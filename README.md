# mccarthy-infra

Infrastructure as Code for the `mccarthy` Drupal site.

**Status: scaffolding.** No Azure resources have been created and no pipeline has
run. See [docs/bootstrap-runbook.md](docs/bootstrap-runbook.md) to stand it up.

## The two-repo split

This is the **ops-owned** half of a pair, modelled on
[lib-main](https://github.com/utkdigitalinitiatives/lib-main) /
[lib-main-infra](https://github.com/utkdigitalinitiatives/lib-main-infra):

| Repo | Owner | Contains |
|---|---|---|
| [`mccarthy-index`](https://github.com/utkdigitalinitiatives/mccarthy-index) | devs | The Drupal 11 codebase. No build or deploy CI — only branch policy and cross-repo dispatch. |
| `mccarthy-infra` (this repo) | ops | Packer image build, Terraform per environment, all deploy workflows. |

Deployment is **VM-image based, not container based**. There is no container
registry anywhere in this system; the deployable artifact is an Azure Compute
Gallery image version.

```
app repo: feature -> dev  --(drupal-dev-merge)-->  build image 0.0.N
                                                   sync prod DB  -> devtest
                                                   sync prod blobs -> devtest
                                                   apply environments/dev (replace VM)
                                                   health check + email
   (a human validates the dev VM)
app repo: dev -> main     --(drupal-main-merge)--> resolve newest gallery image
                                                   apply environments/production (rolling, MaxSurge)
                                                   destroy environments/dev
```

## Architecture

- **Azure Load Balancer** (Standard, L4) → **VMSS** (Rocky Linux 9) → **PostgreSQL Flexible Server 18**
- **Azure Blob Storage** for Drupal media, via the `az_blob_fs` Drupal module
- **Azure Key Vault** for shared secrets, read at boot through managed identity
- **Azure Compute Gallery** for Packer-built images — *shared with lib-main-infra*
- TLS via Let's Encrypt on the VM (not on the load balancer), with certs
  persisted to blob storage so they survive reimages

Region `eastus2`. Production is deallocated overnight and at weekends by
`production-schedule.yml`; disable that workflow once the site is public-facing.

## Shared base image

This repo does **not** build a base image. `lib-main-infra` builds
`drupal-base-rocky-linux-9` monthly into `lib-main-images-rg/lib_main_gallery`,
and that image is pure Rocky 9 + PHP 8.3 + Apache + Composer with nothing
site-specific in it. This project publishes only its **app** image definition,
`mccarthy-rocky-linux-9`, into that same gallery.

Two consequences worth understanding before you rely on it:

1. **Drift.** A PHP or Apache change made for lib-main lands in mccarthy's next
   app image without warning. Set the `BASE_IMAGE_VERSION` repository variable
   to pin a known-good base; leave it empty to track the newest.
2. **Cross-project permission.** The `mccarthy-github-actions` service principal
   holds Contributor on `lib-main-images-rg`, which is lib-main's resource
   group. A custom role scoped to the single image definition is the tighter
   option if that is unacceptable.

If `lib-main-infra` ever tears down its images resource group, this project's
builds break. That coupling is the price of not duplicating a 27-minute monthly
build.

## VNet address allocation

Every library Drupal site is a **spoke**; the hub is the Asimov AKS cluster,
which hosts the SolrCloud these sites search against. Sites do not share a VNet
— each gets its own and peers to Asimov independently. Peering is
non-transitive, so every site reaches Solr and no site reaches another site.

Azure allows many peerings per VNet (the limit is 500), so the constraint is not
a count — it is that **address spaces must not overlap**. Two of the reserved
ranges below are non-obvious:

- `10.0.0.0/16` is Asimov's Kubernetes **service** CIDR. Peering a spoke on this
  range still *succeeds*, because Azure only validates VNet address spaces — but
  reply traffic to a VM at `10.0.1.x` can be intercepted inside the cluster as a
  ClusterIP. Microsoft documents this as unsupported; the failure is intermittent
  and hard to diagnose. `serviceCidr` is immutable after cluster creation, so the
  spokes are what must move.
- `10.1.0.0/16` is partly consumed by the `vireo-db` spoke, which is already
  peered to Asimov and deliberately sits clear of `10.0.0.0/16`.

**Reserved — never allocate from these:**

| Range | Owner |
|---|---|
| `10.0.0.0/16` | Asimov Kubernetes service CIDR |
| `10.1.0.0/16` | vireo-db spoke (`10.1.0.0/24`, `10.1.1.0/24`) |
| `10.224.0.0/12` | Asimov AKS node VNet |
| `10.244.0.0/16` | Asimov pod CIDR (Azure CNI overlay) |
| `172.16.0.0/16` | `dns-test-rg` |

**Per-site allocation — claim the next free /16 and add a row:**

| Range | Site | Status |
|---|---|---|
| `10.10.0.0/16` | mccarthy | allocated (this repo) |
| `10.11.0.0/16` | — | free |
| `10.12.0.0/16` | — | free |
| `10.20.0.0/16` | lib-main | **reserved for re-addressing** — lib-main currently sits on `10.0.0.0/16` and cannot cleanly peer to Asimov until it moves. Must happen before it goes live. |

Within a site: `x.x.1.0/24` web subnet, `x.x.2.0/24` private endpoints.

Verify against reality before allocating — `az network vnet list -o table` is the
authoritative source, not this table.

## Repository layout

```
mccarthy-infra/
├── .github/workflows/
│   ├── build-on-dispatch.yml      # drupal-dev-merge  -> build image, sync DB+blobs, deploy dev VM
│   ├── deploy-on-main-merge.yml   # drupal-main-merge -> production rolling deploy, destroy dev VM
│   ├── deploy-production.yml      # manual rollback / emergency deploy
│   ├── test-cloud-init.yml        # manual cloud-init iteration on an existing image
│   ├── dump-production-db.yml     # manual -> production dump into private blob, for local DDEV
│   └── production-schedule.yml    # nightly/weekend deallocate (cost control)
├── packer/
│   ├── plugins.pkr.hcl
│   ├── variables.pkr.hcl
│   ├── mccarthy-rocky9.pkr.hcl    # app image only; base comes from the shared gallery
│   └── ansible/                   # clone app repo -> composer install -> settings.php wiring
├── modules/                       # 7 reusable Terraform modules
├── environments/
│   ├── secrets/                   # shared Key Vault + RBAC        (apply 1st)
│   ├── devtest/                   # persistent PSQL + blob + auto-stop (apply 2nd)
│   ├── production/                # VNet, LB, PSQL, blob, VMSS     (apply 3rd)
│   └── dev/                       # ephemeral dev VM               (apply 3rd; CI only)
├── bootstrap/azure-setup.sh       # one-time Azure setup, idempotent
└── docs/
    ├── bootstrap-runbook.md   # stand it up from nothing
    └── TODO.md                # known issues and deferred work
```

**Apply order is load-bearing:** `secrets` → `devtest` → `production` / `dev`.
The dev stack reads `devtest-storage-account-key` from the vault.

Resource groups are created by `bootstrap/azure-setup.sh` and read by Terraform
via `data "azurerm_resource_group"`, not created by it. That is what allows the
CI service principal to be scoped per-resource-group instead of holding
subscription-wide Contributor.

## Authentication

Workflows authenticate to Azure with **GitHub OIDC federated credentials**.
There is no `AZURE_CLIENT_SECRET`; the service principal has no password
credential at all.

Federated credential subjects registered on `mccarthy-github-actions`:

| Subject | Covers |
|---|---|
| `repo:utkdigitalinitiatives/mccarthy-infra:ref:refs/heads/main` | `repository_dispatch` and `schedule` events, which always run on the default branch |
| `repo:utkdigitalinitiatives/mccarthy-infra:environment:production` | jobs declaring `environment: production` |
| `repo:utkdigitalinitiatives/mccarthy-infra:environment:dev` | jobs declaring `environment: dev` |
| `repo:utkdigitalinitiatives/mccarthy-infra:pull_request` | PR-triggered jobs |

Terraform state uses Entra auth (`use_azuread_auth=true`) rather than shared
storage keys.

## Repository configuration

### Secrets

| Secret | Notes |
|---|---|
| `AZURE_CLIENT_ID` | App ID of `mccarthy-github-actions` |
| `AZURE_TENANT_ID` | |
| `AZURE_SUBSCRIPTION_ID` | |
| `SSH_PUBLIC_KEY` | Authorized key for the `drupaladmin` account |

Application secrets (DB passwords, hash salts, storage keys, Postmark token)
live in Key Vault, not here.

### Variables

| Variable | Example | Set when |
|---|---|---|
| `PROJECT_NAME` | `mccarthy` | bootstrap |
| `STORAGE_PREFIX` | `mcc` | bootstrap |
| `LOCATION` | `eastus2` | bootstrap |
| `COST_CENTER` | | bootstrap |
| `GALLERY_NAME` | `lib_main_gallery` | bootstrap (shared) |
| `GALLERY_RESOURCE_GROUP` | `lib-main-images-rg` | bootstrap (shared) |
| `BASE_IMAGE_NAME` | `drupal-base-rocky-linux-9` | bootstrap (shared) |
| `BASE_IMAGE_VERSION` | *(empty)* | optional — pin the base image |
| `APP_IMAGE_NAME` | `mccarthy-rocky-linux-9` | bootstrap |
| `TF_STATE_RESOURCE_GROUP` | `mccarthy-tfstate-rg` | bootstrap |
| `TF_STATE_STORAGE_ACCOUNT` | generated | bootstrap |
| `DB_ADMIN_USERNAME` / `DB_NAME` | `drupaladmin` / `drupal` | bootstrap |
| `PG_MAJOR` | `18` | bootstrap — pins the server *and* the runner's `pg_dump` |
| `MEDIA_CONTAINER` | `drupal-media` | bootstrap |
| `PROD_DB_HOST` | `mccarthy-production-psql.postgres.database.azure.com` | bootstrap |
| `NOTIFY_EMAIL_TO` / `NOTIFY_EMAIL_FROM` | | bootstrap |
| `DEVTEST_DB_HOST` / `DEVTEST_STORAGE_ACCOUNT` | | after devtest apply |
| `PROD_STORAGE_ACCOUNT` / `SUBNET_ID` | | after production apply |
| `DRUPAL_SITE_UUID` | `542dcd94-b092-493d-9561-7361fe4c34bd` | before production apply — read from the app repo, never generated |
| `DOMAIN_NAME` / `PUBLIC_IP_ID` / `LB_DNS_LABEL` | | before production apply |

No workflow contains a hardcoded resource group, server, or storage account
name — all are derived from `PROJECT_NAME` or read from a variable.

## Contract the app repo must satisfy

`mccarthy-index` is public and partly wired: as of commit `bb2ea88` it dispatches
on pushes to `dev` and guards PRs into `main`. It cannot fire yet, because the
`dev` branch does not exist. The table below is the full contract; see
`docs/TODO.md` for which rows are already satisfied.

| Item | Value |
|---|---|
| Branch flow | `topic → dev → main`; PRs into `main` only from `dev` |
| On push to `dev` | dispatch `drupal-dev-merge` to `mccarthy-infra` with `client_payload[drupal_repo]` (clone URL), `[drupal_ref]=dev`, `[drupal_sha]` |
| On push to `main` | dispatch `drupal-main-merge` with `client_payload[drupal_sha]` |
| Auth | GitHub App token via `actions/create-github-app-token`, scoped `repositories: mccarthy-infra`; `vars.DISPATCH_APP_ID` + `secrets.DISPATCH_APP_PRIVATE_KEY`. Uses lib-main's `lib-dispatch` App (ID `2828711`), which must hold **`contents: write`** — the dispatch endpoint requires write, not read — and must list `mccarthy-infra` in its selected repositories. Both done 2026-08-04. |
| Config sync dir | `config/` at project root (`$settings["config_sync_directory"] = "../config"`) |
| Left empty in the repo | `$databases = []` and `$settings["hash_salt"] = ""` — infra injects both at boot |
| Site UUID | already set: `542dcd94-b092-493d-9561-7361fe4c34bd` in `config/system.site.yml`. Never re-generate — a reinstall+re-export changes it and breaks production config import. |
| Install profile | `minimal` in `config/core.extension.yml`; must match `drupal_install_profile` here |
| Branches | only `main` exists today; the pipeline needs a `dev` branch |
| Custom theme location | `web/themes/custom/` |

The event type names (`drupal-dev-merge` / `drupal-main-merge`) are deliberately
the same as lib-main's. Dispatches are scoped per-repository, so there is no
ambiguity, and keeping the names identical makes the two repos' workflows
diffable.

Two things the app repo should do that lib-main learned the hard way:

- **Retry and alert on the dispatch.** A dispatch POST once failed server-side
  in lib-main and no pipeline ran — silently, noticed only by manually checking
  the Actions tab. Wrap the `gh api` call in a retry with backoff and add an
  `if: failure()` notification.
- **`paths-ignore` on the dev dispatch** (`**.md`, `LICENSE.txt`,
  `.editorconfig`, `.gitattributes`, `.github/**`) so a README edit does not
  trigger a full image build.

## Differences from lib-main-infra

Greenfield was the cheapest moment to fix things lib-main-infra carries as
backlog. Deliberate divergences:

| | lib-main-infra | here |
|---|---|---|
| Azure auth | static `AZURE_CLIENT_SECRET` | OIDC federated credentials, no secret |
| SP scope | Contributor at subscription scope | Contributor per resource group |
| Resource groups | created by both bootstrap and Terraform (forces an import) | created by bootstrap, read by Terraform |
| Naming | `lib-main` / `drupal` hardcoded in `.tf` files | `var.project_name` + `var.storage_prefix` |
| Storage account name | `drupal` + env + 8 random = exactly 24 chars, no headroom | short prefix + abbreviated env = 15 chars |
| PostgreSQL | 16 | 18, matching the app repo's DDEV |
| VMSS size | `Standard_B2s` (restricted series) | `Standard_B2als_v2` |
| Dev-merge concurrency | workflow-level `cancel-in-progress: true`, which has killed applies mid-run twice | per-job: build cancels, apply queues |
| Action pins | mixed node20/node24, one floating `@main` | all pinned to node24 releases |
| `.terraform.lock.hcl` | gitignored | committed |
| Backend auth | shared storage keys | `use_azuread_auth=true` |
| Auto-stop runbook | subscription-wide query that silently matches nothing under RG-scoped permissions | scoped to the resource group, fails loudly |
| Base image | built here, monthly | consumed from the shared gallery |
| Operational docs | hidden via `.git/info/exclude` | committed |

Not carried over: the unmerged `private://` Azure Files share. It was
uncommitted work-in-progress in lib-main-infra that has never been applied, so
it is not a proven pattern to copy.

## Local Terraform

```bash
cd environments/<env>
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl -backend-config="use_azuread_auth=true"
terraform plan
```

Set `use_oidc = false` in `terraform.tfvars` for local runs — there is no GitHub
OIDC token outside CI, so the Azure CLI session is used instead.

**Do not apply `environments/dev` locally.** It is owned by CI and is destroyed
and recreated on every promotion to main.

This repository is public. `*.tfvars` and `backend.hcl` are gitignored because
they carry subscription IDs, tenant IDs, AAD object IDs, and SSH public keys —
commit only the `.example` templates.

## License

Public repository — UTK Libraries
