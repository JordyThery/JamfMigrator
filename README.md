# Jamf Migrator

A macOS app that copies a source Jamf tenant to a destination tenant — or any
selection down to a single object — with a dry-run preview, a resumable engine,
and a gated wipe.

Jamf Migrator started as a fork of [Replicator](https://github.com/jamf/Replicator)
by Jamf Professional Services (MIT license) and has been rewritten as a SwiftUI
app for macOS 26 on top of the Jamf Platform API and the Jamf Pro APIs.

## Connections

Each tenant is configured in **Settings › Tenants** with one of two connection
kinds:

- **Platform API gateway** (default): region (`us`/`eu`/`apac`), the tenant's
  environment UUID, and an API integration's client ID + secret from
  [Jamf Account](https://account.jamf.com). Requests go through
  `https://{region}.api.jamfcloud.com` with the `X-Environment-Id` header.
- **Jamf Pro server** (for tenants without Platform API access): the
  instance URL (`https://tenant.jamfcloud.com`) with either an **API client**
  (`/api/oauth/token`) or a **Jamf Pro username and password**
  (`/api/v1/auth/token` mints a bearer token; API calls never use Basic auth).

The two kinds mix freely — a gateway source can copy to a direct destination
and the reverse. **Blueprints and Compliance Benchmarks exist only behind the
Platform API**; when a selected tenant is a direct connection those types are
grayed out with a tooltip and planned as Blocked.

Secrets are stored in the macOS Keychain, never on disk.

### Permissions

Give the API integration (or API client/user) read access on the source and
full CRUD on the destination for every object type you plan to copy. The
**Clone tenant** wizard's Connect step probes every selected type on both
tenants and names anything the integration lacks permission for.

## What gets copied

Objects migrate in dependency order and are matched **by name** on the
destination. The dry run labels every object:

| Outcome | Meaning |
|---|---|
| **Create** | Not on the destination yet. |
| **Update** | Exists but differs — the inspector shows a field-level diff. |
| **Replace** | Compliance Benchmarks only: deleted and recreated (no update endpoint). |
| **Unchanged** | Identical; skipped. |
| **Blocked** | Can't be migrated — the reason is shown. |

| Step | Object types |
|---|---|
| 1 | Sites |
| 2 | Categories, buildings, departments, network segments |
| 3 | Computer, mobile device and user extension attributes |
| 4 | Scripts, packages (records only), distribution points |
| 5 | Jamf user/group accounts, LDAP servers, users, user groups, directory bindings, software update servers |
| 6 | Smart/static computer and mobile device groups, advanced searches |
| 7 | Configuration profiles, Mac and mobile apps, eBooks, classes, restricted software, printers, dock items (+ self-service icons) |
| 8 | Policies, patch management titles and policies, App Installers |
| 9 | Enrollment customizations |
| 10 | Computer and mobile device PreStages (with ADE and distribution-point mapping) |
| 11 | Blueprints *(Platform API only)* — deploy state mirrored from the source |
| 12 | Compliance Benchmarks *(Platform API only)* |
| 13 | Webhooks and tenant settings: check-in, inventory collection, SMTP, Self Service, re-enrollment, LAPS, onboarding, SSO |

### What can't be copied (the manual checklist)

- **ADE tokens** — one per tenant, created in Apple Business/School Manager
  against the destination's public key. The Clone wizard maps instances.
- **VPP / Apps and Books tokens**, **APNs certificate**, **SSO certificates**,
  **API clients and roles**.
- **Package files** — records are copied; the files must already be on the
  destination's distribution points.
- **Secrets the API won't return** — LDAP/bind/file-share passwords are taken
  from **Settings › Secrets** (or written as a placeholder); PreStage admin and
  SMTP/SSO/webhook passwords must be re-entered on the destination.
- **Inventory** — computers and mobile devices are out of scope, so static
  groups are created empty.
- FileVault-escrow profiles, Apple School Manager classes and patch-service
  extension attributes are skipped (Blocked) by design.

## Using the app

1. Add both tenants in **Settings › Tenants** (mark the source tenant
   **Protected** so it can never be wiped).
2. Pick Source and Destination in the sidebar, choose object types (Check all /
   Uncheck all), then **Preview** (⇧⌘P) — a read-only dry run.
3. Review the plan: per-type counts in the sidebar, per-object outcomes with
   checkboxes in the list, diffs in the inspector. Uncheck anything to leave it
   out — copying one specific script is: Uncheck all types → check Scripts →
   Select › Uncheck all → check the one script.
4. **Run** (⌘R). Progress is live; a stopped or failed run **resumes** — the
   journal skips everything already done. Enable **Settings › Export** to save
   every raw and written payload per run.

### Clone tenant

The toolbar's **Clone tenant** button runs the guided flow: Connect (live
preflight) → Prepare (manual checklist, ADE and distribution-point mapping,
secrets) → Preview → Run → **Verify**, which plans again and proves a second
run would write nothing.

### Delete mode and Wipe tenant

**⌘D** toggles delete mode for the session (the app always starts in Copy): a
red banner appears, Run turns red, and every run confirms with the tenant name
and counts. The red **Wipe tenant** button deletes every selected object type
from a tenant behind gates that must all pass: the tenant isn't Protected, a
dry-run preview, a verified backup of the selected types (skippable only
through an extra confirmation), and typing the tenant's name. Deletes run in
reverse dependency order, retry objects held by dependencies, and end with a
report of anything left behind.

## Logs and files

- Log: `~/Library/Containers/be.jordythery.jamfmigrator/Data/Library/Logs/JamfMigrator/`
- Tenants, journals, backups and exports:
  `…/Data/Library/Application Support/JamfMigrator/`

## License

MIT — see [LICENSE](LICENSE). Based on Replicator, © Jamf.
