# lib-main-infra → mccarthy-infra: what changed and why

lib-main was the first Drupal site built on this general design; mccarthy is the
second. This document compares the two infrastructure repos and records the
lessons from operating lib-main that drove mccarthy's divergences.

**Comparison basis** (2026-08-03): lib-main-infra `origin/main` (`52e146d`)
against mccarthy-infra `8c49356`. lib-main-infra's uncommitted `private://`
Azure Files WIP is excluded — it has never been applied.

## What didn't change

The architecture is the same design, deliberately: Load Balancer → VMSS
(Rocky 9) → PostgreSQL Flexible Server, blob storage for media via
`az_blob_fs`, Key Vault secrets fetched at boot through managed identity,
Packer-built gallery images as the deploy artifact, the same
`secrets → devtest → production/dev` environment split, the same seven
Terraform modules, and the same `drupal-dev-merge`/`drupal-main-merge` dispatch
contract (event names kept identical on purpose so the two repos stay
diffable). Almost nothing about the *architecture* was revised. Nearly all of
the divergence is operational hardening — fixing, at greenfield cost, things
lib-main carries as backlog or learned through incidents.

## The main differences

### 1. Authentication: OIDC everywhere, no secrets, least privilege

lib-main uses a static `AZURE_CLIENT_SECRET` with subscription-wide Contributor
and shared-key access to Terraform state. mccarthy's service principal has *no
password credential at all* — four GitHub OIDC federated credentials instead —
is scoped Contributor per resource group, and state uses Entra auth
(`use_azuread_auth=true`). Packer's `client_secret` variable was deleted
entirely ("no static service principal secret to leak"). All three were
already on lib-main's backlog; mccarthy shipped them on day one.

### 2. Ownership boundaries: one creator per resource

In lib-main, both the bootstrap script and Terraform create resource groups,
which forces a `terraform import` on first apply. In mccarthy, bootstrap
creates all five RGs and Terraform only *reads* them
(`data "azurerm_resource_group"`) — which is also what makes the per-RG SP
scoping possible. The same principle applied to images: mccarthy builds **no
base image**. It deleted the base Packer template, the monthly
`base-image-build.yml` workflow, the `image-gallery` module, and the
marketplace-agreement bootstrap — it publishes only its app image definition
into lib-main's shared gallery. The tradeoff (base-image drift, cross-project
Contributor on `lib-main-images-rg`) is documented in the README rather than
discovered later.

### 3. Parameterization: "a third site is a tfvars change instead of a fork"

lib-main hardcodes `lib-main`, `drupal-*` resource names, the cost center,
storage account names, DB hosts, and email recipients throughout `.tf` files
and workflows. mccarthy derives everything from `project_name` /
`storage_prefix` variables and repo variables — no workflow contains a literal
resource name. This fixed two latent collisions the second site exposed:

- The storage account name: `drupal` + `production` + 8 random chars is
  *exactly* 24 characters — Azure's limit, zero headroom. mccarthy's scheme
  (short prefix + abbreviated environment) yields 15.
- The PostgreSQL server name, which is a **global** DNS label
  (`<name>.postgres.database.azure.com`), so `drupal-production-psql` could
  exist only once.

### 4. CI made incident-proof

The biggest one: lib-main's workflow-level `cancel-in-progress: true` killed
`terraform apply` mid-run twice (2026-03-09 and 2026-06-22), leaving an
unreleasable state-blob lease and, the second time, an orphaned half-replaced
VM. mccarthy splits concurrency per job — image builds cancel (safe), applies
**queue** — and adds cross-workflow groups so a manual rollback can never
apply against production concurrently with an automatic deploy.

Other CI fixes:

- The runner's `pg_dump` is installed from PGDG pinned to `PG_MAJOR` —
  Ubuntu's default client 16 flatly refuses to dump a newer server. lib-main
  only works because its PG 16 happens to match the runner: "coincidence, not
  design." `PG_MAJOR` also feeds `TF_VAR_postgresql_version`, so client and
  server cannot drift apart.
- All actions pinned to node24 releases (finishing lib-main's half-done
  migration, which included one floating `@main`).
- Image-version resolution sorts by `publishedDate`, because `0.0.99 > 0.0.100`
  lexicographically.
- Health checks actually fail the job instead of printing a warning — lib-main's
  `test-cloud-init` loop `break` let a never-healthy VM pass.
- A `bootstrap_build` payload flag lets the very first image build from vanilla
  Drupal before the app repo exists, with all downstream jobs gated off (and a
  guard against GitHub Actions' boolean/string coercion so the flag can't be
  spoofed by accident).

### 5. Module-level defect fixes with post-mortems in the comments

The auto-stop runbook is the sharpest example: lib-main's does a
subscription-wide server query under RG-scoped permissions, gets an empty
result, and reports `Completed` while stopping nothing — it ran that way
undetected for at least four consecutive weeks. mccarthy's takes a mandatory
resource-group parameter, sets `$ErrorActionPreference = "Stop"`, and
**throws** when it finds zero servers or any stop fails.

Related fixes in the same spirit:

- The automation schedule's start time is computed (`plantimestamp()` + offset,
  with `ignore_changes`). lib-main's hardcoded `2026-02-13T22:00:00-05:00`
  default "was a time bomb … and duly went off" — Azure rejects start times in
  the past.
- The media SAS window moved from hardcoded literals to
  `media_sas_start`/`media_sas_expiry` variables with a "put it on a calendar"
  warning (deliberately *not* `timestamp()`, which would reissue the SAS and
  reimage the VMSS on every apply).
- `lifecycle { ignore_changes = [runbook_type] }` suppresses an azurerm 4.81
  provider misread that otherwise forces a phantom runbook replacement on every
  plan (tracked in TODO to remove when fixed upstream).

### 6. Knowledge is committed, not local

lib-main's real runbook, TODO, and CLAUDE.md are hidden via
`.git/info/exclude` — invisible on GitHub. mccarthy commits
`docs/bootstrap-runbook.md` (a full stand-it-up-from-nothing procedure, ending
with a "rough edges inherited from lib-main" table) and `docs/TODO.md`, whose
opening line is the lesson verbatim: *"a local-only note helps exactly one
person."* Likewise:

- `.terraform.lock.hcl` is committed — lib-main gitignores it, so provider
  versions drift between operators.
- Every environment has `backend.hcl.example` / `terraform.tfvars.example`
  (lib-main's devtest had neither).
- Examples use placeholders. lib-main's committed examples leak the real state
  storage-account name, subscription ID, and four developers' AAD object IDs in
  a public repo; mccarthy moves all of those to gitignored files.

### 7. Platform choices made with current information

- **PostgreSQL 18** instead of 16 — chosen to match the app repo's DDEV config
  exactly, eliminating the local-dump-won't-restore drift class. lib-main has
  "upgrade to 17" sitting in its backlog.
- **VMSS default `Standard_B2als_v2`** instead of `Standard_B2s`, sidestepping
  the Bs-v1 series retirement lib-main still has queued (with an explicit
  warning not to pick the Arm64 `Bpsv2` variants, which won't boot the x64
  images).
- **VNet `10.10.0.0/16`** from an explicit allocation registry in the README.
  Allocating mccarthy's range is how it was discovered that lib-main sits on
  `10.0.0.0/16` — which collides with the Asimov AKS *service* CIDR, meaning
  lib-main must be re-addressed (a full production-network rebuild) before it
  can peer to shared Solr.

## The lessons, distilled

1. **Silent success is the worst failure mode.** The auto-stop runbook that
   "succeeded" for a month doing nothing, the dispatch POST that failed
   server-side with no alert (2026-05-04), the health-check loop whose `break`
   let a never-healthy VM pass — every one became a fail-loudly pattern in
   mccarthy: throw on empty results, `::error::` annotations, health checks
   that fail the job, and a dispatch retry+alert requirement written into the
   app-repo contract.

2. **Never cancel an apply.** Two stale-lock/orphaned-resource incidents
   produced mccarthy's asymmetric concurrency: cancel builds freely, queue
   applies always.

3. **Hardcoded values are time bombs; wrong-but-present defaults are worse
   than no default.** The schedule start-time that expired, the stale
   `base_image_version` default ("builds silently on an ancient base — callers
   must be explicit"), the stale `image_version` in tfvars that silently
   reimages production to an older build, the zero-headroom storage name.
   mccarthy's response is uniform: parameterize, require explicitness, and
   document the footguns that remain at the exact spot you'd trip them.

4. **Every resource needs exactly one owner.** Bootstrap *or* Terraform
   creates a thing, never both; one repo owns the base image and the other
   consumes it. This also unlocked least-privilege CI, and where a new coupling
   was accepted (the shared gallery), its failure modes were written down up
   front.

5. **Version agreement must be enforced, not coincidental.** lib-main's
   `pg_dump` works by luck; mccarthy makes `PG_MAJOR` a single source of truth
   feeding both the server and the runner client, and picked PG 18 specifically
   because the dev already builds against it locally.

6. **If it isn't committed, it doesn't exist.** Runbook, TODO, lockfile,
   per-env examples — all in the repo now, with the secret-hygiene discipline a
   public repo demands.

7. **The second instance is when the first one's debt comes due.** Name
   collisions, address-space collisions, and hardcoding are all invisible with
   one site. Notably, the flow of lessons ran both ways: building mccarthy is
   what surfaced lib-main's most serious latent problem (the Asimov CIDR
   collision, now the top blocker in lib-main's own TODO).

## Follow-ups surfaced by the comparison

- `environments/dev/cloud-init.tftpl` has a self-signed cert subject of
  `/CN=dev-vm/O=/OU=dev` — the empty `O=` looks like an incomplete substitution
  when de-lib-main-ifying it (harmless; openssl accepts it).
- Both repos' dev environment still carries the "TEMPORARY: D10 news migration
  source (Pantheon MySQL)" block, which is lib-main-specific and likely dead
  weight in mccarthy.
