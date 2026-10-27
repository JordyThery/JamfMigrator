# JamfMigrator: instructions for Claude

Shared code and the standards for every app: see JTKit's CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace).

## What the app is

- Jamf Migrator (project and repo `JamfMigrator`, app name "Jamf Migrator") copies a source Jamf tenant onto a destination tenant, or any selection down to one object. Goal: set up a "golden master" tenant once and clone it into a new, empty tenant.
- A full SwiftUI rewrite of Jamf's Replicator (MIT, credited in About and `THIRD-PARTY-NOTICES.md`). It is Jordy's own tool, not an upstream contribution.
- Main flows: Preview (read-only dry run with field-level diffs), Run (resumable), Clone tenant wizard (Connect → Prepare → Preview → Run → Verify), delete mode and the gated Wipe tenant. Every run saves a report.
- Jordy is not a programmer: explain changes in plain language and work in small steps.

## How to work on it

- App-only work: open the app's own project (`JamfMigrator.xcodeproj`). Its notes load and it builds against the published JTKit.
- Anything that changes JTKit: work in `~/Developer/Apps.xcworkspace`.
- Build releases from the app's own project. Never have the app open in both at once.
- Only change JTKit or other apps when Jordy asks for them.
- After merging into main, push main to origin straight away (keep GitHub in sync).
- The project uses filesystem-synchronized groups. Don't edit `project.pbxproj` by hand; Jordy changes package references in Xcode.
- macOS 26 only (Liquid Glass), sandboxed, Swift 5 language mode, async/await. No storyboards, no Combine.

## Rules decided by Jordy

- **Two connection kinds per tenant**, mixing freely: the Jamf Platform API gateway (region, Environment ID, API client) or a direct Jamf Pro server (API client, or username and password that mint a bearer token). API calls never use Basic auth.
- **Blueprints and Compliance Benchmarks exist only behind the gateway.** On a direct tenant they are greyed out and planned as Blocked.
- **Newest endpoint version always** (never v1 when v3 exists). Prefer the Jamf Pro API over Classic wherever the Pro API has full create/read/update/delete; Classic only where it doesn't.
- **Selective migration is first-class:** any subset of types or objects, with Check all / Uncheck all.
- **Delete mode** stays on for the session but always starts off at launch; red banner, and every run confirms with the tenant name and counts.
- **Wipe tenant** keeps all its gates, in order: delete mode on, tenant not Protected, dry run, verified backup (skip only with an extra confirmation), type the tenant's name. Never weaken them.
- **Blueprint deploy state mirrors the source:** deployed → deploy; out of date → deploy with a warning; not deployed → leave undeployed.
- **Dropped on purpose, don't add back:** the headless CLI mode (jamf-cli covers scripting), API roles and API integrations (the gateway doesn't serve them), computers and mobile devices (inventory is out of scope, so static groups are created empty).
- Objects are matched **by name** on the destination.

## Architecture

- `Objects/ObjectType.swift`: the registry. Each type: API family and pinned version, paths, list shape, dependencies, step, delete order, and its `ObjectAccess` (Jamf Pro privileges from JTKit's table plus the Jamf Account capability).
- `Transform/`: `ProTransformer`, `ClassicTransformer`, `ClassicXML`: strip read-only fields, remap ids by name, group remapping inside Blueprints.
- `Planner/`: `MigrationPlanner` (dry run), `PayloadDiff`, `Preflight` (permission check), plan models.
- `Engine/`: `MigrationEngine`, `DeleteEngine` (reverse order, retries objects still referenced), `RunJournal` (resume), `RunReport` (saved per run), `Verifier`, `IconMigrator`, `TenantMappings` (ADE instances, distribution points), `TenantExporter` (backup), `ExportWriter`.
- `Tenants/`: `Tenant` (a JTKit `ConnectionRecord`) and `TenantStore` (one JTKit client per tenant, rebuilt after an edit, dropped on delete).
- `UI/`: `AppState`, sidebar, object list, inspector, plan summary, run view, `CloneWizard`, `WipeWizard`, Settings tabs, `GuidedTour.swift` (steps only).
- `Support/Support.swift`: app paths and `AppActivity`, the app's own lines in the activity log (redacted).

From JTKit: `JamfPlatform.Client` (gateway and direct Jamf Pro, retries, write spacing), `JamfPlatformError`, `JamfPlatform.PermissionCheck`, `JamfPlatform.Poller`, `JamfPlatform.Blueprints`, `JamfPro.Privilege`, `JamfRegion`, `JamfTokenProvider`, `LosslessJSON`, `RequestRecorder`, `Redaction`, `IdentifierMasker`, `ActivityLog` + `ActivityLogWindow`, `ConnectionStore` + `ConnectionCommands`, `KeychainSecretStore`, `SettingsWindow`, `AboutWindow` + acknowledgements, `UpdateChecker`, `TourState`/`TourStep`, `StatusBadge`, `JSONFile`; `JTKitTestSupport` in tests.

Stays in the app: the registry and transforms, Classic XML payloads, the delete engine and its retries, journal, run reports, mappings, the wizards. Extend JTKit instead of adding another copy of anything it has.

Still open (ROADMAP "Standards for every app"): the sidebar's own `TenantPicker` is to be replaced by JTKit's `ConnectionPicker` on the next JTKit update.

## Stored data (keep these names)

- Tenants: `tenants.json` in Application Support/JamfMigrator (inside the sandbox container), keys `id, name, region, environmentId, clientId, serverURL, username, isProtected`. Region raw values `us`, `eu`, `apac`.
- Keychain service `JamfMigrator-tenant`: account = tenant UUID for the client secret or password; `service-<key>` for the Settings › Secrets values. "After first unlock", moving items from the data-protection keychain on read (builds before 1.0.1 wrote there).
- UserDefaults: `sourceTenantID`, `destTenantID`, `selectedTypeKeys`, `exportOnRun`, `mappings-<source>-<destination>`.
- Application Support/JamfMigrator: `journals/`, `backups/`, `exports/`, `Run Reports/`. Every run, also a stopped one, saves a redacted report.
- The old text log `jamfmigrator.log` is retired: its lines go to the activity log; the file stays on disk untouched.

## Jamf behaviour learned the hard way

- The gateway answers an unknown route with `403 BAD_PERMISSIONS`, not 404, and serves only the newest version of an endpoint, so an old version looks like a missing permission. Platform paths follow `/{namespace}/v{n}/{resource}` (`blueprints/v1/blueprints`, `compliance-benchmarks/v1/benchmarks`).
- Direct paths map 1:1: `pro/…` ↔ `/api/…`, `proclassic/…` ↔ `/JSSResource/…`.
- Platform tokens last 900 s with no refresh token: sign in again with the client credentials.
- Never follow `href` in write answers (it points at internal hosts); use the returned id. A Classic create returns `<…><id>n</id></…>`; a benchmark create names it `benchmarkId`.
- Classic lists are asked for as JSON; details and writes are XML.
- Pro detail payloads carry ids only, never the `*Name` fields: resolve every reference through the source's id → name lookups.
- Jamf normalises absent fields to `""`: treat empty and missing as equal in diffs.
- An icon-only Classic PUT on a policy resets its Self Service display name: send it back in the same write.
- PreStages: nested blocks need `id` and `versionLock` (`-1`/0 on create, the destination's on update); `adminPassword` is never returned; a manual Recovery Lock password is required when enabled (taken from Settings › Secrets or a placeholder).
- Patch titles: the destination must subscribe first (Classic create from the same patch source), then the Pro title accepts only `application/merge-patch+json` PATCH. Patch title configurations list as a bare array.
- Blueprints: settings use `{Included, Value}`; any PATCH makes a deployed Blueprint out of date; `PATCH` with `steps` replaces all steps; names can repeat; a deployed Blueprint can be deleted directly.
- Benchmarks: no update endpoint (Replace = delete and recreate); duplicate title → 409; `syncState` only on list entries.
- Deleting a device group that a Blueprint still uses → `422 HAS_DEPENDENCIES`.
- A Jamf Pro beta instance was seen deleting newly created benchmarks about 3 minutes after creation. That is a Jamf-side issue, not an app bug.
- Licensed-software writes are recorded without contents, and serial numbers are blanked from failure reasons (a refused write can echo a licence serial).
- Rate limits aren't published: keep JTKit's write spacing.

## Testing

- Unit tests: ⌘U in the app's own project (Swift Testing). Networking tests use `MockHTTP`, `FakeGateway` and JTKit's `MockServer`; no real network.
- `ObjectRegistryTests` checks every pin against the vendored gateway spec (`JamfMigratorTests/Resources/gateway-coverage.json`, from jamf-cli). When jamf-cli's spec moves, update the file and fix the pins it flags.
- Never run the long UI suites of Jamf Deployer and AppSettings2Blueprint unless Jordy asks for a test by name (JTKit rule).
- Live checks: see JTKit ROADMAP step 11. Tenants come only from the local allow-list outside git. Writes only on the destination test tenant, with a recognisable test prefix, cleaned up afterwards; the source test tenant is only read. Never touch the destination's original admin account; leave Jamf Pro user accounts and groups out of a test wipe.
- Never put tenant names, URLs, Environment IDs, client IDs, secrets or passwords in the repo, docs or commit messages. A temporary helper script that needs credentials goes in a temporary folder outside the repo and is deleted afterwards.

## Releasing

1. Bump `MARKETING_VERSION` (app and tests). The build number is stamped into the built app by a build phase (UTC date-time); the tracked `Info.plist` keeps its placeholder, so a build leaves nothing to commit.
2. Add an entry to `ChangeLog.md` (short, user-facing).
3. Follow the release gate in JTKit/ROADMAP.md (release check, design review, code review, Jordy's check by hand). Update the JTKit package version first if needed.
4. Build, sign (Developer ID), notarize and staple with `scripts/release.sh <notary profile>`, or Xcode's Archive › Distribute App and then `ditto -c -k --keepParent`. The zip is `JamfMigrator-<version>.zip`.
5. Tag `vX.Y.Z`, create the GitHub release with the zip attached. The in-app updater reads `releases/latest` and needs the zip.
6. Website: only when the app has its own page on jordythery.be and the release changes the app enough to make that page untrue or incomplete, update the page.
