# Bootstrap runbook

Stands up `mccarthy` from nothing. Follow in order — several steps depend on
outputs of earlier ones.

Unlike lib-main-infra, this document is **committed**. That repo keeps its
operational notes in `.git/info/exclude`, which is a local-only mechanism, so
the runbook exists on exactly one laptop. Anything genuinely secret belongs in
Key Vault, not in a hidden file; everything else belongs in git.

**Status: steps 1–5 executed 2026-07-31.** `secrets` and `devtest` are applied and
re-plan clean; `production` and `dev` have not been touched. The first run did hit
rough edges, and the fixes are folded in below — see `docs/TODO.md` for the two
that are still open, one of which (the Defender for Storage singleton) will recur
on the production apply.

| Step | State |
|---|---|
| 1. Bootstrap script | done — state account `mccarthytfstate2de2eef0` |
| 2. Repo secrets/variables | done — 20 variables, 4 secrets |
| 3. `environments/secrets` | applied — Key Vault `mccarthy-kv-553468f1` |
| 4. Manual Key Vault secrets | done — all three seeded |
| 5. `environments/devtest` | applied — PostgreSQL 18, `mccdevtesth6srb8na` |
| 6+ | not started |

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

Local applies authenticate with your `az login` session. This environment has no
`use_oidc` variable — omitting `-backend-config="use_oidc=true"` from `init` is
all that is needed. `devtest` and `production` *do* declare one, already `false`
in their example tfvars; see step 5.

`use_azuread_auth=true` also means **you** need `Storage Blob Data Contributor`
on the state storage account. `bootstrap/azure-setup.sh` grants it to the signed-in
user, but if you bootstrapped as someone else, grant it before running `init` or
it fails reading state. Owner at subscription scope is not sufficient — it carries
no data-plane blob access.

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

**Do not generate a site UUID.** It already exists. Read it out of the app repo,
where it was written by `drush config:export` after the site was first installed:

```bash
grep '^uuid:' ~/projects/mccarthy-index/config/system.site.yml
#   uuid: 542dcd94-b092-493d-9561-7361fe4c34bd
```

Cloud-init runs `drush site:install` (which mints a throwaway random UUID),
immediately overwrites it with this value, then runs `config:import` — which
Drupal refuses if the two disagree.

Read the install profile from the same place, for the same reason: Drupal will
not let config import change it, so a mismatch fails the first production boot.

```bash
grep '^profile:' ~/projects/mccarthy-index/config/core.extension.yml
#   profile: minimal
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
gh variable set DRUPAL_SITE_UUID     --body "$(grep '^uuid:' ~/projects/mccarthy-index/config/system.site.yml | awk '{print $2}')"
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

The app repo is `utkdigitalinitiatives/mccarthy-index` (already created by the dev
team, cloned to `~/projects/mccarthy-index`). It has **no `.github/` directory**,
so nothing dispatches to this repo yet and the pipeline cannot be exercised end
to end. See the README's "Contract the app repo must satisfy" for what it needs.

Open items on the app-repo side, as of 2026-07-30:

- no dispatch workflows and no dev-to-main branch guard
- no `dev` branch; only `main`
- no root `.gitignore`, so `vendor/` and `web/core/` are one `git add -A` from
  being committed
- no `az_blob_fs`; `system.file:default_scheme` is `public`, which on a VMSS is
  local disk wiped by every reimage
- DDEV declares PHP 8.4 against production's 8.3. Core only needs PHP >= 8.3, so
  this is a difference rather than a defect. PostgreSQL now matches at 18 on both
  sides, so local dumps restore into production cleanly.

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

> `prepare-database` installs the PostgreSQL client from PGDG pinned to
> `vars.PG_MAJOR`. If that variable is unset the workflows fall back to `18`, which
> matches the Terraform default — but set it explicitly, because it is also what
> feeds `TF_VAR_postgresql_version` on production applies.

## 10. Re-enable the scheduled workflow

`production-schedule.yml` was disabled at repo creation so its cron did not fire
against resources that did not exist yet. Once production is applied:

```bash
gh workflow enable "Production Start/Stop Schedule"
```

The other four workflows are event-triggered and safe to leave active — nothing
dispatches to them until the app repo exists.

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
| PostgreSQL major changes | Change `PG_MAJOR` and the Terraform default together. It pins both the server and the runner's `pg_dump`; a client older than the server cannot dump it at all. |
