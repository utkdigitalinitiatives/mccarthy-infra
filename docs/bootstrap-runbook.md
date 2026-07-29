# Bootstrap runbook

Stands up `mccarthy` from nothing. Follow in order — several steps depend on
outputs of earlier ones.

Unlike lib-main-infra, this document is **committed**. That repo keeps its
operational notes in `.git/info/exclude`, which is a local-only mechanism, so
the runbook exists on exactly one laptop. Anything genuinely secret belongs in
Key Vault, not in a hidden file; everything else belongs in git.

**Nothing in this runbook has been executed yet.** The repository is scaffolding
only. Expect to hit rough edges on the first real run and fix them here.

---

## Prerequisites

- `az` CLI, logged in, with rights to create Entra app registrations and to
  assign roles at resource-group scope
- `terraform` >= 1.0, `gh` CLI
- Access to the `UTK-Library-Systems` subscription
- Write access to `lib-main-images-rg` (the shared gallery lives there)

---

## 1. Run the bootstrap script

```bash
./bootstrap/azure-setup.sh
```

Creates the five resource groups, the Terraform state storage account, the
`mccarthy-rocky-linux-9` image definition inside the **shared** gallery, and the
`mccarthy-github-actions` service principal with federated OIDC credentials and
no password. It is idempotent; re-run freely.

It prints the `gh secret set` / `gh variable set` commands for everything known
at this point. Run them.

## 2. Confirm what the script did NOT do

- It does **not** accept Rocky Linux marketplace terms — already accepted in
  this subscription for lib-main.
- It does **not** build a base image — `lib-main-infra` owns that.
- It does **not** create the Compute Gallery — shared, already exists.

## 3. Apply `environments/secrets/`

```bash
cd environments/secrets
cp backend.hcl.example backend.hcl          # fill in the storage account name
cp terraform.tfvars.example terraform.tfvars # fill in subscription, cost center, SP object ID
terraform init -backend-config=backend.hcl -backend-config="use_azuread_auth=true"
terraform apply
```

`gh_actions_sp_object_id` is the **object ID**, not the app/client ID:

```bash
az ad sp show --id <appId> --query id -o tsv
```

Local applies authenticate with your `az login` session, so set `use_oidc =
false` in `terraform.tfvars` (already the default in the example file).

## 4. Seed the manual Key Vault secrets

Terraform generates the hash salts, the Drupal admin password, and mirrors the
storage keys. These three must be seeded by hand first:

```bash
KV=$(az keyvault list -g mccarthy-secrets-rg --query "[0].name" -o tsv)

az keyvault secret set --vault-name "$KV" --name production-db-admin-password --value '<generated>'
az keyvault secret set --vault-name "$KV" --name devtest-db-admin-password    --value '<generated>'
az keyvault secret set --vault-name "$KV" --name shared-postmark-api-token    --value '<postmark server token>'
```

Generate passwords with something like
`openssl rand -base64 32 | tr -d '/+=' | head -c 32`. PostgreSQL rejects some
punctuation in admin passwords, so stick to alphanumerics.

## 5. Apply `environments/devtest/`

```bash
cd environments/devtest
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl -backend-config="use_azuread_auth=true"
terraform apply
```

Then publish the outputs the workflows need:

```bash
gh variable set DEVTEST_DB_HOST         --body "$(terraform output -raw postgresql_fqdn)"
gh variable set DEVTEST_STORAGE_ACCOUNT --body "$(terraform output -raw storage_account_name)"
```

## 6. Apply `environments/production/`

Generate the site UUID once and keep it forever — it must match
`config/system.site.yml` in the app repo or config import fails on every deploy:

```bash
uuidgen | tr 'A-Z' 'a-z'
```

```bash
cd environments/production
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars   # fill in UUID, domain, SSH key, IP
terraform init -backend-config=backend.hcl -backend-config="use_azuread_auth=true"
terraform apply
```

**Two-pass deployment.** Leave `enable_vmss_blob_access = false` for the first
apply — the VMSS does not exist yet, so there is no managed identity to grant
blob access to. Set it to `true` and apply again.

Then:

```bash
gh variable set PROD_STORAGE_ACCOUNT --body "$(terraform output -raw storage_account_name)"
gh variable set SUBNET_ID            --body "$(terraform output -raw web_subnet_id)"
gh variable set DRUPAL_SITE_UUID     --body "<the uuid you generated>"
gh variable set DOMAIN_NAME          --body "<site fqdn>"
```

## 7. Harden the state storage account

Once `terraform init` and `plan` have both succeeded against the Entra-auth
backend, and the role assignment has had a few minutes to propagate:

```bash
az storage account update --name <state account> \
  --resource-group mccarthy-tfstate-rg --allow-shared-key-access false
```

Doing this **before** `Storage Blob Data Contributor` has propagated locks you
out of your own state.

## 8. Create the app repository

`utkdigitalinitiatives/mccarthy` does not exist yet. See the README's
"Contract the app repo must satisfy" section for exactly what it needs to
implement. Until it exists the build pipeline has nothing to clone and cannot
be exercised end to end.

Register a GitHub App (or reuse lib-main's) with `contents: read` and
`metadata: read` on this repo, install it on the app repo, and set
`vars.DISPATCH_APP_ID` + `secrets.DISPATCH_APP_PRIVATE_KEY` there.

## 9. First image build

There is no `base-image-build.yml` here. Confirm the shared base image exists:

```bash
az sig image-version list \
  --resource-group lib-main-images-rg \
  --gallery-name lib_main_gallery \
  --gallery-image-definition drupal-base-rocky-linux-9 \
  --query "sort_by([].name, &@)[-1]" -o tsv
```

Then push to `dev` in the app repo, or run `test-cloud-init.yml` manually.

---

## Acceptance test

The bootstrap is done when:

1. `secrets`, `devtest`, and `production` have all applied cleanly
2. A dev-merge dispatch builds an image and deploys the dev VM
3. `curl -ksf https://<dev vm ip>/health` returns `OK`
4. `/var/log/cloud-init-output.log` on the dev VM has no `[fetch-secrets]` errors
5. A main-merge dispatch rolls production and `http://<domain>/health` returns 200

---

## Known rough edges inherited from lib-main-infra

Carried forward as warnings because they will bite the same way here.

| Issue | Where it bites |
|---|---|
| Stale `image_version` in `terraform.tfvars` | A manual production apply silently reimages to an old build. Always pass `-var="image_version=<currently running>"`. CI is unaffected — it passes an explicit `-var`. |
| Cross-node DB ceremony | With MaxSurge, two VMSS instances can run `drush updatedb` / `config:import` against the same database concurrently. Fine for additive changes; serialize with `pg_advisory_lock` before the first breaking schema change. |
| Auto-stop wake-up race | The nightly deallocate means a cold boot re-runs the cloud-init ceremony. Same fix as above. |
| Media SAS expiry | `media_sas_expiry` is a hard date. Media stops being served when it lapses. Put it on a calendar. |
| Base image drift | The shared base is rebuilt monthly by lib-main-infra. Set `BASE_IMAGE_VERSION` to pin. |
