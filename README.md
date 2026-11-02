# Jamf Migrator

A macOS app that copies a source Jamf tenant to a destination tenant — or any
selection down to a single object — with a read-only Preview, a resumable run,
and a gated wipe.

Jamf Migrator started as a fork of [Replicator](https://github.com/jamf/Replicator)
by Jamf Professional Services (MIT license) and has been rewritten as a SwiftUI
app for macOS 26 on top of the Jamf Platform API and the Jamf Pro APIs.

## Requirements

- macOS 26 or later
- Per tenant: a Jamf Platform API integration from Jamf Account, or a Jamf Pro
  API client or user account, with the permissions in
  [Permissions](docs/PERMISSIONS.md)

## Install

Download `JamfMigrator-<version>.zip` from
[Releases](https://github.com/JordyThery/JamfMigrator/releases/latest), unzip
it, and move Jamf Migrator to Applications. It's signed with Developer ID and
notarized.

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

Client secrets and passwords are stored in the macOS Keychain (service
`JamfMigrator-tenant`), never on disk.

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

Before every clone, the Clone Tenant wizard lists the tokens, certificates,
API roles and clients, and package files below.

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
passwords, password hashes, Settings › Secrets values and license serial
numbers are replaced by `<redacted>` in those files.

### Clone Tenant

The toolbar’s **Clone Tenant** button runs the guided flow: Connect (checks
both tenants and their permissions) → Prepare (manual checklist, ADE and
distribution point mapping, secrets) → Preview → Run → **Verify**, which plans
again and shows that a second run would write nothing.

### Delete mode and Wipe Tenant

**⌘D**, **Migration › Enter Delete Mode** or the toolbar's Copy/Delete switch
turns on delete mode for the session (the app always starts in Copy): a red
banner names the tenant and offers **Switch to Copy**, Run turns red, and every
run confirms with the tenant name and counts. In delete mode the toolbar's red
**Wipe Tenant** button deletes every selected object type from a tenant behind
gates that must all pass, in order: delete mode is on, the tenant isn’t
Protected, a Preview, a verified backup of the selected types (skippable only
through an extra confirmation), and typing the tenant’s name. Deletes run in
reverse dependency order, retry objects held by dependencies, and end with a
report of anything left behind. Delete mode never removes the account a
direct connection signs in with, or a Jamf Pro account or group with full
access and the Administrator privilege set.

### Demo Mode

**Try Demo Mode** in the sidebar (shown while no tenants are added) or
**Connection › Demo Mode** swaps your
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

### Menus

- **Connection**: Source and Destination (or the tenant in delete mode),
  **Edit Tenants…** and **Demo Mode**.
- **Migration**: **Enter Delete Mode** / **Leave Delete Mode** (⌘D),
  **Preview** (⇧⌘P), **Run** (⌘R), **Clone Tenant…** (in Copy) and **Wipe
  Tenant…** (in delete mode).

### Settings

- **Connections**: your tenants and whether each one is Protected.
- **Secrets**: the passwords the API never returns (directory binding, LDAP,
  file share read/write and read-only, PreStage Recovery Lock).
- **Export**: save payloads during runs.
- **Updates**: the daily update check.

## Activity log and files

- **Activity log**: **Window › Activity Log** (⇧⌘L) shows every sign-in,
  request and run problem as it happens, with secrets removed. It is kept in
  memory; **File › Export Activity Log for Bug Report…** saves it with
  identifiers masked, **Export Activity Log Unmasked…** without.
- Tenants, journals, backups, exports and run reports:
  `~/Library/Containers/be.jordythery.jamfmigrator/Data/Library/Application Support/JamfMigrator/`
- Settings (the Source and Destination, the type selection, Settings › Export
  and the mappings) are kept in the app's preferences; secrets in the Keychain.

## Network and sandbox

The app contacts only:

- `us.api.jamfcloud.com`, `eu.api.jamfcloud.com` or `apac.api.jamfcloud.com`
  (the tenant's region) for the Jamf Platform API
- each tenant's own Jamf Pro server, for a direct connection
- `api.github.com` and GitHub's release downloads, for the update check
- the Self Service icon addresses the source tenant returns (Jamf's icon
  CDN), over https only, to copy icons

The app is sandboxed: outgoing network connections, the Downloads folder, and
files you choose in an Open or Save panel.

## Building

Open `JamfMigrator.xcodeproj` in Xcode 26 or later and build the
`JamfMigrator` scheme (⌘R); ⌘U runs the unit tests. The app’s only package
dependency is [JTKit](https://github.com/JordyThery/JTKit), the shared package
of these apps. Resolving it also downloads Microsoft’s MSAL, which JTKit uses
for Intune sign-in and which this app doesn’t link or ship.

## Support

If Jamf Migrator saves you time, you can
[buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## Disclaimer

This tool is provided as-is, without warranty of any kind. Use it at your own risk. This is a personal project. It is not affiliated with or endorsed by my employer or Jamf. Issues and pull requests are appreciated. Support is best-effort.

## License

MIT — see [LICENSE](LICENSE). Based on Replicator, © Jamf.
