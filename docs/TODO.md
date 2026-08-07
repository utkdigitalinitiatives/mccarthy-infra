# TODO

Known issues and deferred work. Unlike lib-main-infra's equivalent, this file is
**committed** — a local-only note helps exactly one person.

Entries should carry enough evidence that the next person does not have to
re-derive the problem: what breaks, how it was verified, and what the fix is.

---

## Open

### `DefenderForStorageSettings/current` must be imported, never created

**Found 2026-07-31 during the first devtest apply.**

`modules/blob-storage` declares `azapi_resource.defender_for_storage` (created
when `disable_defender_for_storage = true`). That resource is a **singleton that
Azure provisions automatically** for every storage account, inheriting the
subscription-level Defender settings. Terraform can therefore never create it:

```
Error: Resource already exists
a resource with the ID ".../DefenderForStorageSettings/current" already exists -
to be managed via Terraform this resource needs to be imported into the State.
```

**Production is NOT affected** — verified by plan on 2026-08-03, which creates 33
resources and no `defender_for_storage` among them. The resource is `count`-gated
on `disable_defender_for_storage`, which defaults to `false` and is set to `true`
only in `environments/devtest/main.tf:117`. `dev` does not set it either.

So this recurs on any storage account that *opts out* of Defender, not on every
new one. Unblock with:

```bash
terraform import 'module.blob_storage.azapi_resource.defender_for_storage[0]' \
  '<storage-account-id>/providers/Microsoft.Security/DefenderForStorageSettings/current?api-version=2022-12-01-preview'
```

Proper fix: switch the module to `azapi_update_resource`, which patches an
existing resource instead of asserting ownership of its creation. Not done yet
because it changes the module for devtest and production together and deserves
its own apply.

---

### azurerm misreads `runbook_type`, forcing a phantom replacement

**Found 2026-07-31. Worked around, not fixed.**

`azurerm_automation_runbook.stop_postgresql` is declared `PowerShell72`. Provider
4.81 reads it back as `PowerShell`, which forces replacement on every single
plan. Azure itself is correct — `az automation runbook show` reports
`runbookType: PowerShell72` — so this is a provider read bug, not real drift.

Suppressed with `lifecycle { ignore_changes = [runbook_type] }` in
`modules/azure-automation/main.tf`. **Re-test on provider upgrades** and drop the
workaround once the read is fixed, otherwise a genuine runbook-type change would
be silently ignored.

---

### App repo (`mccarthy-index`) — step 8, partly wired, blocked on the dev team

**This is the only remaining bootstrap step.** Steps 1–7, 9 and 10 are done;
production is applied and serving. The README's "Contract the app repo must
satisfy" is the authoritative list.

**Progress as of 2026-08-04.** The dispatch plumbing is wired and the credential
question is settled. What is left is one deliberate hold on our side and a branch
setup owned by the dev team. **Nothing has fired end to end yet** — no image has
ever been built from the app repo, `mccarthy-index` still carries only its
2026-07-07 scaffold, and production still serves the vanilla Drupal baked into
image `0.0.4`. Read the per-item state below rather than assuming.

**Gating decision resolved: `mccarthy-index` went PUBLIC on 2026-08-04.** The
anonymous clone works and no git credential is needed; step 8 work is unblocked.
Context, in case visibility ever flips back: **no git credential is plumbed into
Packer** — `var.drupal_repo` reaches `ansible.builtin.git` in
`packer/ansible/playbook.yml` with nothing to authenticate with, and the clone
runs on the throwaway build VM, not the Actions runner, so the runner's
`GITHUB_TOKEN` cannot help (wrong repo scope, wrong machine). A future private
repo means either cloning on the runner and shipping the tree to the VM with a
`file` provisioner (preferred — no secret can be baked into the image), or
threading a short-lived token through `build-on-dispatch.yml` → Packer → the
playbook and scrubbing `.git/config` before capture, because git persists the
authenticated remote URL there.

Infra-side work:

- **DONE 2026-08-04 — GitHub App.** Reused lib-main's `lib-dispatch` rather than
  registering a new one: app ID `2828711`, installation `109025518` on the org,
  `repository_selection: selected`. `mccarthy-infra` was added to that selected
  list, and `vars.DISPATCH_APP_ID` + `secrets.DISPATCH_APP_PRIVATE_KEY` are set on
  **`mccarthy-index`**, not here. Verified by minting a token scoped to
  `mccarthy-infra` — a 422 is what "repo not in the installation" looks like.
  **The App holds `contents: write` + `metadata: read`, and write is required**:
  `POST /repos/.../dispatches` needs Contents *write* for App and fine-grained
  tokens. The runbook said `contents: read`; a new App built to that spec would
  403 on its first dispatch. That is now corrected in
  `docs/bootstrap-runbook.md`.
- **DONE 2026-08-04 — `PUBLIC_IP_ID` repo variable.** It was never set, and it is
  consumed by both `deploy-production.yml` and `deploy-on-main-merge.yml`. Unset,
  GitHub passes `TF_VAR_public_ip_id=""`, and **an empty string is not `null`**:
  `modules/load-balancer/main.tf:39` gates IP creation on `== null`, so Terraform
  would neither create an IP nor reuse the real one, and would pass `""` as the
  frontend IP. Every production deploy through CI would have failed. Set to the
  `libtest1` resource in `dns-test-rg`, verified against the live LB frontend.
  `LB_DNS_LABEL` is still unset and that is correct — `main.tf:173` forces
  `dns_label = null` whenever `public_ip_id` is set.
- **`deploy-on-main-merge.yml` has still never fired**, and `environments/dev/`
  has never been applied. Expect first-run defects; see the CI note at the bottom
  of this file.
- **No GitHub environment exists — `total_count` is 0.** `deploy-production.yml`
  and `deploy-on-main-merge.yml` both declare `environment: production` and
  `build-on-dispatch.yml` declares `environment: dev`, but GitHub auto-creates an
  environment on first use with **no protection rules**, so all three are
  currently decorative. Create `production` with a required reviewer before the
  main-merge path goes live, or a dev→main merge deploys production unattended.

App-repo side:

- **PARTLY DONE 2026-08-04 — workflows.** `mccarthy-index` commit `bb2ea88` adds
  `dispatch-dev-merge.yml` (push to `dev`, with `paths-ignore` and a 5-attempt
  retry) and `dev-to-main.yml` (fails PRs into `main` from any head but `dev`).
  Both carry an `if: failure()` step that opens — or comments on — an issue
  holding the exact re-dispatch command, because lib-main lost a pipeline run to a
  silent server-side dispatch failure that nobody noticed. Adapted from
  `lib-main`'s equivalents, which have neither the retry nor the alert.
- **HELD BACK DELIBERATELY — `dispatch-main-merge.yml`.** It is written and
  `actionlint`-clean but sits **untracked** in `~/projects/mccarthy-index`. It has
  not been committed because **`on: push: branches: [main]` fires on the very push
  that adds the file** — GitHub evaluates workflows from the pushed commit — so
  committing it immediately triggers a first-ever, unattended, unreviewed
  production deploy. Land it only once the `production` environment has a required
  reviewer. It deliberately carries no `paths-ignore`, unlike the dev dispatch,
  because the main-merge event also destroys the dev VM and skipping a docs-only
  merge would leave that VM running and billing.
- **DONE 2026-08-07 — `dev` branch created** at `bb2ea88`, same tip as `main`.
  Creating it emitted a `push` event on `dev` but triggered nothing, because that
  commit's diff is entirely `.github/**`, which `dispatch-dev-merge.yml` lists in
  `paths-ignore`. **The next push to `dev` that touches real files is the first
  end-to-end pipeline run** — Packer build, `DROP`/`CREATE` on the devtest
  database, blob sync, and the first-ever apply of `environments/dev/`. Expect
  first-run defects.
- **Still open — branch protection**, deliberately deferred 2026-08-07. `main` is
  unprotected, so `dev-to-main.yml` runs but nothing requires it to pass, and
  nothing stops a direct push to `main`. The flow is `topic → dev → main`.
- still no root `.gitignore`, so `vendor/` and `web/core/` are one `git add -A`
  away
- **6 open Dependabot alerts, all `guzzlehttp/guzzle`** (1 high, 5 moderate).
  They live in `composer.lock`, which the Packer build installs with
  `composer install --no-dev`, so they would be baked into the production image. A
  `composer update guzzlehttp/guzzle` on `dev` clears all six and makes a good
  first exercise of the pipeline: a real change, a verifiable outcome, nothing
  else riding on it.

**Blob storage is not wired into the app repo — and the earlier framing of this
was wrong.** Re-checked 2026-08-04. `composer.json` requires **neither
`drupal/az_blob_fs` nor `drupal/key`**, and neither appears in
`config/core.extension.yml`, while cloud-init unconditionally writes
`$settings['file_default_scheme'] = 'azblob'`,
`$config['az_blob_fs.settings'][...]` and `$config['key.key.azure_blob_key'][...]`
into `settings.php`.

This entry used to say it was "most likely to bite on the first real deploy." It
is not, and the mechanism matters:

- `drush en key az_blob_fs` appears **only in cloud-init's fresh-install branch**
  (`environments/production/cloud-init.tftpl:294`). Production is already
  installed, so a reimage takes the *update* branch — `updatedb` →
  `config:import` — which never runs `drush en`. Module state comes entirely from
  `config/core.extension.yml`. **Listing the modules there is what enables them;
  requiring them in `composer.json` only puts the code on disk.** Both are needed.
- `mccarthy-index` **has no file or image fields at all** — 18 node field
  storages, all text/date/taxonomy, no media types, and no `uri_scheme` anywhere
  in `config/`. Compare `lib-main`, which sets `uri_scheme: azblob` on all five of
  its file field storages. So the first deploy has nothing to store and will not
  break.

The real trigger is **the day someone adds an image or file field to `record`**:
files then land on VMSS local disk and are wiped by the next reimage, silently.
Cheap now, expensive later. Fix is `composer require drupal/az_blob_fs:^3.0
drupal/key:>=1.15` (the versions lib-main runs), both modules added to
`core.extension.yml`, and `az_blob_fs.settings.yml` + `key.key.azure_blob_key.yml`
exported as empty shells for cloud-init's `$config` overrides to land on — a
`$config` override does nothing if the config entity it targets does not exist.
Copy lib-main's.

**Unverified, worth ten minutes on devtest:** cloud-init sets
`$settings['file_default_scheme']`, but Drupal 9+ reads the default scheme from
`system.file:default_scheme` config, not from `$settings`. That line may be inert
in **both** this project and lib-main.

Not a defect, just a difference: DDEV declares PHP 8.4 against production's 8.3.
Core needs >= 8.3. PostgreSQL matches at 18 on both sides since 2026-07-31.

---

### Nothing prunes images in the shared resource group

**Observed 2026-08-03.** Pre-existing and mostly lib-main's, but mccarthy now
contributes to it, so it is recorded here rather than only in lib-main-infra.

`lib-main-images-rg` holds **89 intermediate managed images** (81 `drupal-rocky9-*`,
7 `drupal-base-rocky9-*`, 1 `mccarthy-rocky9-*`), each declaring a 64 GB OS disk,
plus **80 gallery versions** under `drupal-rocky-linux-9`. Both grow by one per
build and neither is ever cleaned up.

The intermediate managed image is a Packer implementation detail — it captures to
a managed image, then publishes that into the gallery. Once the gallery version
exists the managed image has no consumer, so all of the old ones are dead weight.
Gallery versions are at least defensible for rollback; 80 is not.

Billing is on used capacity, not the provisioned 64 GB, so the real cost is well
below what the raw numbers suggest — worth measuring before acting.

Not fixed here because deleting image history is not this project's call, and any
prune has to account for which versions running VMSS instances are pinned to.
`az vmss show --query virtualMachineProfile.storageProfile.imageReference.id`
before deleting anything.

---

### lib-main must move off `10.0.0.0/16` before it goes live

Not this repo's change, but it constrains the shared Solr plan and is recorded
here so the dependency is visible. lib-main's production VNet collides with the
Asimov AKS service CIDR. See the README's VNet address allocation section, and
lib-main-infra's own `README.md` / `docs/TODO.md` / `CLAUDE.md`.

---

## Resolved

### The Composer fallback built an image with no Drush in it

**Found 2026-08-03 on the third CI run.**

`drupal/recommended-project` does not bundle Drush. The Ansible playbook's
app-repo path gets it from the project's own `composer.lock`, but the
`composer create-project` fallback — the path that exists specifically so the
first image can be built before the app repo is wired — never asked for it. The
build got as far as symlinking:

```
fatal: [default]: FAILED! => {"msg": "src file does not exist, use 'force=yes'
  if you really want to create the link: /var/www/drupal/vendor/bin/drush"}
```

Cloud-init drives the whole site install through Drush (`site:install`, the UUID
overwrite, `config:import`, `updatedb`, `cache:rebuild`), so an image without it
is inert. Fixed with an explicit `composer require drush/drush` guarded to the
fallback path.

This is the general hazard with that fallback: it is the only path nobody ever
exercises, so it rots silently. `mccarthy-index` does declare `drush/drush ^13.7`,
so the clone path was never affected — but an app repo that omitted it would fail
at exactly the same task with exactly the same message.

---

### Packer wanted a subscription-scope resource group the SP cannot create

**Found 2026-08-03 on the second CI run, once the OIDC fix below let it get far
enough to fail on something else.**

By default the azure-arm builder creates a throwaway `pkr-Resource-Group-*`,
which needs `Microsoft.Resources/subscriptions/resourceGroups/write` at
subscription scope. This project's service principal holds Contributor on five
named resource groups and nothing wider — deliberately, and unlike
`lib-main-github-actions`, which has subscription-wide Contributor and so never
hit this.

Packer reports the resulting `AuthorizationFailed` as:

```
A resource group with that name already exists.
Please use build_resource_group_name to use an existing resource group.
```

which is wrong and cost some time — the group did not exist, the SP could not
read the scope to find out. The advice it gives is right, though.

**Fix:** `build_resource_group_name` is now a Packer variable, and
`build-on-dispatch.yml` passes `vars.BUILD_RESOURCE_GROUP` falling back to
`vars.GALLERY_RESOURCE_GROUP` (`lib-main-images-rg`), where the SP already has
Contributor and where the intermediate managed image already lands. The build VM
and its disk/NIC are transient and Packer cleans them up.

Note `location` and `build_resource_group_name` are mutually exclusive — Packer
derives the region from the group and rejects both — so `location` is set
conditionally. Leaving the new variable null preserves the old temp-RG behaviour
for anyone running with broader rights; both paths pass `packer validate`.

If mccarthy should stop borrowing lib-main's resource group for builds, the
change is a dedicated `mccarthy-images-rg` plus a Contributor assignment in
`bootstrap/azure-setup.sh` and a `BUILD_RESOURCE_GROUP` repo variable.

---

### GitHub now issues an immutable OIDC subject, and Entra matched the old one

**Found 2026-08-03 on the very first CI run — `Azure Login`, the first step that
had ever exercised the service principal.**

```
AADSTS700213: No matching federated identity record found for presented
assertion subject 'repo:utkdigitalinitiatives@11233454/mccarthy-infra@1316465775:ref:refs/heads/main'
```

The federated credentials said `repo:utkdigitalinitiatives/mccarthy-infra:...`.
GitHub has started embedding the numeric org and repo IDs in the subject claim —
an *immutable* identifier that survives a rename, where the name-based form
silently stops matching after one. Entra does no wildcarding, so nothing matched
and every OIDC-authenticating job would have failed the same way.

The rollout is per-repository, not org-wide, and appears to track repo creation
date. Confirm rather than assume:

```bash
gh api repos/<org>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
#   mccarthy-infra: repo:utkdigitalinitiatives@11233454/mccarthy-infra@1316465775
#   lib-main-infra: repo:utkdigitalinitiatives/lib-main-infra
```

**lib-main-infra is on the old format and is unaffected** — but it is one repo
rename away from the same failure, and its credentials would then need the same
treatment.

Note `use_immutable_subject` in that response reads `false` even for
mccarthy-infra, which is misleading. `sub_claim_prefix` is the field that tells
you what will actually be presented; trust it over the flag.

**Fix:** `bootstrap/azure-setup.sh` now reads the prefix from that endpoint
instead of composing `repo:<org>/<repo>` itself, falling back to the old form
with a warning if the call fails. `add_federated_credential` also reconciles on
*subject* rather than merely checking that the name exists, so re-running the
script repairs an already-bootstrapped project instead of reporting `exists:`
and leaving it broken. That is the case that matters: the format changing under
a working deployment is precisely when someone re-runs the script.

---

### A JSON boolean in `client_payload` walked straight past a workflow guard

**Introduced and fixed 2026-08-03, caught in review before it ever ran.**

`bootstrap_build` gates whether `build-on-dispatch.yml` stops after the image or
carries on into `prepare-database`, `sync-blob-storage` and `deploy-dev`. The
first version of the guard compared `github.event.client_payload.bootstrap_build`
directly against `'true'` at job level. That is only correct if the caller sends a
**string**.

GitHub coerces mismatched types to numbers before comparing. A JSON boolean
`true` casts to 1; the string `'true'` casts to NaN; `1 != NaN` is **true**. So
`{"bootstrap_build": true}` — the natural way to write it, and what `gh api -F`
produces — built the vanilla image and then ran the downstream jobs anyway. The
shell test in the validate step could not catch it either: `${{ }}` stringifies
both forms to `true` before the shell ever sees them.

During a genuine first bootstrap those jobs merely fail against resources that do
not exist. The bite comes later: an image-only rebuild once the environments are
up would `DROP DATABASE` / `CREATE DATABASE` on devtest and then deploy vanilla
Drupal to the dev VM — precisely what the flag exists to prevent.

**Fix:** the validate step normalises the flag to a string once and publishes it
as a job output; the three downstream jobs gate on
`needs.build-image.outputs.bootstrap`. Job outputs are always strings, so the
comparison is exact whatever the caller sends.

**Never compare `client_payload` fields directly in an `if:`.** Route them
through a job output, or through `env:` and a shell test, where the types are
knowable. Use `gh api -f` (string) rather than `-F` (magic type conversion) when
dispatching by hand.

---

### PostgreSQL client on the runner was older than the server — broke the first DB sync

**Filed 2026-07-30, fixed 2026-07-31. Never hit in practice; nothing had been
applied to Azure yet.**

`build-on-dispatch.yml` (job `prepare-database`) and `test-cloud-init.yml` both
installed the client from Ubuntu's default repo:

```bash
sudo apt-get install -y -qq postgresql-client
```

`ubuntu-latest` is Ubuntu 24.04, which ships **PostgreSQL client 16.14** — verified
against `actions/runner-images`. Our servers were **PostgreSQL 17** at the time
(now 18). `pg_dump` refuses to read a server with a newer major version than
itself, and there is no override; `--ignore-version` was removed years ago:

```
pg_dump: error: server version: 17.x; pg_dump version: 16.14
pg_dump: error: aborting because of server version mismatch
```

That would have failed on the very first dev-merge, before anything reached the
dev VM. lib-main is unaffected only because it runs PostgreSQL 16 and happens to
match the runner — coincidence, not design.

**Fix:** both workflows now add the PGDG apt repository and install
`postgresql-client-${PG_MAJOR}`. `PG_MAJOR` is a repo variable that also feeds
`TF_VAR_postgresql_version` in `deploy-production.yml` and
`deploy-on-main-merge.yml`, so the client and the server cannot drift apart. It
falls back to `18` — the Terraform default — when unset, so an incomplete
bootstrap still gets a matching pair rather than an invalid package name.

Note this only ever constrained `pg_dump`/`pg_restore`. Plain `psql` does no such
version check and would have kept working.

---

### Standardize on PostgreSQL 18

**Filed 2026-07-30, decided 2026-07-31. Was: "decide whether to move to 18".**

Was on **17**; now **18** everywhere. Nothing had been applied to Azure, so the
change cost nothing beyond the edits.

Why 18 won: `mccarthy-index`'s `.ddev/config.yaml` declares `postgres: 18`
(verified — `database.version: "18"` at line 11). Matching it makes local and
production identical and removes the version-drift caveat entirely, including the
sharp edge that a local PG 18 dump cannot be restored into a PG 17 server. The
case against — 18 being newer and less proven under Drupal 11 — was weak, since
the dev is already building against 18 locally; aligning shrinks the untested
surface rather than growing it. Drupal 11 requires >= 16 with no upper bound, and
`pg_trgm` is present in 18.

Verified before changing anything:

- `az postgres flexible-server list-skus --location eastus2` lists 18 among
  `supportedServerVersions`, and in-place `17 → 18` upgrades are supported, so
  this was reversible-ish either way.
- `azurerm` accepts `version = "18"` on `azurerm_postgresql_flexible_server` as of
  the 4.81.0 in `.terraform.lock.hcl` (the constraint is `~> 4.71`). Worth
  re-checking if that pin is ever lowered.

Changed together, and they must stay together: `modules/postgresql/variables.tf`,
`environments/production/variables.tf`, the `PG_MAJOR` repo variable seeded by
`bootstrap/azure-setup.sh`, and the `|| '18'` fallbacks in the four workflows.
devtest and dev inherit the module default and need no separate change.
