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

**This will recur on every new storage account** — production has not been
applied yet and will hit it. Unblock with:

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

### App repo (`mccarthy-index`) is not wired to this pipeline

Tracked in the README's "Contract the app repo must satisfy" and in
`docs/bootstrap-runbook.md` step 8. Summary: no `.github/` directory, no `dev`
branch, no root `.gitignore`, no `az_blob_fs` (so media on a VMSS lands on local
disk and is wiped by every reimage), and DDEV declares PHP 8.4 against
production's 8.3.

---

### lib-main must move off `10.0.0.0/16` before it goes live

Not this repo's change, but it constrains the shared Solr plan and is recorded
here so the dependency is visible. lib-main's production VNet collides with the
Asimov AKS service CIDR. See the README's VNet address allocation section, and
lib-main-infra's own `README.md` / `docs/TODO.md` / `CLAUDE.md`.

---

## Resolved

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
