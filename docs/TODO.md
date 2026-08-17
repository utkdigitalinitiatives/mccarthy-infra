# TODO

Known issues and deferred work. Unlike lib-main-infra's equivalent, this file is
**committed** — a local-only note helps exactly one person.

Entries should carry enough evidence that the next person does not have to
re-derive the problem: what breaks, how it was verified, and what the fix is.

---

## Open

### `config:import` cannot install az_blob_fs — the first deploy of the blob wiring broke dev while its health check passed

**Found 2026-08-13 on run `31713551667` of `build-on-dispatch.yml` — the first
dispatch-driven deploy of image `0.0.6`, carrying PR #5's blob wiring. The
eighth consecutive first-run defect. Dev recovered by hand the same day;
cloud-init fixed in both templates. Production never ran the broken path — but
it would have on the next `dev → main` promotion, and its health check would
have reported the deploy green.**

The run: Build Image ✅ → Sync Blob ✅ → **Prepare Database ✅ — the first time
this workflow's own copy of the password fix ever ran** → Deploy Dev ❌ on the
"Surface cloud-init logs" gate. So `build-on-dispatch.yml` has still never gone
green end to end, but every job in it has now executed from a dispatch.

**Mechanism, in order:**

- The dev VM took the update path (devtest DB freshly synced from production,
  which does not have the modules). `config:import` saw three operations:
  create `az_blob_fs.settings`, create `key.key.azure_blob_key`, update
  `core.extension`. Its extension sync installed `key`, then crashed installing
  `az_blob_fs`: **"You have requested a non-existent service az_blob_fs."**
  Installing a module that registers a stream wrapper inside drush's in-process
  container rebuild is a known Drupal failure class (s3fs has the same issue).
- The crash left `core.extension` updated but the install unfinished and
  neither config created. Every subsequent bootstrap — web and drush alike —
  fataled: first "The key entity type does not exist", then, after a cache
  wipe, `Call to a member function getKeyValue() on null` in
  `AzBlobFsService.php:101`. The wrapper's client construction reads the key
  entity named by environment.php's `$config` override, and that entity did
  not exist. **The override is what makes it fatal** — with no key name
  configured, the same code returns null gracefully.
- **The site returned 500 on every page while `/health` returned 200** — the
  health endpoint does not bootstrap Drupal. "Run Dev Validation Tests" passed
  against a fully broken site; only the log grep caught it, and only via the
  dishonestly-worded "Config import failed (may be no changes), continuing..."
  swallow. This is the TLS incident's blindness one layer deeper, and it is
  exactly how a production deploy of this defect would have reported success.
  `drush config:import -y` exits 0 when there is nothing to import, so that
  "may be no changes" branch only ever fired on real failures.

**Recovery (dev, by hand over SSH):** commenting the `az_blob_account_key_name`
override in `/etc/drupal/environment.php` restored `drush cr` but not
`config:import` or `php:eval` — the wrapper still threw during both — so both
configs were hand-serialized with plain `php -r` + `symfony/yaml` and inserted
into the `config` table via `drush sql:query` (which never bootstraps), caches
truncated by SQL, override restored, `drush cr`. Verified: `config:status`
clean against sync, site 200, title "Cormac Index".

**az_blob_fs then executed for the first time in this stack, and it works:**
`azblob://` write, read, and delete against devtest's `drupal-media` container
all succeeded. Note a `drush cr` is required after the modules and config land
before the wrapper functions.

**The fix, rehearsed end to end on the dev VM** (modules uninstalled cleanly,
then reinstalled from the exact state production's DB will be in on promotion
day): both cloud-init templates now pre-install the modules in **separate drush
processes** before `config:import` — `drush en key` → seed
`key.key.azure_blob_key` alone via `config:import --partial --source=<tmpdir>`
→ `drush en az_blob_fs`. Standalone `drush en az_blob_fs` does not hit the
container crash; that was verified, not assumed. Every step is a no-op once the
DB has the modules, and the block guards on the module directory existing, so
DBs already carrying the modules and codebases without them are both
unaffected. Also fixed alongside, because they were load-bearing in the
incident: the "may be no changes" swallow is gone (production now exits 1 on a
failed import, reading `PIPESTATUS[0]` since `| tee` masks the status — the
same masking as the TLS entry's third defect), and production's fresh-install
branch, which had the identical landmine in
`drush en key az_blob_fs || true` before any config exists, now calls the same
function.

**VERIFIED IN PRODUCTION 2026-08-13.** The `test-cloud-init.yml` rehearsal was
deliberately skipped; PR #6 (`dev → main`, same day) promoted the change and
run `31720848832` reimaged production with the fixed cloud-init — the block's
first execution from a template render, against the real no-modules production
DB. Verified by the site, not the checkmark: HTTPS 200 on `/` and
`/user/login` with the Cormac Index title (a failed import 500s every page),
HTTP→HTTPS 301 intact. The TLS blob-restore branch also ran for the first time
with content present and **restored rather than reissued** — the serving cert's
serial is byte-identical to the pre-deploy snapshot
(`0622AB63B506FB5D893F7BAAB1D18B855202`, notAfter 2026-11-09). Two
never-executed paths ran clean on their first try — the first first-runs in
this repo's history to do so.

**Still open:**

- **lib-main-infra's cloud-init has the same defect** — the files are
  near-copies; verified line-for-line 2026-08-13
  (`production/cloud-init.tftpl:276-277,300` there). Dormant only because
  lib-main's production DB already has az_blob_fs installed; a reinstall from
  a clean DB or any future stream-wrapper module hits it. Decision 2026-08-13:
  not ported for now.
- ~~`/health` has now let two incidents through (TLS, this).~~ **Fixed in code
  2026-08-17, not yet exercised by a deploy.** Every check step now runs a
  Drupal gate after the `/health` gate: `GET /user/login`, requiring **both** a
  200 **and** the string `user_login_form` in the body, because an error page
  can be served with a 200. All four workflows carry it —
  `deploy-on-main-merge.yml`, `deploy-production.yml`, `build-on-dispatch.yml`
  ("Run Dev Validation Tests"), `test-cloud-init.yml`. The two production
  workflows also gained the TLS gate described in the TLS entry below, so their
  order is liveness (HTTP) → TLS (HTTPS) → Drupal. The marker was verified
  against the live production login page on 2026-08-17, and the failure paths
  were verified against a non-Drupal 200 and an unreachable host. **Both
  incidents that got through would now fail the deploy.** Per this repo's own
  record, treat the first run of these gates as a first run.

---

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

### App repo (`mccarthy-index`) — step 8 complete; follow-ups open

**Step 8 landed 2026-08-11. All ten bootstrap steps are now done.** Production
serves the `mccarthy-index` codebase from image `0.0.5`. The README's "Contract
the app repo must satisfy" is the authoritative list; the items below are
follow-ups, and none of them block the pipeline.

**2026-08-11 — the production path ran for the first time.** PR #4 (`dev → main`)
merged at 12:17:33Z as commit `0ea7518`; `dispatch-main-merge.yml` fired and was
accepted on its first attempt; `deploy-on-main-merge.yml` (run `31490534785`) ran
its production path end to end — gallery query → `0.0.5` → apply on
`environments/production` → rolling reimage → health check → dev stack destroyed.
Every step reported success. VMSS instance `2` runs `0.0.5`, and the site serves
`<title>Log in | Cormac Index</title>` in place of the vanilla Drupal in `0.0.4`.

**That green run still took HTTPS down for 25 minutes**, and the workflow could
not see it. See "The first production reimage broke TLS while the deploy reported
success" under Open. Recovered by hand at 12:46Z.

**Correcting the 2026-08-10 text that used to sit here.** It claimed PR #2's merge
"drove the whole chain for the first time: dispatch → image `0.0.5` → blob sync →
devtest DB sync → first-ever apply of `environments/dev/`". That conflates two
separate runs and overstates what the dispatch chain proved. What actually ran:

- `build-on-dispatch.yml` run `31400881287`: **Build Image ✅ → Sync Blob Storage
  ✅ → Prepare Database ❌ → Deploy Dev ⏭️ skipped.** Image `0.0.5` was genuinely
  the first ever built from the app repo and the blob sync did run, but the chain
  died at the database step on the password defect below.
- The devtest DB sync and the **first-ever apply of `environments/dev/`** were
  proven separately by a manual `test-cloud-init.yml` run (`31418568438`) after
  both fixes landed. Different workflow, different code path.

So **`build-on-dispatch.yml` has still never completed end to end**, and the
password fix has only ever been exercised in `test-cloud-init.yml`'s copy of it.
The next merge to `dev` remains a first run for that workflow.

Two defects surfaced on 2026-08-10, both fixed the same day — the first two
entries under Resolved below. Both had a **comment directly above the broken line
asserting the false premise**, so reading the code argued *for* the bug.

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
- **DONE 2026-08-10 — `environments/dev/` applied** for the first time, after the
  RG fix below — through `test-cloud-init.yml`, not through the dispatch chain.
  **DONE 2026-08-11 — `deploy-on-main-merge.yml`'s production path fired** and
  reported success; it had previously only ever run in `cleanup_only` mode. It
  still surfaced a latent defect, as every first run in this repo has. See the CI
  note at the bottom of this file.
- **DONE 2026-08-10 — GitHub environments `dev` and `production` created**, both
  with **zero protection rules**, byte-identical to lib-main's. This entry used to
  say to create `production` with a required reviewer. **That was the wrong layer**
  and the advice is withdrawn. Environment gates fire *after* the push event, in
  the middle of the deploy job; the `dev → main` PR approval already happened
  *before* the merge that fires the dispatch. Gating both means approving the same
  decision twice. lib-main reached the same conclusion — it removed its
  `production-approval` and `dev-review` environment gates on 2026-03-03 (commits
  `d0a2012`, `f72164c`, no rationale recorded; the orphaned environments still
  exist there, referenced by no workflow). **The layer that actually gates
  production is the rulesets on `mccarthy-index`** — see the branch-protection
  item below. The environments are still worth having for deployment history and
  as a home for environment-scoped secrets.

App-repo side:

- **PARTLY DONE 2026-08-04 — workflows.** `mccarthy-index` commit `bb2ea88` adds
  `dispatch-dev-merge.yml` (push to `dev`, with `paths-ignore` and a 5-attempt
  retry) and `dev-to-main.yml` (fails PRs into `main` from any head but `dev`).
  Both carry an `if: failure()` step that opens — or comments on — an issue
  holding the exact re-dispatch command, because lib-main lost a pipeline run to a
  silent server-side dispatch failure that nobody noticed. Adapted from
  `lib-main`'s equivalents, which have neither the retry nor the alert.
- **DONE 2026-08-10 — `dispatch-main-merge.yml` landed.** Held back until then
  because **`on: push: branches: [main]` fires on the very push that adds the
  file** — GitHub evaluates workflows from the pushed commit — so committing it
  would have triggered a first-ever, unattended, unreviewed production deploy.
  The hold was lifted once `main` required an approved PR (rulesets, below), which
  makes the deploy it fires reviewed by construction. It went in via `dev` first
  (PR #3): landing it on `dev` is inert because `dispatch-dev-merge.yml` lists
  `.github/**` in `paths-ignore`. It deliberately carries no `paths-ignore` itself,
  unlike the dev dispatch, because the main-merge event also destroys the dev VM
  and skipping a docs-only merge would leave that VM running and billing.
  **It is now live: the next merge to `main` deploys production.**
- **DONE 2026-08-07 — `dev` branch created** at `bb2ea88`, same tip as `main`.
  Creating it emitted a `push` event on `dev` but triggered nothing, because that
  commit's diff is entirely `.github/**`, which `dispatch-dev-merge.yml` lists in
  `paths-ignore`. **The next push to `dev` that touches real files is the first
  end-to-end pipeline run** — Packer build, `DROP`/`CREATE` on the devtest
  database, blob sync, and the first-ever apply of `environments/dev/`. Expect
  first-run defects.
- **DONE 2026-08-10 — branch protection, via rulesets.** Ported lib-main's two
  rulesets to `mccarthy-index`, diff-identical to the originals: **`dev-review`**
  on `refs/heads/dev` and **`dev-to-main`** on `refs/heads/main`. Each requires a
  PR with 1 approving review, dismisses stale reviews on push, allows merge
  commits only, and blocks force-push and deletion; `dev-to-main` additionally
  requires the **`enforce`** status check, which is the job name in
  `dev-to-main.yml` in both repos. `bypass_actors: []` on both.

  **Look for rulesets, not classic branch protection.** `GET
  /repos/{o}/{r}/branches/{b}/protection` returns **404 on all four repos**
  (`lib-main`, `lib-main-infra`, `mccarthy-index`, `mccarthy-infra`) — that 404
  means "no *classic* protection", not "unprotected". lib-main's enforcement was
  invisible until `GET /repos/{o}/{r}/rulesets` was checked. Use
  `/rules/branches/{b}` to see what actually applies to a branch.

  This is what makes `dev-to-main.yml` load-bearing: before, the workflow ran but
  nothing required it to pass. It proved itself the same day — PR #1
  (`security/guzzle-7.15.2 → main`) failed the check in 6 seconds for having a
  non-`dev` head, and PR #4 (`dev → main`) passed it.

  Two consequences. **You cannot approve your own PR**, so a solo change to
  `mccarthy-index` needs a developer's approval. And `gh pr merge` fails with
  `the base branch policy prohibits the merge`; `--admin` forces it, which
  defeats the control.

  **STILL OPEN — a standing bypass actor was added to `dev-to-main` on
  2026-08-11** so that PR #4 could be merged without a second reviewer: user
  `26966411`, `bypass_mode: "always"`. **"always" is not one-shot.** It exempts
  that account from the review requirement on *every* future `dev → main` PR,
  silently and indefinitely. The `enforce` status check still applies; the
  human-approval half no longer does. Remove it now that the production path is
  proven — otherwise the control only binds people who are not the person who
  normally merges. `dev-review` on `refs/heads/dev` still has `bypass_actors: []`.
- still no root `.gitignore`, so `vendor/` and `web/core/` are one `git add -A`
  away. Mitigate in the meantime with `composer update <pkg> --no-install`, which
  updates `composer.lock` without ever materialising `vendor/`.
- **DONE 2026-08-10 — the six `guzzlehttp/guzzle` Dependabot alerts are cleared.**
  `composer.lock` only: guzzle 7.13.2 → **7.15.3**, plus `guzzlehttp/promises`
  2.5.0 → 2.5.2 and `guzzlehttp/psr7` 2.12.3 → 2.13.0, which move out of necessity
  — guzzle 7.15.3 requires `promises ^2.5.2` and `psr7 ^2.13`, so a guzzle-only
  partial update cannot resolve. Nothing else changed; the package count held at
  104 and `composer.json`'s content hash is unchanged. This was the intended first
  exercise of the pipeline and it worked as designed, flushing out both defects
  recorded below.

  **Resolution is unpinned and that is a latent hazard.** Neither this repo nor
  `lib-main` sets `config.platform.php`, and neither declares a root
  `require.php`, so `composer update` resolves against whatever PHP is running:
  8.5 on the workstation used here, 8.4 in `.ddev/config.yaml`, **8.3 on the base
  image** (`packer/variables.pkr.hcl:120`). A lock resolved locally can therefore
  contain packages the image cannot install. It did not bite here — all three
  packages require `php ^7.2.5 || ^8.0`, verified before committing — but that was
  luck.

  **Pinned 2026-08-11 on `mccarthy-index` branch `feat/az-blob-fs`, merged to
  `dev` 2026-08-13 (PR #5):**
  `config.platform.php` is set to `8.3`, and `composer.lock` now records
  `platform-overrides: {"php": "8.3"}`. Pinning it *before* adding az_blob_fs is
  what makes that resolution trustworthy — and it moved nothing already locked,
  so the pin is free to adopt. **`lib-main` is still unpinned and has the same
  hazard.**

**Blob storage was never wired into the app repo. Fix prepared 2026-08-11 on
`mccarthy-index` branch `feat/az-blob-fs` (commit `a0af263`), merged to `dev`
2026-08-13 as PR #5 (merge `2edd4eb`), and promoted to production the same day
via PR #6 — production now runs image `0.0.6` with both modules installed.
Both merges used `gh pr merge --admin`, because no second reviewer was in the
loop (`dev-review` has no bypass actors; `dev-to-main`'s standing bypass actor
evidently does not satisfy the API merge) — the same control gap as the
bypass-actor entry above, disclosed here for the same reason.**

**The infra half has been complete since bootstrap**, and is recorded here so
nobody re-derives it: a private `drupal-media` container (verified 2026-08-11 —
it exists and holds **zero blobs**), the VMSS identity holding Storage Blob Data
Contributor, the account key mirrored to Key Vault as
`production-storage-account-key` and substituted into `settings.php` at boot by
`fetch-secrets.sh`, and an Apache reverse proxy mapping `/drupal-media/*` to the
blob endpoint with a read-only SAS (`cloud-init.tftpl:448-449`). That proxy is
what makes `az_blob_cdn_host_name = ${domain_name}` coherent rather than wrong.
**The SAS expires 2028-01-01** (`var.media_sas_expiry`) — a hard date somebody
must roll before media stops being served.

What was missing was entirely app-side: `composer.json` required **neither
`drupal/az_blob_fs` nor `drupal/key`**, and neither appeared in
`config/core.extension.yml`, while cloud-init unconditionally writes
`$config['az_blob_fs.settings'][...]` and `$config['key.key.azure_blob_key'][...]`
into `settings.php`. So every override landed on configuration that does not
exist — and **a `$config` override cannot bring a config entity into being**,
which is why `key.key.azure_blob_key` needed an exported shell rather than just a
module.

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
- **The reverse also bites.** Enabling the modules without exporting their config
  is not stable either: a full `config:import` deletes active configuration that
  is absent from the sync directory. Modules and their config files have to land
  together.

The real trigger is **the day someone adds an image or file field to `record`**:
files then land on VMSS local disk and are wiped by the next reimage, silently.
Cheap now, expensive later.

**What the fix does** (`feat/az-blob-fs`, one commit, merged 2026-08-13):

- `composer require drupal/az_blob_fs:^3.0 drupal/key:>=1.15`, resolving to
  **az_blob_fs 3.0.0 and key 1.22.0 — the exact versions lib-main runs** — plus
  `microsoft/azure-storage-blob` 1.5.4 and `azure-storage-common` 1.5.2. 104
  packages to 108, **0 updates and 0 removals**, so nothing already locked moved.
  Note `microsoft/azure-storage-blob` is **abandoned upstream** with no suggested
  replacement; lib-main carries the same dependency.
- Both modules added to `core.extension.yml`. az_blob_fs declares `key:key` and
  `drupal:image`; `image` was already enabled.
- `az_blob_fs.settings.yml` and `key.key.azure_blob_key.yml` exported as empty
  shells for cloud-init's overrides to land on. The former is copied from
  lib-main, and its `_core.default_config_hash` was **verified** to be
  `Crypt::hashBase64(serialize())` of az_blob_fs 3.0.0's own
  `config/install/az_blob_fs.settings.yml` — so it is a genuine module default,
  not a snapshot of another site's settings. The latter carries a freshly minted
  UUID rather than lib-main's.
- Pins `config.platform.php` to `8.3`, which is what made the resolution above
  trustworthy. See the unpinned-resolution note under the guzzle entry.

**`$settings['file_default_scheme']` is inert. Verified 2026-08-11 — this is no
longer an open question.** It was previously filed here and in
`docs/bootstrap-runbook.md` as "unverified, worth ten minutes on devtest". No
devtest run was needed; Drupal 11 core settles it:

- **Zero** occurrences of `Settings::get('file_default_scheme')` anywhere in core
  or contrib. The name survives only as a *form key*:
  `core/modules/system/src/Form/FileSystemForm.php:132-135` declares it with
  `'#config_target' => 'system.file:default_scheme'`.
- Every consumer reads config instead — `FileItem.php:64` (which is what supplies
  a new file field's default `uri_scheme`), `ImageStyle.php:234,543`,
  `ImageThemeHooks.php:234`, `ThemeSettingsForm.php:495`.

So the line cloud-init writes has never done anything, in **either** project.
What actually governs is `config/system.file.yml`, and both repos export it with
`default_scheme: public`, which `config:import` re-asserts on every deploy.
**lib-main is unaffected in practice only because it sets `uri_scheme: azblob`
explicitly on all five of its file field storages** — the default is never
consulted. Two consequences:

- The `feat/az-blob-fs` branch deliberately leaves `default_scheme: public`,
  matching lib-main. Switching it to `azblob` would also apply to DDEV, which has
  no Azure credentials. **Set `uri_scheme: azblob` per field instead** when file
  fields are added to `record`.
- If a site-wide default is ever wanted, the correct override is
  `$config['system.file']['default_scheme']`, not `$settings[...]`. The dead line
  sits at `environments/production/cloud-init.tftpl:75` and
  `environments/dev/cloud-init.tftpl:71` **in this repo and in `lib-main-infra`
  alike** — the files are near-copies, down to the line numbers. Not removed here
  because editing cloud-init changes `custom_data`, which is a VMSS model change
  and therefore a reimage; it is harmless where it sits, so it should ride along
  with the next change that reimages anyway.

Not a defect, just a difference: DDEV declares PHP 8.4 against production's 8.3.
Core needs >= 8.3. PostgreSQL matches at 18 on both sides since 2026-07-31.

---

### Staying on `az_blob_fs` is a decision, not an accident — here are its triggers

**Decided 2026-08-13**, at the moment the app-side wiring above was ready to
merge — the cheapest point there will ever be to switch, since the site has no
files. Recorded so the dependency risk stays a scheduled decision rather than a
silent one.

The concern was building a new site on a deprecated dependency. What is actually
abandoned is **`microsoft/azure-storage-blob`**, the SDK underneath — Microsoft
archived its PHP SDKs in November 2023. The module on top is not: verified
2026-08-13, **az_blob_fs 3.0.0 was released 2026-02-18**, declares
`^10 || ^11`, is covered by the Drupal Security Team, has four maintainers and
~406 reported installs, and its issue queue carries an active refactor replacing
the SDK with direct REST calls (SAS and Entra service-principal auth). So the
bad dependency has a plausible expiration date via a normal module update.

The alternatives were checked and do not escape the SDK:

- League's official Flysystem Azure adapter depends on the **same** archived
  SDK; the Drupal glue modules (`flysystem_azure`, `flysystem_az_blob`) are less
  maintained than az_blob_fs itself.
- The healthy replacement stack is community **Azure-OSS**
  (`azure-oss/storage-blob-flysystem`, 2.2.0 released June 2026), but nothing in
  Drupal contrib wires it in — using it today means custom stream-wrapper glue
  we would own, which is worse for template legibility than the drift it avoids.
- The SDK-free architecture is an Azure Files mount with plain local files — a
  redesign of infra (proxy, SAS, Key Vault, cloud-init) that is already deployed
  blob-shaped in both projects.

**The plan: adopt az_blob_fs's REST refactor when it ships stable — on mccarthy
first, then lib-main.** mccarthy has no files, so it is the free pilot; lib-main
has real data and inherits a proven path. Drift in service of the intended
future standard, not a fork.

Reopen this decision if any of these fire:

- the REST refactor releases stable (adopt it), or its issue goes quiet for a
  year
- az_blob_fs loses security-team coverage or the maintainers stop responding
- a PHP bump breaks the archived SDK — the image is pinned to 8.3, so this
  moves at our pace, but check `composer why` + a devtest build before any bump
- lib-main starts its own migration for any reason: do not let the two projects
  pick different replacements

Fallback if the module dies before the refactor lands: Azure-OSS with custom
Flysystem glue, or the Azure Files mount — both real design work, neither to be
done as a side effect of something else.

**az_blob_fs first executed in this stack on 2026-08-13** — not via a file
field (none exist yet) but via a manual `azblob://` write/read/delete smoke
test on the dev VM after the deploy failure recorded above, and it works on
Drupal 11.4.1. The day file fields are added to `record`, still smoke-test
upload and serve through the real UI on devtest before promoting — the wrapper
working is not the same as image derivatives and the `/drupal-media/*` proxy
path working.

---

### The first production reimage broke TLS while the deploy reported success

**Found 2026-08-11 on the first-ever production deploy. Recovered by hand the
same day; the code that allowed it is unchanged.**

`deploy-on-main-merge.yml` run `31490534785` was green on every step, health check
included. HTTPS was down for 25 minutes — 443 closed, no HTTP→HTTPS redirect — and
nothing in the run said so.

Four things had to line up. **Three of them are still true.** Only the empty
container has been addressed, and only by hand — the code that emptied it is
unchanged:

**1. The cert was not in blob storage, and never had been.** `tls-setup.sh`
restores `$DOMAIN/fullchain.pem` and `privkey.pem` from the `tls-certs` container
before falling back to certbot. The container held **zero blobs**:

```
[2026-08-11 12:21:04] [tls-setup] No certificate found in blob storage
```

The Aug 3 certificate had only ever existed on the old instance's disk and died
with it. **Probable cause: `upload_blob` never checks whether the upload worked** —
`curl -s -X PUT ...` with no status test, and `set -e` will not catch it because
curl exits 0 on an HTTP error. Production's first apply deliberately ran with
`enable_vmss_blob_access = false` (the two-pass bootstrap noted in
`environments/production/terraform.tfvars`), so the VMSS identity had no data-plane
access when `tls-setup.sh` ran; the second pass granted it but did not reimage, so
the script never ran again. Consistent with every fact available, but the Aug 3
instance is gone along with its log — inference, not proof. `docs/bootstrap-runbook.md`
asserted the deploy hook "re-uploads to the `tls-certs` container": true of the
code, never true of the container.

**2. certbot ran before the new instance was serving the public IP.** Falling
through to Let's Encrypt, the HTTP-01 challenge was fetched and got a **404**:

```
Detail: 132.196.154.18: Invalid response from
http://libtest1.lib.utk.edu/.well-known/acme-challenge/xhcy...: 404
```

The file existed — on the new instance. `runcmd` order is `fetch-secrets` →
`drupal-init` → `tls-setup` → `restart php-fpm` → `restart httpd`, so certbot runs
while the instance is still mid-cloud-init, before its own httpd restart and
before the load balancer has moved traffic to it.

**What is proven:** instance 2's httpd access logs contain **no acme-challenge
request at that time at all**, so the validation never reached the machine that
wrote the file. The path itself is fine — verified after the fact at 200 locally
and 200 on five consecutive external fetches. **What is inferred:** that the
outgoing `0.0.4` instance answered the challenge. That fits the timing and the
404, but that instance is gone and its logs with it, so it is not established.
Either way the conclusion holds — issuance depended on which backend the load
balancer happened to be using, which `tls-setup.sh` has no way to know.

Aug 3 did not hit this because a first apply has no outgoing instance to race.

**3. `set -e` did not catch the certbot failure.** `certbot certonly ... 2>&1 |
tee -a "$LOG_FILE"` exits with **tee's** status, which is 0. The script continued
and died one line later on `cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem`, so
the visible error is a missing file rather than a refused certificate — the same
shape as the two defects found on 2026-08-10, where the failure was disguised as
something else.

**4. The deploy's health check cannot detect any of this.** It requests
`http://$DOMAIN/health` — deliberately plain HTTP, per the comment, to dodge a
cert-warmup race. A TLS failure is therefore invisible to it by construction, and
a deploy that leaves 443 dead looks exactly like a good one.

**Recovery:** `/opt/tls-setup.sh && systemctl restart httpd` via `az vmss
run-command invoke` on instance 2 at 12:46Z. It issued a cert (valid to
2026-11-09), uploaded both PEMs — **populating `tls-certs` for the first time
ever** — wrote the vhost and brought 443 up. Verified: HTTPS 200, HTTP 301, cert
`CN=libtest1.lib.utk.edu` issued by Let's Encrypt.

**What is actually fixed: the state, not the code.** `tls-certs` now holds a
certificate, so the next reimage should restore rather than gamble on certbot,
which makes items 2 and 3 much harder to reach. But all four mechanisms are still
in `environments/production/cloud-init.tftpl` exactly as they were — nothing was
changed to prevent a recurrence.

Worth doing, roughly in value order:

- ~~**Assert HTTPS in `deploy-on-main-merge.yml`**~~ — **done 2026-08-17**, and in
  `deploy-production.yml` too. `curl -sf https://$DOMAIN/health` with a retry
  loop (10 × 15s) runs after the plain-HTTP gate, followed by a Drupal gate; see
  the `config:import` entry above. HTTP stays first so a warming certificate does
  not fail the deploy, and the TLS gate is skipped when `DOMAIN_NAME` is unset,
  because the fallback URL is a load-balancer FQDN with no certificate for it.
  **Not yet exercised by a real deploy.** The three items below are still open,
  so a certificate can still fail silently *inside* the instance — the gate
  catches the result, not the cause.
- **Check the uploads — there are two, and neither is checked.** `upload_blob` in
  `tls-setup.sh` and the standalone `/opt/tls-upload-cert.sh` called by the renewal
  hook both run `curl -s -X PUT` with no status test. Either can no-op in silence,
  which is what bought eight days of false confidence. Both should fail loudly.
- **Drop the `| tee` on certbot**, or read `${PIPESTATUS[0]}`, so `set -e` sees the
  real exit status.
- **Do not issue certificates from cloud-init.** Restoring from blob is safe there;
  issuance depends on the load balancer already pointing at this instance, which
  cloud-init cannot know. A boot-time timer retrying until validation succeeds
  removes the race.

**Residual risk even with the blob copy present:** the restore rejects a cert with
under 7 days left (`openssl x509 -checkend 604800`). An instance replacement inside
that window, before `certbot-renew.timer` has renewed, falls back to certbot and
hits the same race. Narrow, but real.

**Renewal, for reference.** `certbot-renew.timer` is enabled at boot,
`OnCalendar=*-*-* 00/12:00:00`, `RandomizedDelaySec=12hours`, `Persistent=true` —
it *checks* twice daily but only renews inside certbot's default 30-day window, so
the real renewal is around **2026-10-10** for a cert expiring 2026-11-09. The hook
`/etc/letsencrypt/renewal-hooks/deploy/01-update-and-upload.sh` copies into
`/etc/pki/tls`, restarts httpd and runs `/opt/tls-upload-cert.sh`. Both files were
read on instance 2 and do what they claim — but note that is a statement about the
code, and the same unchecked `curl -s -X PUT` sits at the end of it. **After the
October renewal, check the `lastModified` on the two blobs in `tls-certs` rather
than assuming it propagated:**

```bash
az storage blob list --account-name mccprod8yqx588v --container-name tls-certs \
  --auth-mode key --query "[].{name:name, modified:properties.lastModified}" -o table
```

The start/stop schedule (`30 11` up, `30 22` down, Mon–Fri) means timer fires are
missed routinely; `Persistent=true` catches up at next boot, and a 30-day window is
ample slack.

---

### Dependabot does not report Drupal core advisories — `composer audit` does

**Found 2026-08-10, while clearing the guzzle alerts.**

The GitHub Dependabot alerts UI listed six open alerts on `mccarthy-index`, all
`guzzlehttp/guzzle`. After clearing those, `composer audit --locked` reported
**three more that Dependabot never surfaced at all**, against `drupal/core`
11.4.1:

```
SA-CORE-2026-012  CVE-2026-55805  XSS
SA-CORE-2026-011  CVE-2026-15917  XSS
SA-CORE-2026-010  CVE-2026-15916  information disclosure
```

All three are patched in **11.4.4**; the locked version is 11.4.1. They live in
`composer.lock`, which the Packer build installs with `composer install
--no-dev`, so they bake into the image exactly the way the guzzle ones would
have.

The mechanism: Composer reads the **drupal.org** advisory database, which is
where Drupal security releases are published. Dependabot's feed does not cover
it. So **an empty Dependabot list is not evidence that the lock is clean** —
that is the trap, because the alerts UI is the natural place to look and it
reads as authoritative.

Run `composer audit --locked` before any image build that matters. Note plain
`composer audit` reports "No packages - skipping audit" when `vendor/` is
absent; `--locked` is what audits the lock file itself.

**Lock updated 2026-08-17 on `mccarthy-index` branch `security/drupal-11.4.5`
(commit `a1b0dcd`, cut from `dev`). Not merged, not deployed.** The advisories
are cleared but nothing has run the new code yet.

- `composer update "drupal/core-*" --with-all-dependencies` resolved core to
  **11.4.5**, not 11.4.4 — a newer patch in the same series, which contains the
  same fixes. **26 updates, 0 installs, 0 removals**: the five `drupal/core-*`
  packages, `mck89/peast`, and 20 `symfony/*` patch bumps inside 7.4.x.
- `composer audit --locked` afterwards: **no advisories**. The only remaining
  entry is the abandoned `microsoft/azure-storage-blob`, which is the recorded
  az_blob_fs decision above, not a vulnerability.
- **Only `composer.lock` changed.** `composer.json` needed no edit — `^11.4`
  already admitted 11.4.5 — and the scaffold is byte-identical between 11.4.1
  and 11.4.5 across all 23 tracked files under `web/`, verified by installing
  both versions side by side in a scratch directory. Those tracked files were
  also confirmed to match the 11.4.1 scaffold exactly, so no hand edit was at
  risk of being overwritten.
- Resolution ran against the `config.platform.php` pin of **8.3**, which is the
  image's PHP. Core 11.4.5 requires `>=8.3.0`, and no package's `php`
  constraint moved. The lock was never installed into the repo, so the missing
  root `.gitignore` never had a chance to swallow `vendor/`.

This was deliberately left for its own dev cycle rather than riding along with
the pipeline shakeout — a core bump is a real upgrade with config and schema
implications, unlike a transitive library bump. It is also the first deploy that
the new TLS and Drupal gates will guard, so **push the workflow changes to
`mccarthy-infra` `main` before merging this to `dev`**, or the build will run
under the old blind check.

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

### The devtest database sync authenticated with production's password

**Found 2026-08-10 on the first end-to-end pipeline run. Fixed in `0a9393d`.**

`build-on-dispatch.yml` (job `prepare-database`) fetched one secret and used it
against both servers, under this comment:

```
# Production and devtest share one admin password today, so one fetch.
```

They do not, and never did. Key Vault has held **two** secrets since bootstrap —
`production-db-admin-password` and `devtest-db-admin-password` — and
`docs/bootstrap-runbook.md:117-118` generates both. Only the workflow assumed
otherwise. Confirmed by comparing SHA-256 digests of the two values; they differ.

```
psql: error: connection to server at "mccarthy-devtest-psql.postgres.database.azure.com"
  failed: FATAL:  password authentication failed for user "drupaladmin"
```

**The failure is shaped to mislead.** The production `pg_dump` runs first and
succeeds, so the log shows a healthy production connection followed by devtest
refusing auth — which reads as a devtest-side outage or firewall problem rather
than the job using the wrong credential. Two `psql` calls fail in a row before
the step exits, because the first is `|| true`.

**Fix:** fetch both secrets, scope production's to the `pg_dump` alone, and
`export PGPASSWORD` to devtest's once for everything targeting `DEVTEST_HOST`.
Both are masked.

`test-cloud-init.yml` carried the **identical** bug at line 192 and was fixed in
the same commit. It had never been run, so it would have failed the same way the
first time anyone used it.

Verified by re-running: `Sync production database to devtest` passed, and the
run then failed further along on the unrelated defect below.

---

### `environments/dev/` created its resource group instead of reading it

**Found 2026-08-10 on the first-ever apply of the dev stack. Fixed in `f90269d`.**

```
Error: a resource with the ID ".../resourceGroups/mccarthy-dev-rg" already
exists - to be managed via Terraform this resource needs to be imported into
the State.
```

`environments/dev/main.tf` declared `resource "azurerm_resource_group" "dev"`,
while production and devtest both use `data`. Its comment claimed
`bootstrap/azure-setup.sh` pre-creates the group and "Terraform adopts the name
on first apply". **Terraform never adopts an existing resource** — it errors, as
above. The premise about bootstrap was correct (`azure-setup.sh:58,106`); only
the conclusion was wrong.

**Do not fix this by importing it.** That makes the apply pass and then destroys
dev permanently on the first promotion to main:

1. `deploy-on-main-merge.yml` runs an **untargeted** `terraform destroy` on this
   stack, so an imported RG is deleted along with everything in it.
2. Deleting the RG deletes every role assignment scoped to it — including the
   service principal's `Contributor` on `mccarthy-dev-rg`.
3. The SP holds Contributor on five named resource groups and **nothing at
   subscription scope**, so it cannot create a resource group. The next dev
   deploy fails with `AuthorizationFailed`, and the SP cannot regrant itself the
   access it just lost.
4. Recovery needs PIM Owner activation and a re-run of `bootstrap/azure-setup.sh`.

**Why the code was written that way:** it is lib-main's, unadapted. lib-main uses
`resource` for all three stacks and is right to — `lib-main-github-actions` holds
`Contributor` at **subscription scope**. `mccarthy-github-actions` deliberately
does not. mccarthy converted production and devtest to data sources for exactly
this reason and missed dev, because dev had never been applied. This is the same
permission asymmetry as the Packer resource-group entry below, in a second place.

**Fix:** `data "azurerm_resource_group" "dev"`, matching the other two stacks.
`terraform validate` catches the second reference in `outputs.tf`, which a grep
of `main.tf` alone will miss. Destroy still tears down everything *inside* the
group, which is where the cost is; only the empty shell and its role assignment
survive.

Verified end to end the same day: the apply succeeded, the dev VM served the
app, and a later `cleanup_only` destroy left `mccarthy-dev-rg` present and empty
with the SP's `Contributor` assignment intact.

---

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

---

## A note on first runs

**Nothing in this repo had ever run in CI before 2026-08-03, and every first run
since has failed on a different latent defect.** The count stands at eight: four
dispatches on 2026-08-03, two on 2026-08-10 (the devtest password and the dev
resource group), one on 2026-08-11 (TLS on the first production reimage), and
one on 2026-08-13 (config:import crashing on the az_blob_fs install — the first
deploy to carry the blob wiring, and the second first-run whose health check
passed against a broken site).

**Not one was visible from reading the code.** Worse, in the two found on
2026-08-10 a **comment directly above the broken line asserted the false
premise** — "Production and devtest share one admin password today" and
"Terraform adopts the name on first apply". Reading the code did not merely fail
to reveal the bug; it argued for it. Both comments were written by someone who
believed them, and both were wrong about a fact that a single command would have
settled. The 2026-08-11 defect repeats the pattern at the doc level: the runbook
described blob-backed cert persistence that had never once occurred.

**2026-08-11 added a new failure mode: the first run that reported success was
also a failure.** The six before it announced themselves with a red run. This one
was green on every step, because the only assertion it makes about the site is an
HTTP request, and what broke was HTTPS. A first run is not verified by its own
exit status — it is verified by checking the thing the run was supposed to
produce. Look at the site, not the checkmark.

The practical rule: **treat any path that has not executed as unverified, and
treat the comments on it as unverified too.** Where a comment or a doc states a
checkable fact — that two secrets match, that a resource will be adopted, that a
scope is wide enough, that a file has been uploaded — check it rather than
trusting it.

Paths that have still never executed, as of 2026-08-13:

- **`build-on-dispatch.yml` green end to end.** As of 2026-08-13 every job in it
  has run from a dispatch — `Prepare Database` passed with its own copy of the
  password fix for the first time — but the run went red in `Deploy Dev` on the
  cloud-init log gate (the config:import entry above), so a fully green
  dispatch-driven run has still never happened. The next merge to `dev` is that
  first run, now with the fixed cloud-init.

No longer on this list as of the 2026-08-13 production promotion (run
`31720848832`): the **blob restore branch of `tls-setup.sh`** (restored the
existing cert — same serial before and after) and the **cloud-init pre-install
block** (first render, ran clean against the no-modules production DB). Both
were first runs that worked.
- **The blob restore branch of `tls-setup.sh`.** It has run twice and found an
  empty container both times. `tls-certs` is populated as of 2026-08-11, so the
  next reimage is the first time it will actually restore a certificate.
- `deploy-production.yml` in full.
- The `pr_number` / per-PR ephemeral variant of the dev stack. It is vestigial —
  no workflow sets `TF_VAR_pr_number` — and it could not work as written anyway,
  since `mccarthy-dev-pr-N-rg` is not one of the five groups the SP can touch.
