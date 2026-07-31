# TODO

Known issues and deferred work. Unlike lib-main-infra's equivalent, this file is
**committed** — a local-only note helps exactly one person.

Entries should carry enough evidence that the next person does not have to
re-derive the problem: what breaks, how it was verified, and what the fix is.

---

## Open

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
