# Jamf Migrator

A macOS app that copies a source Jamf tenant to a destination tenant — or any
selection down to a single object — with a read-only Preview, a resumable run,
and a gated wipe.

Jamf Migrator started as a fork of [Replicator](https://github.com/jamf/Replicator)
by Jamf Professional Services (MIT license) and has been rewritten as a SwiftUI
app for macOS 26 on top of the Jamf Platform API and the Jamf Pro APIs.

## Connections

Each tenant is added in **Settings › Connections** with one of two connection
kinds:

- **Jamf Platform API** (default): the region, the tenant’s Environment ID,
  and an API integration’s client ID and secret from
  [Jamf Account](https://account.jamf.com).
- **Jamf Pro** (a direct connection, for tenants without Jamf Platform API
  access): the server URL (`https://yourcompany.jamfcloud.com`) with either an
  **API client** or a **Jamf Pro username and password**. A username and
  password sign in for a token; requests never use Basic authentication.

The two kinds mix freely: a Jamf Platform API source can copy to a direct
destination and the reverse. **Blueprints and Compliance Benchmarks exist only
behind the Jamf Platform API gateway**; while a selected tenant connects
directly to Jamf Pro, those types are grayed out and left out of Preview.

Client secrets and passwords are stored in the macOS Keychain, never on disk.

### Permissions

The quick version: the source needs Read and the destination needs Read,
Create and Update on every object type you copy, plus Delete for delete mode.
For least privilege, [Permissions](docs/PERMISSIONS.md) lists the Jamf Account
permission and the Jamf Pro privileges for each object type, the types each one
also reads, and the few exceptions. The **Clone Tenant** wizard’s Connect step
checks every selected type on both tenants and names any a tenant can’t read.

## What gets copied

Objects migrate in dependency order and are matched **by name** on the
destination. **Preview** (the dry run) reads both tenants, writes nothing, and
labels every object:

| Outcome | Meaning |
|---|---|
| **Create** | Not on the destination yet. |
| **Update** | Exists but differs; the inspector shows a field-level diff. |
| **Replace** | Compliance Benchmarks only: deleted and recreated (they have no update endpoint). |
| **Unchanged** | Identical; skipped. |
| **Blocked** | Can’t be migrated; the reason is shown. |

| Step | Object types |
|---|---|
| 1 | Sites |
| 2 | Categories, buildings, departments, network segments |
| 3 | Computer, mobile device and user extension attributes |
| 4 | Scripts, packages (records only), distribution points |
| 5 | Jamf Pro user and group accounts, LDAP servers, users, user groups, directory bindings, software update servers |
| 6 | Smart and static computer and mobile device groups, advanced searches |
| 7 | Configuration profiles, Mac and mobile device apps, eBooks, classes, restricted and licensed software, printers, Dock items (with their Self Service icons) |
| 8 | Policies, patch management titles and policies, App Installers |
| 9 | Enrollment customizations |
| 10 | Computer and mobile device PreStages (with ADE and distribution point mapping) |
| 11 | Blueprints *(Jamf Platform API only)*: deployed on the destination only when deployed on the source; an out-of-date one is deployed with a warning |
| 12 | Compliance Benchmarks *(Jamf Platform API only)* |
| 13 | Webhooks and tenant settings: check-in, inventory collection, SMTP, Self Service, re-enrollment, LAPS, onboarding, single sign-on |

Onboarding items are matched by name on the destination; single sign-on that
is off on the destination stays off.

### What can’t be copied (the manual checklist)

The Clone Tenant wizard shows this list before every clone:

- **ADE tokens**: create one per tenant in Apple Business or Apple School
  Manager with the destination’s public key. The wizard maps the instances.
- **Apps and Books (VPP) tokens**, the **APNs certificate**, **SSO
  certificates**, and **API roles and clients**.
- **Package files**: the records are copied; the files must already be on the
  destination’s distribution points.
- **License attachments** on licensed software: the licenses are copied, the
  attached files aren’t (the run report warns).
- **Secrets the API won’t return**: the directory binding, LDAP, file share
  (read/write and read-only) and PreStage Recovery Lock passwords are taken
  from **Settings › Secrets** (or written as a placeholder); PreStage admin,
  SMTP, single sign-on and webhook passwords must be re-entered on the
  destination.
- **Inventory**: computers and mobile devices are out of scope, so static
  groups are created empty.
- FileVault escrow profiles, Apple School Manager classes and patch-service
  extension attributes are Blocked by design.

## Using the app

1. Add both tenants in **Settings › Connections** (mark the source tenant
   **Protected** so it can never be wiped).
2. Pick Source and Destination in the sidebar, choose object types (Check All
   / Uncheck All), then click **Preview** (⇧⌘P).
3. Review the plan. Preview opens on a **Summary** page: totals per outcome,
   and every planned type with its counts (the sidebar shows them too).
   Select a type to see its objects with their checkboxes, and an object to see
   its diff in the inspector. Uncheck anything to leave it out. To copy one
   script: Uncheck All types → check Scripts → Preview → Select › Uncheck All →
   check the one script.
4. Click **Run** (⌘R) and confirm. Run carries out exactly what Preview showed:
   only the checked objects Preview marked to create, update or replace.
   Objects added later are left alone, and if an object, Settings › Secrets or
   the mappings changed since Preview, Run stops before writing it and asks for
   a new Preview. Stop a run or lose the connection, and **Resume Run** carries
   on with the same plan.

Every run, also a stopped one, saves a report to the **Run Reports** folder;
**Show Report in Finder** in the run window opens it. Turn on **Settings ›
Export** to save every source payload and every written payload per run;
passwords, Settings › Secrets values and license serial numbers are replaced
by `<redacted>` in those files.

### Clone Tenant

The toolbar’s **Clone Tenant** button runs the guided flow: Connect (checks
both tenants and their permissions) → Prepare (manual checklist, ADE and
distribution point mapping, secrets) → Preview → Run → **Verify**, which plans
again and shows that a second run would write nothing.

### Delete mode and Wipe Tenant

**⌘D** turns on delete mode for the session (the app always starts in Copy):
a red banner appears, Run turns red, and every run confirms with the tenant
name and counts. The red **Wipe Tenant** button deletes every selected object
type from a tenant behind gates that must all pass, in order: the tenant isn’t
Protected, a Preview, a verified backup of the selected types (skippable only
through an extra confirmation), and typing the tenant’s name. Deletes run in
reverse dependency order, retry objects held by dependencies, and end with a
report of anything left behind. Delete mode never removes the account a
direct connection signs in with, or a Jamf Pro account or group with full
access and the Administrator privilege set.

### Demo Mode

**Try Demo Mode** in the sidebar (or **Connection › Demo Mode**) swaps your
tenants for two made-up ones, Contoso Source (Demo) and Contoso Destination
(Demo), so you can try every flow without a Jamf tenant. Demo Mode never reads
your Keychain or Settings › Secrets, and its run reports, journals, backups and
exports go to a temporary folder.

### Guided Tour

A short tour starts on first launch and walks through the workflow; replay it
from **Help › Guided Tour**.

### Updates

At launch, at most once a day, the app asks GitHub for the latest release and
offers it once, with its release notes and a download of the zip. **Jamf
Migrator › Check for Updates…** checks on demand; **Settings › Updates** turns
the daily check off. The app is sandboxed and can’t replace itself: save the
zip, quit, and swap the app in Applications.

### Settings

- **Connections**: your tenants and whether each one is Protected.
- **Secrets**: the passwords the API never returns (directory binding, LDAP,
  file share read/write and read-only, PreStage Recovery Lock).
- **Export**: save payloads during runs.
- **Updates**: the daily update check.

## Activity log and files

- **Activity log**: **Window › Activity Log** (⇧⌘L) shows every sign-in,
  request and run problem as it happens, with secrets removed. It is kept in
  memory; export it from that window for a bug report.
- Tenants, journals, backups, exports and run reports:
  `~/Library/Containers/be.jordythery.jamfmigrator/Data/Library/Application Support/JamfMigrator/`

## Disclaimer

This tool is provided as-is, without warranty of any kind. Use it at your own risk. This is a personal project. It is not affiliated with or endorsed by my employer or Jamf. Issues and pull requests are appreciated. Support is best-effort.

## License

MIT — see [LICENSE](LICENSE). Based on Replicator, © Jamf.
