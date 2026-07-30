# TODO

Known issues and deferred work. Unlike lib-main-infra's equivalent, this file is
**committed** — a local-only note helps exactly one person.

Entries should carry enough evidence that the next person does not have to
re-derive the problem: what breaks, how it was verified, and what the fix is.

---

## Open

### PostgreSQL client on the runner is older than the server — breaks the first DB sync

**Filed 2026-07-30. Deferred by the user; noted rather than fixed.**

`build-on-dispatch.yml` (job `prepare-database`) and `test-cloud-init.yml` both do:

```bash
sudo apt-get install -y -qq postgresql-client
```

`ubuntu-latest` is Ubuntu 24.04, which ships **PostgreSQL client 16.14** — verified
against `actions/runner-images`. Our servers are **PostgreSQL 17** (`modules/postgresql/variables.tf`,
`environments/production/variables.tf`; devtest inherits the module default).

`pg_dump` refuses to read a server with a newer major version than itself:

```
pg_dump: error: server version: 17.x; pg_dump version: 16.14
pg_dump: error: aborting because of server version mismatch
```

There is no override — `--ignore-version` was removed from `pg_dump` years ago.

**Impact:** `prepare-database` fails on the very first dev-merge, before anything
reaches the dev VM. This is a first-run blocker, not a latent edge case.

**Why lib-main is unaffected:** it runs PostgreSQL 16, which happens to match the
runner's client. The alignment is coincidence, not design. This repo broke it by
moving to 17, and moving to 18 breaks it identically — anything above 16 does.

**Fix:** install the client from PGDG pinned to the server's major version, and
drive both from a single source so they cannot drift apart again:

```bash
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg
echo "deb https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update -qq
sudo apt-get install -y -qq postgresql-client-${PG_MAJOR}
```

Suggest a `PG_MAJOR` repo variable consumed by both the workflows and
`TF_VAR_postgresql_version`, so the server and client versions cannot diverge.

**Bundle this with the PostgreSQL 18 decision below** — both touch the same lines.

---

### Decide whether to move to PostgreSQL 18

**Filed 2026-07-30. Deferred by the user.**

Currently on **17**. PostgreSQL **18 is GA in eastus2** — verified with
`az postgres flexible-server list-skus --location eastus2`, which also confirms
in-place `17 → 18` upgrades are supported, so neither choice is a dead end.

The argument for 18: `mccarthy-index`'s `.ddev/config.yaml` already declares
`postgres: 18`. Moving production to 18 makes local and production identical and
removes the version-drift caveat entirely — including the sharp edge that a local
PG 18 dump cannot be restored into a PG 17 server. Nothing is deployed yet, so
the change is free today.

The argument against: 18 is newer and less proven under Drupal 11. Weak, though —
the dev is already building against 18 locally, so aligning shrinks the untested
surface rather than growing it. Drupal 11 requires >= 16 with no upper bound, and
`pg_trgm` is present in 18.

Touches: `modules/postgresql/variables.tf`, `environments/production/variables.tf`,
and the client-version fix above.

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
