# Bootstrap runbook

Stands up `mccarthy` from nothing. Follow in order — several steps depend on
outputs of earlier ones.

Unlike lib-main-infra, this document is **committed**. That repo keeps its
operational notes in `.git/info/exclude`, which is a local-only mechanism, so
the runbook exists on exactly one laptop. Anything genuinely secret belongs in
Key Vault, not in a hidden file; everything else belongs in git.

**Status: steps 1–5 executed 2026-07-31; step 9 attempted 2026-08-03.** `secrets`
and `devtest` are applied and re-plan clean; `production` and `dev` have not been
touched. Both runs hit rough edges and the fixes are folded in below — see
`docs/TODO.md` for the ones still open.

| Step | State |
|---|---|
| 1. Bootstrap script | done — state account `mccarthytfstate2de2eef0` |
| 2. Repo secrets/variables | done — 20 variables, 4 secrets |
| 3. `environments/secrets` | applied — Key Vault `mccarthy-kv-553468f1` |
| 4. Manual Key Vault secrets | done — all three seeded |
| 5. `environments/devtest` | applied — PostgreSQL 18, `mccdevtesth6srb8na` |
| 6. `environments/production` | applied — both passes, re-plans clean; serving on libtest1 |
| 7. Harden state account | done — `allowSharedKeyAccess: false` |
| 8. App repo wiring | done 2026-08-11 — production serves `mccarthy-index` from `0.0.5` |
| 9. First image build | done — `0.0.4`, bootstrap image (vanilla Drupal, not the app repo) |
| 10. Re-enable schedule | done — active since 2026-08-03 |

Production came up on 2026-08-03 and works end to end: the VMSS booted from
`0.0.4`, cloud-init installed Drupal, and Let's Encrypt issued a real certificate
for `libtest1.lib.utk.edu` over HTTP-01. `https://libtest1.lib.utk.edu/health`
returns 200 against a publicly trusted chain.

**Since 2026-08-11 the site serves the Cormac Index**, from image `0.0.5`, after
the first `dev → main` promotion drove `deploy-on-main-merge.yml`'s production
path. Step 8 is complete.

**Correction — that first certificate was never persisted.** This paragraph used
to say the cert was "renewed by `certbot-renew.timer` with a deploy hook that
re-uploads to the `tls-certs` container". The timer and the hook are real, but the
container was **empty from 2026-08-03 until 2026-08-11**: the upload is unchecked,
and production's first apply deliberately ran with `enable_vmss_blob_access =
false`, so it had no data-plane access at the moment it tried. The certificate
lived only on that instance's disk, and the first reimage took HTTPS down for 25
minutes while the deploy reported success. Recovered by hand the same day;
`tls-certs` now holds both PEMs. Full write-up in `docs/TODO.md`. **Do not read
this as evidence that cert persistence works — the next reimage is the first real
test of it.**

**Nothing in this repository had ever run in CI before 2026-08-03.** The first
three dispatches each failed on a different latent defect — OIDC subject format,
Packer's build resource group, and a Drush-less Composer fallback — none of which
were visible from reading the code. The fourth succeeded. All three are written
up in `docs/TODO.md`. Expect the same class of surprise from any step below that
has never executed.

Each build also leaves an intermediate managed image (`mccarthy-rocky9-<version>`)
in `lib-main-images-rg`. That is by design — Packer captures to a managed image
before publishing to the gallery — but they accumulate one per build and nothing
prunes them.

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

> **Do step 9 first.** Production reads the app image through a data source, so a
> plan fails outright until `mccarthy-rocky-linux-9` has at least one version.
> The numbering here is historical.

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

### Using an externally-managed public IP

`dns-test-rg` holds the shared dev/test ingress addresses that OIT has pointed
real names at. mccarthy uses `libtest1` (132.196.154.18 / libtest1.lib.utk.edu);
`libdev1` in the same RG fronts lib-main production the same way. Set
`public_ip_id` to the resource ID and leave `lb_dns_label` null — it is ignored.

Two things have to be true before the apply, both done for libtest1 on
2026-08-03 but not for whatever address comes next:

```bash
# 1. An Azure public IP can front only one resource. libtest1 was a secondary
#    ipconfig on the DNS-test VM's NIC. Note --remove: passing
#    --public-ip-address "" makes Azure resolve an empty resource name and fails
#    with InvalidResourceReference.
az network nic ip-config update -g dns-test-rg \
  --nic-name dns-test568_z2 -n ipconfig-libtest1 --remove publicIpAddress

# 2. CI needs publicIPAddresses/join/action on it. The service principal is
#    scoped to the five mccarthy RGs and inherits nothing, so a local apply
#    (subscription Owner via PIM) succeeds where deploy-production.yml would not.
#    Scoped to the IP, not the RG -- lib-main's SP gets this from subscription-wide
#    Contributor, which is not a pattern worth copying.
az role assignment create --assignee <sp object id> \
  --role "Network Contributor" \
  --scope ".../resourceGroups/dns-test-rg/providers/Microsoft.Network/publicIPAddresses/libtest1"
```

`domain_name` is not only the TLS CN. It is baked into `settings.php` as a
trusted host pattern and as `az_blob_cdn_host_name`, which is what makes Drupal
emit media URLs on the site domain for Apache to rewrite to blob + SAS. Changing
it later is a re-apply plus a VMSS reimage — all config, no data migration.

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

Done 2026-08-03. Check every consumer first — there is no shared-key fallback
afterwards, and a CI-only consumer will not show up in a local test:

- all five `terraform init` calls in `.github/workflows/` pass
  `use_azuread_auth=true` (and `use_oidc=true`)
- the `terraform_remote_state.secrets` data source in `production`, `devtest` and
  `dev` passes `use_azuread_auth = var.use_azuread_auth`, which defaults to `true`
- nothing sets `ARM_ACCESS_KEY` or a SAS token anywhere

Verified afterwards by re-planning all three applied environments; each still
reads its state and reports no drift. Note this hardens only the **state**
account. The per-environment data storage accounts still mirror their access keys
into Key Vault for the Drupal `key` module, which is a separate mechanism.

## 8. Create the app repository

The app repo is `utkdigitalinitiatives/mccarthy-index` (already created by the dev
team, cloned to `~/projects/mccarthy-index`). See the README's "Contract the app
repo must satisfy" for what it needs.

**This step is in progress, not done. `docs/TODO.md` carries the authoritative
per-item state** — read it before touching anything here. Summary as of
2026-08-04:

- **the repo went public**, so the Packer clone needs no credential. A future
  private app repo would; the TODO entry explains why the obvious fix bakes a
  token into the published image.
- **dispatch is wired.** Reused lib-main's `lib-dispatch` App (ID `2828711`)
  rather than registering a new one, added `mccarthy-infra` to its selected-repo
  list, and set `vars.DISPATCH_APP_ID` + `secrets.DISPATCH_APP_PRIVATE_KEY` **on
  the app repo**, not here. `mccarthy-index` commit `bb2ea88` adds
  `dispatch-dev-merge.yml` and `dev-to-main.yml`.
- **the App needs `contents: write` + `metadata: read`.** An earlier version of
  this runbook said `contents: read`; that is wrong.
  `POST /repos/.../dispatches` requires Contents *write* for App and
  fine-grained tokens, so an App built to the old spec 403s on its first
  dispatch.
- **`dispatch-main-merge.yml` is written but deliberately not committed.**
  Committing it to `main` fires it on that same push and would trigger a
  first-ever unattended production deploy. Create the `production` GitHub
  environment with a required reviewer first — no environments exist today, so
  the `environment:` keys in the deploy workflows currently enforce nothing.
- **the dev team owns the `dev` branch and branch protection.** Until `dev`
  exists nothing can dispatch, so that is what gates the first end-to-end run.
- still open on the app-repo side: no root `.gitignore`; three `drupal/core`
  advisories that only `composer audit --locked` reports. `az_blob_fs`/`key` were
  missing from `composer.json` and `core.extension.yml`; a fix is committed on
  `mccarthy-index` branch `feat/az-blob-fs` but not merged. The 6 Dependabot
  alerts were cleared 2026-08-10.
- DDEV declares PHP 8.4 against production's 8.3. Core only needs PHP >= 8.3, so
  this is a difference rather than a defect. PostgreSQL now matches at 18 on both
  sides, so local dumps restore into production cleanly.

## 9. First image build

There is no `base-image-build.yml` here. Confirm the shared base image exists:

```bash
az sig image-version list \
  --resource-group lib-main-images-rg \
  --gallery-name lib_main_gallery \
  --gallery-image-definition drupal-base-rocky-linux-9 \
  --query "sort_by([].name, &@)[-1]" -o tsv
```

**This has to happen before step 6, despite the numbering.** Production's
`data.azurerm_shared_image_version` lookup fails at *refresh*, so without a
version in `mccarthy-rocky-linux-9` production cannot even be planned.

Only `build-on-dispatch.yml` writes into that image definition, and it is
`repository_dispatch`-only. `test-cloud-init.yml` **consumes** an existing
version — it never builds one — and a push to the app repo's `dev` branch cannot
dispatch anything until that repo has workflows (step 8). So the first image has
to be kicked off by hand:

```bash
gh api repos/utkdigitalinitiatives/mccarthy-infra/dispatches \
  -f event_type=drupal-dev-merge \
  -f 'client_payload[bootstrap_build]=true'
```

`bootstrap_build` builds the image with **no app repo**, from vanilla Drupal via
`composer create-project`, and skips the three downstream jobs (they all read
from a production that does not exist yet). That is enough to prove out the load
balancer, the public IP, TLS issuance and cloud-init — but it is not the site.
Rebuild from the app repo once step 8 is done.

Use `-f`, not `-F`. `-F` has magic type conversion: it would send a JSON boolean
`true` rather than the string, and GitHub's expression comparison coerces
mismatched types to numbers — `true` becomes 1, `'true'` becomes NaN, and
`1 != NaN` is true, so the downstream guard would let the jobs run. The workflow
normalises the flag into a job output for exactly this reason, but there is no
sense in leaning on that.

Afterwards, feed the version it produced into production's `terraform.tfvars`:

```bash
gh run list --workflow "Build on Dispatch" --limit 1
az sig image-version list -g lib-main-images-rg --gallery-name lib_main_gallery \
  --gallery-image-definition mccarthy-rocky-linux-9 --query "[].name" -o tsv
```

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

Done 2026-08-03. What it commits you to, since the cron is easy to misread:

| Cron (UTC) | Action | Eastern |
|---|---|---|
| `30 11 * * 1-5` | start | 07:30 EDT / 06:30 EST |
| `30 22 * * 1-5` | stop | 18:30 EDT / 17:30 EST |

**GitHub cron is always UTC, so the local window shifts an hour across DST.** If
the site must be up by a fixed local time year-round, the cron needs adjusting
twice a year — nothing here does that automatically.

**Weekdays only.** Production is deallocated from Friday evening until Monday
morning. That is the intent for a cost-managed environment, but `libtest1` is
publicly resolvable, so anyone hitting it over a weekend gets nothing. Decide
deliberately before this fronts anything user-facing.

`ACTION` falls through to `stop` for any trigger that is not the start cron. That
biases toward not running rather than toward burning money, which is the right
default — but it does mean editing the start cron string without also editing the
`ACTION` expression in the job's `env:` silently converts the morning start into a
second stop.

Every cold start re-runs the cloud-init ceremony — see "Auto-stop wake-up race" in
the rough-edges table. Harmless at one instance; revisit before scaling out.

Note also that GitHub disables scheduled workflows automatically after 60 days
with no repository activity, and may delay scheduled runs under load. Neither is
a correctness problem here, but a missed start is a missed start.

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

## Things this project found first

Not inherited — these surfaced here and lib-main has not hit them yet.

| Issue | Where it bites |
|---|---|
| OIDC subject format | mccarthy-infra is issued the *immutable* subject claim (`repo:org@ID/repo@ID:...`); lib-main-infra still gets the name-based form. **lib-main is one repo rename away from the same `AADSTS700213`**, and its federated credentials would then need the same treatment. Read the truth from `gh api repos/<org>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix` — not from `use_immutable_subject`, which reads `false` even where the immutable form is in use. |
| Narrow SP scope vs. Packer | Contributor on five named resource groups means Packer cannot create its default throwaway build RG, and reports the authorization failure as "a resource group with that name already exists". Set `build_resource_group_name`. lib-main never sees this because its SP is a subscription-wide Contributor. |
| The Composer fallback rots | It is the one path nobody exercises. It shipped without Drush. Anything cloud-init needs must be explicitly required there, not assumed from the app repo's `composer.lock`. |
| An unset repo variable is `""`, not null | `TF_VAR_x: ${{ vars.X }}` with `X` unset sets the env var to the **empty string**, and Terraform does not read that as `null`. Any `var.x == null` gate silently takes the wrong branch. Cost us every CI production deploy via `PUBLIC_IP_ID` before it was ever noticed, because `modules/load-balancer/main.tf:39` gates IP creation on `== null`. **lib-main uses the same pattern and is exposed wherever a `vars.` value is optional.** Grep for `== null` against anything sourced from `vars.`. |
| A workflow triggers on the push that adds it | GitHub evaluates workflows from the pushed commit, so committing a new `on: push: branches: [main]` workflow **fires it immediately**. Adding a production-deploy dispatcher is therefore itself a production deploy. Land such files only when an unattended run is acceptable, or gate them behind an environment with a required reviewer. Corollary, observed 2026-08-07: **creating a branch also emits a `push` event**, but `paths-ignore` still applies — creating `dev` at `bb2ea88`, whose diff is entirely `.github/**`, triggered nothing. Do not rely on that for a branch cut from a commit that touches real files. |
| `environment:` with no environment enforces nothing | GitHub auto-creates a missing environment on first use **with no protection rules**. `mccarthy-infra` declared `environment: production` in two deploy workflows while `total_count` was 0, so the approval gate everyone assumed existed did not. Check `gh api /repos/<org>/<repo>/environments` rather than trusting the workflow YAML. |
| `$settings['file_default_scheme']` is inert (**verified 2026-08-11**) | Cloud-init sets it in both projects and it has never done anything. Drupal 8+ reads the default scheme from `system.file:default_scheme` config; core contains **zero** reads of `Settings::get('file_default_scheme')`, and `FileSystemForm.php:132-135` binds that form key to `'#config_target' => 'system.file:default_scheme'`. Both repos export `system.file.yml` with `default_scheme: public`, which `config:import` re-asserts every deploy — so neither site's default scheme is `azblob`, and both rely on per-field `uri_scheme`. **Applies to lib-main identically.** Full write-up in `docs/TODO.md`. |
