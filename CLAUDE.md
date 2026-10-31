# JamfMigrator: instructions for Claude

At the start of every conversation, run ../JTKit/Scripts/check-versions.sh (or fetch it from GitHub if ../JTKit isn’t there) and mention the result in one line if anything is out of date.

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
- Only the test folders are filesystem-synchronized groups; the app target's files are listed in the project. Don't edit `project.pbxproj` by hand for files or targets: put new app code in an existing file, or ask Jordy to add the file in Xcode. The JTKit package version (minimum and `Package.resolved`) Claude updates itself, as in the other apps, resolved from the app's own project against the published JTKit (decided by Jordy on 2026-10-27); other package references Jordy changes in Xcode.
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
- **Run carries out exactly the plan Preview showed** (decided by Jordy on 2026-10-28): only ticked Create, Update, Replace and Delete rows (ticks are an inclusion list; Unchanged, Blocked and objects added later never run); the plan's types, never the current selection. Right before each write the object is compared again exactly as Preview compared it (`MigrationPlanner.compare`, digests in `ObjectPlan`); if the source, the destination or the name's use changed, Run stops before writing it and asks for a new Preview. Settings › Secrets: Preview keeps only a SHA-256 of each value, in memory; a value never goes into the plan, a journal or a run report, which only says "Secrets changed since Preview". Same-named source objects are all Blocked; destination duplicates block too. Unticking an object a ticked one needs blocks Run; if such an object's create fails during Run, the rows that need it fail as not written (Resume retries them), never written with a missing reference. Verify reports a type it couldn't read as not checked, never as passed.

## Architecture

- `Objects/ObjectType.swift`: the registry. Each type: API family and pinned version, paths, list shape, dependencies, step, delete order, and its `ObjectAccess` (Jamf Pro privileges from JTKit's table plus the Jamf Account capability).
- `Transform/`: `ProTransformer`, `ClassicTransformer`, `ClassicXML`: strip read-only fields, remap ids by name, group remapping inside Blueprints.
- `Planner/`: `MigrationPlanner` (dry run), `PayloadDiff`, `Preflight` (permission check), plan models.
- `Engine/`: `MigrationEngine`, `DeleteEngine` (reverse order, retries objects still referenced), `RunJournal` (resume), `RunReport` (saved per run), `Verifier`, `IconMigrator`, `TenantMappings` (ADE instances, distribution points), `TenantExporter` (backup), `ExportWriter`.
- `Tenants/`: `Tenant` (a JTKit `ConnectionRecord`) and `TenantStore` (one JTKit client per tenant, rebuilt after an edit, dropped on delete).
- `UI/`: `AppState`, sidebar, object list, inspector, plan summary, run view, `CloneWizard`, `WipeWizard`, Settings tabs, `GuidedTour.swift` (steps only).
- `Support/Support.swift`: app paths and `AppActivity`, the app's own lines in the activity log (redacted).
- Under tests (`SavedTenantGuard` in `TenantStore.swift`, built on JTKit's `TestRun`; `OnlyObjects` in `MigrationEngine.swift`): see Testing.

From JTKit: `JamfPlatform.Client` (gateway and direct Jamf Pro, retries, write spacing), `JamfPlatform.APIError`, `JamfPlatform.PermissionCheck`, `JamfPlatform.Poller`, `JamfPlatform.Blueprints`, `JamfPro.Privilege`, `JamfRegion`, `JamfPlatform.TokenProvider`, `TestRun`, `LosslessJSON`, `RequestRecorder`, `Redaction`, `IdentifierMasker`, `ActivityLog` + `ActivityLogWindow`, `ConnectionStore` + `ConnectionCommands`, `KeychainSecretStore`, `SettingsWindow`, `AboutWindow` + acknowledgements, `UpdateChecker`, `TourState`/`TourStep`, `StatusBadge`, `JSONFile`; `JTKitTestSupport` in tests.

Stays in the app: the registry and transforms, Classic XML payloads, the delete engine and its retries, journal, run reports, mappings, the wizards. Extend JTKit instead of adding another copy of anything it has.

Demo mode (JTKit step 10): `AppState.demo` (JTKit `DemoMode`, key `demoMode`) with two demo tenants from JTKit, "Contoso Source (Demo)" and "Contoso Destination (Demo)", direct Jamf Pro, so Blueprints and Benchmarks are Blocked. `TenantStore.makeClient` is the only place that gives a demo tenant JTKit's demo network and fake secret; Test Connection (`testClient`) always uses the real network. While demo mode is on: journals, backups, exports and run reports go to `DemoMode.scratchDirectory` (`AppState.dataDirectory`), never Application Support; the type selection and mappings stay in memory; Settings › Secrets are not read (placeholders are written); the saved Source and Destination are left as they were. `-JTKitSandbox YES` keeps tenants, secrets and settings in memory and makes no update check. The sidebar pickers and the Connection menu are JTKit's `ConnectionPicker` and `ConnectionCommands` with Demo Mode below the tenants; both demo tenants are offered for every role, delete mode's Tenant included.

## Stored data (keep these names)

- Tenants: `tenants.json` in Application Support/JamfMigrator (inside the sandbox container), keys `id, name, region, environmentId, clientId, serverURL, username, isProtected`. Region raw values `us`, `eu`, `apac`.
- Keychain service `JamfMigrator-tenant`: account = tenant UUID for the client secret or password; `service-<key>` for the Settings › Secrets values. "After first unlock", moving items from the data-protection keychain on read (builds before 1.0.1 wrote there).
- UserDefaults: `sourceTenantID`, `destTenantID`, `selectedTypeKeys`, `exportOnRun`, `mappings-<source>-<destination>`, `demoMode`.
- Application Support/JamfMigrator: `journals/`, `backups/`, `exports/`, `Run Reports/`. Every run, also a stopped one, saves a redacted report. A sandbox run (`-JTKitSandbox`) without demo mode uses a temporary folder instead; Settings › Export's switch is kept in the app's own settings (in memory in a sandbox run).
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
- Licensed-software writes are recorded without contents, and serial numbers are blanked from failure reasons (a refused write can echo a licence serial).
- Rate limits aren't published: keep JTKit's write spacing.
- A computer static group create (`pro/v3/computer-groups/static-groups`) sends `"assignments": []`; an update never sends members.
- The live check accepts a macOS profile’s Self Service `notification` settings as different only on a Jamf Pro 11.34.0 beta destination (decided by Jordy on 2026-10-28).
- What this app waits for from Apple, Jamf or Microsoft, or must recheck: see WATCHLIST.md.

## Testing

- Unit tests: ⌘U in the app's own project (Swift Testing). Networking tests use `MockHTTP`, `FakeGateway` and JTKit's `MockServer`; no real network.
- `ObjectRegistryTests` checks every pin against the vendored gateway spec (`JamfMigratorTests/Resources/gateway-coverage.json`, from jamf-cli). When jamf-cli's spec moves, update the file and fix the pins it flags.
- Never run the long UI suites of Jamf Deployer and AppSettings2Blueprint unless Jordy asks for a test by name (JTKit rule).
- Live checks: see JTKit ROADMAP step 11. Tenants come only from the local allow-list outside git. The app's own code only ever reads the source tenant and writes only on the destination test tenant, with a recognisable test prefix, cleaned up afterwards. **During the release check only**, the test code (never the app) may also create `JTKTEST`-prefixed objects on the source test tenant, and removes them afterwards (decided by Jordy on 2026-10-28). Never touch the destination's original admin account; leave Jamf Pro user accounts and groups out of a test wipe.
- **Under tests the app never reaches a saved tenant** (decided by Jordy on 2026-10-28): as the unit tests' host it starts like a sandbox run (`-JTKitSandbox`: tenants, secrets and settings in memory, no update check), and any client for the saved tenants (the real `tenants.json` or the real `JamfMigrator-tenant` Keychain items) refuses every sign-in, token refresh and request before it is sent and records it in the container's `tmp/JamfMigrator-under-test/`. The release check empties that file first, and its live checks fail the run if anything was recorded.
- **"Only these objects"** (`OnlyObjects`): a test-only limit on Preview, Run and Verify to named source objects. It can only be made by test code (Debug builds only, and it refuses outside tests); never set it from the app's screens, settings or launch arguments.
- **UI tests** (`JamfMigratorUITests`, a macOS UI testing bundle, minimum macOS 26.0 like the app, uses `JTKitUITestSupport`): only `DemoSmokeUITests`, run by the release check through the "JamfMigrator Release Check" scheme. The app's own scheme runs the unit tests only, so ⌘U never starts UI tests. Run a single UI test only when Jordy asks for it by name.
- **Release check** (ROADMAP step 11): `scripts/release-check.sh` (scheme "JamfMigrator Release Check"; `--local-jtkit` before a JTKit version is tagged). Own-project build against the published JTKit and sign-in, unit tests, `DemoSmokeUITests` in demo mode (launch, About, Settings tabs, the connections editor adding and deleting a throwaway tenant, the Clone tenant wizard's Preview, Run and a clean Verify, activity log, "— Demo" titles, Run offering exactly one ticked change, Run off after the selection changed), live checks, report. Claude may run it unattended (nohup, poll). Never name a tenant in this repo.
  - The app is sandboxed, so the live folder (allow-list copy, ledger, results) is in the container's `tmp/JTKitReleaseCheck/` (JTKit 0.12.2, `TEST_HOST_CONTAINER`).
  - Live checks (`LiveCheckTests.swift`, skipped on ⌘U), objects named `JTKTEST JM <run> – …`, jamf-test-a (source, Platform API) → jamf-test-b: (1) over the Platform API: a category, an empty **static** computer group (0 members checked on both tenants), a script in the category, a macOS profile in the category scoped to nothing (checked on both tenants); (2) over jamf-test-b's direct Jamf Pro connection (username and password): a category and a profile in it; the direct sign-in tokens are cancelled afterwards. The test code makes them on the source; the app's own `MigrationPlanner`, `MigrationEngine` and `Verifier` (with `OnlyObjects`, the journal in a temporary folder, no export) migrate and verify them; the test code reads them back on the destination and removes them from both tenants, then sweeps both for `JTKTEST`.
  - Also checked live: Run stops before writing when the source changed since Preview (the test code edits the source script after Preview: the category is created, the script isn't, a new Preview shows the category Unchanged and the rest is created), and a second Preview after the run shows everything Unchanged (the profile only with the accepted 11.34 beta field, left unticked) and its Run writes nothing.
  - Safety, on top of JTKit's guarded network: the app's source client runs on a read-only copy of that network; the app's destination client runs behind a fence that lets only reads, sign-ins and creates through and stops the engine on anything else; before a run the destination must have none of the run's names and Preview must plan exactly the test objects, all as Create. Delete mode and Wipe never run live.
  - The fingerprint compares the app's Application Support folder in its container (`tenants.json`, `settings.plist`, `journals/`, `backups/`, `exports/`, `Run Reports/`), its `Library/Logs/JamfMigrator`, the defaults `sourceTenantID`, `destTenantID`, `demoMode`, `selectedTypeKeys`, `exportOnRun` and every `mappings-…` key, and the names of the `JamfMigrator-tenant` Keychain items (hashes only).
- Never put tenant names, URLs, Environment IDs, client IDs, secrets or passwords in the repo, docs or commit messages. A temporary helper script that needs credentials goes in a temporary folder outside the repo and is deleted afterwards.

## Releasing

1. Bump `MARKETING_VERSION` (app and tests). The build number is stamped into the built app by a build phase (UTC date-time); the tracked `Info.plist` keeps its placeholder, so a build leaves nothing to commit.
2. Add an entry to `ChangeLog.md` (short, user-facing).
3. Follow the release gate in JTKit/ROADMAP.md (release check, design review, code review, Jordy's check by hand). Update the JTKit package version first if needed.
4. Build, sign (Developer ID), notarize and staple with `scripts/release.sh <notary profile>`, or Xcode's Archive › Distribute App and then `ditto -c -k --keepParent`. The zip is `JamfMigrator-<version>.zip`.
5. Tag `vX.Y.Z`, create the GitHub release with the zip attached. The in-app updater reads `releases/latest` and needs the zip.
6. Website: only when the app has its own page on jordythery.be and the release changes the app enough to make that page untrue or incomplete, update the page.
