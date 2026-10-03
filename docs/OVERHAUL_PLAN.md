# Jamf Migrator overhaul plan

Status: **approved for review, not started** (2026-10-03)

## Goal

Set up a "golden master" Jamf tenant once, then copy it into a new, empty tenant with one button, so the new tenant is ready to use.
Jamf Migrator does what [terraform-provider-jamfplatform](https://github.com/jamf/terraform-provider-jamfplatform) does, but as a GUI. That provider, [jamf-cli](https://github.com/Jamf-Concepts/jamf-cli) and the Jamf API MCP server (`https://developer.jamf.com/mcp`) are the references for endpoint shapes, required fields and gateway quirks.

## Decisions

| Topic | Decision |
|---|---|
| API | Jamf Platform API gateway only: `https://{us\|eu\|apac}.api.jamfcloud.com`, client credentials, `X-Environment-Id` header, environment-scoped integration. Every legacy auth method is removed. |
| Endpoint versions | Always the newest version of every endpoint (never v1 when v3 exists). Use the Jamf Pro API in preference to Classic wherever the Pro API has full create/read/update/delete. Classic is used only for objects that have no full Pro API equivalent. |
| UI | SwiftUI rewrite for macOS 26 (Liquid Glass) using async/await. No storyboards, no Combine. |
| CLI | Headless/command-line mode is dropped. jamf-cli covers scripting. |
| Delete mode | Stays on across runs until you switch it off, but always starts off at launch. Red banner, and every run asks for confirmation. |
| Blueprint deploy | Copies the source state. `DEPLOYED` → deploy. `OUT_OF_DATE` → deploy, with a warning in the dry run. `NOT_DEPLOYED` → leave undeployed. |
| Dropped object types | API roles and API integrations (the gateway doesn't serve them), computers, mobile devices. |
| Added | PreStages (with ADE instance mapping), enrollment customizations, Blueprints, Compliance Benchmarks, tenant settings, dry-run preview, one-button tenant clone, gated one-button tenant wipe. |

## What gets copied, in order

The API column shows the intended split. The newest version of each endpoint is confirmed against the gateway spec in Phase 2 and pinned in the registry.

| Step | Objects | API |
|---|---|---|
| 1 | Sites | Classic (Pro `/sites` is read-only) |
| 2 | Categories, buildings, departments | Pro |
| 2 | Network segments | Classic |
| 3 | Computer and mobile extension attributes | Pro |
| 3 | User extension attributes | Classic |
| 4 | Scripts, packages (records only), distribution points | Pro |
| 5 | Jamf accounts (users and groups) | Pro where full CRUD is available, otherwise Classic |
| 5 | LDAP servers, users, user groups, directory bindings, disk encryption, software update servers | Classic, unless the Pro API has full CRUD |
| 6 | Smart computer groups, smart and static mobile groups | Pro |
| 6 | Static computer groups, advanced searches | Classic, unless the Pro API has full CRUD |
| 7 | Configuration profiles, Mac and mobile apps, ebooks, classes, restricted software, printers, dock items | Classic |
| 7 | Icons | Pro `/v1/icon` |
| 8 | Policies | Classic |
| 8 | Patch titles and patch policies | Pro `/v3/patch-software-title-configurations`, `/v2/patch-policies` |
| 8 | App Installers | Pro |
| 9 | Enrollment customizations | Pro v2 |
| 10 | Computer and mobile PreStages | Pro v3 |
| 11 | Blueprints | Platform `/blueprints/v1` |
| 12 | Compliance Benchmarks | Platform `/compliance-benchmarks/v1` |
| 13 | Tenant settings: check-in, inventory collection, SMTP, Self Service settings, re-enrollment, LAPS settings, onboarding | Pro (`/pro/v3/check-in`, `/pro/v2/smtp-server`, `/pro/v2/local-admin-password/settings`, …) |
| 13 | Webhooks | Classic |
| 13 | SSO | Pro `/pro/v3/sso` (prompts for its secrets) |

Groups that reference other groups are ordered among themselves.

Smart groups are created through the Pro API, while policies and profiles stay on Classic, so the IDMap has to record each group's Jamf Pro id. Classic payloads keep referencing groups by id or name.

**Can't be copied.** These are shown as a manual checklist before the run:
- ADE tokens: one per tenant, created in ABM/ASM against the destination's public key.
- VPP / Apps and Books tokens.
- APNs certificate.
- SSO certificates.
- API clients.
- Package files: the gateway's CDN firewall blocks uploads, so packages must already be on the destination's distribution points.

**Secrets the API won't return.** The app asks for these, or uses the values from Settings:
- LDAP and directory-binding passwords
- PreStage admin and recovery-lock passwords
- SMTP password
- SSO secrets

## Architecture

```
JamfMigrator/
├─ Platform/   PlatformClient (actor), TokenProvider (actor), Region, GatewayError, Retry/Poll helpers
├─ Tenants/    Tenant (region, environment UUID, client ID; secret in Keychain), TenantStore
├─ Objects/    ObjectType registry: API + pinned version, paths, dependencies, step, delete order, read-only/secret fields
├─ Transform/  Per-type transformers (ported from Cleanup.swift), IDMap, GroupResolver
├─ Planner/    MigrationPlanner → MigrationPlan (dry run), Preflight
├─ Engine/     MigrationEngine, DeleteEngine, ExportWriter, RunJournal (resume), RunReport
├─ Features/   Blueprints, Benchmarks, PreStages, TenantSettings
├─ UI/         NavigationSplitView shell, CloneWizard, PlanView, RunView, ResultsView, Settings
└─ Tests/      Swift Testing
```

**`PlatformClient`** sends every request:
- Adds the Bearer token, `X-Environment-Id`, and the correct Accept and Content-Type headers (XML for `/proclassic`).
- Sends `Accept-Encoding: identity` on writes.
- Never follows `href`; uses the returned `id` instead.
- Retries 429 using `Retry-After`. Retries 5xx only for idempotent methods. Throttles writes.
- Decodes **three error shapes** (see Gateway findings).

**`TokenProvider`** caches the token (`expires_in` is 900 s, and there is no refresh token). It refreshes at about 80% of the lifetime, allows only one refresh at a time, and fetches a new token once on a 401.

**Shared polling helper** for things that aren't ready straight after a write:
- PreStage `profileUuid`
- benchmark `syncState`
- 404s just after a write

**`ObjectType` registry** pins every type to the **newest** endpoint version, and to the Pro API wherever it has full CRUD.
- The gateway only serves the newest version. Older versions return `403 BAD_PERMISSIONS`, so an old version looks the same as a missing permission.
- A unit test checks the registry against the gateway spec, so a version bump in the spec fails the test.
- Tenant validation calls each registry endpoint and reports any type the integration lacks permission for.

**`IDMap`** maps source ids to destination ids (and group UUIDs). It is saved in the **RunJournal**, so a failed run can resume and a second run is safe. Objects are matched by name.

## Key features

### One-button "Clone tenant"

1. **Connect.** Validate both tenants (`GET /pro/v1/jamf-pro-version`) and check permissions for every endpoint.
2. **Preflight.**
   - Warn if the destination isn't empty.
   - Show the manual checklist.
   - Map ADE instances. If the destination has exactly one, map it automatically; if it has none, the PreStages are blocked.
   - Map distribution points.
   - Ask for the secrets.
3. **Dry-run preview.** Review it, then confirm.
4. **Run** in step order, with progress for each step. Can be cancelled, paused and resumed.
5. **Verify.** Compare counts and spot-check objects, then show a results report that can be exported.

Choosing types and objects by hand stays available for partial copies.

### One-button "Wipe tenant" (gated)

Wipe tenant is the reverse of Clone tenant: it empties one tenant completely. It uses the same planner, engine and RunJournal, but runs the steps in reverse order: tenant settings stay as they are, then Benchmarks → Blueprints → PreStages → enrollment customizations → … → sites.

**Gates.** Every gate must pass before the button becomes active:
1. **Delete mode is on.** The Wipe button only appears in delete mode.
2. **The tenant isn't protected.** Each tenant has a **Protected** toggle, on by default for whichever tenant you mark as the golden master. A protected tenant can't be wiped at all; you have to switch protection off in Settings first.
3. **Dry-run preview.** It lists everything that will be deleted, with counts per type, and everything that will be kept (see below).
4. **Backup.** Before deleting, the app exports the whole tenant to a folder (the existing export feature) and checks that the export completed. You can skip this only through an extra "I don't need a backup" confirmation.
5. **Typed confirmation.** You type the tenant's display name exactly, and then click a destructive button that names the tenant and the object count.

**What is kept.** These can't or shouldn't be deleted:
- Built-in objects such as "All Managed Clients" and the other default smart groups, and the default distribution point and site settings.
- ADE instances, VPP tokens, APNs and the API integration used to run the wipe.
- Tenant settings (check-in, SMTP, SSO and the like). They are singletons, so there's nothing to delete. An optional "reset to defaults" can come later.
- Computers and mobile devices (inventory records). They aren't in scope for this app.

**How it runs:**
- It retries `422 HAS_DEPENDENCIES` and `406/409` responses after the step that held the reference has finished.
- It accepts a Blueprint delete that returned 500 if a follow-up GET returns 404.
- When a Classic DELETE returns a misleading 400, a follow-up GET decides whether the delete actually happened.
- It can be cancelled and resumed.
- At the end it lists every object it couldn't delete, with the reason.

### Dry-run preview

Reads both tenants and changes nothing. Each object is shown with one outcome:

| Outcome | Meaning |
|---|---|
| **Create** | The object isn't on the destination yet. |
| **Update** | The object exists on the destination but differs. The inspector shows a diff. |
| **Unchanged** | The object exists and is identical. It is skipped. |
| **Replace** | The object exists but can't be updated in place, so it will be deleted and recreated. This applies to Compliance Benchmarks only, and you have to confirm it. |
| **Blocked** | A dependency isn't selected, a group can't be resolved, an ADE instance isn't mapped, a secret is missing, or more than one destination object has the same name. |
| **Warning** | Will be copied, but check it: a Blueprint is `OUT_OF_DATE` on the source, a Blueprint component is linked to VPP, or a write-only field (such as a password) can't be copied. |

The run then carries out exactly that plan. In delete mode, the preview lists what will be removed.

### PreStages (`/pro/v3/computer-prestages`, `/pro/v3/mobile-device-prestages`)

- **Remapped fields:**
  - `deviceEnrollmentProgramInstanceId` (taken from the ADE mapping)
  - `enrollmentSiteId`
  - `locationInformation.buildingId` and `locationInformation.departmentId`
  - `enrollmentCustomizationId` (`0` means none)
  - `prestageInstalledProfileIds`
  - `customPackageIds`
  - `customPackageDistributionPointId` (`-2` means the cloud distribution point)
  - `pssoConfigProfileId` and `rtsConfigProfileId`
- **Not copied:**
  - Scope (serial numbers). Devices belong to each tenant's ADE token.
  - Admin and recovery-lock passwords. The API doesn't return them; you enter them in the wizard.
- **Writing:**
  - A PUT echoes every `versionLock`: root, `locationInformation`, `purchasingInformation` and `accountSettings`.
  - After writing, wait for `profileUuid` before making further changes.
  - Set the default PreStage last.

### Blueprints (`/blueprints/v1`)

- **Before writing:** strip `id`, `created`, `updated` and `deploymentState`.
- **Remap device-group UUIDs** in `scope.deviceGroups` and in `activationPredicate`. Each group is looked up by name and type: `GET /pro/v2/groups` returns `groupPlatformId` (this is the same id as in `/device-groups/v1`).
- **Configuration-profile components:** give each `payloadIdentifier` a new UUID.
- **`app-managed` components:** look up the destination's VPP asset IDs through `/v1/blueprint-components`, or raise a Warning.
- **Matching:**
  - One destination match by name → update it with `PATCH`, sending the full `steps` array.
  - No match → `POST`.
  - More than one match → Blocked.
- **Deploy** according to the decision above. A second deploy is harmless.
- **Delete mode:** `DELETE` straight away. No undeploy is needed first.

### Compliance Benchmarks (`/compliance-benchmarks/v1`)

- **Copy:**
  - Map `baselineId` (in the GET response) to `sourceBaselineId` (in the POST request).
  - Copy `rules[{id, enabled, odv}]`, `enforcementMode` and `selectedOsVersions`.
  - Remap the device groups in `target.deviceGroups`.
- After `POST`, poll `syncState` until it is `SYNCED`, and report `FAILED`.
- There is no update endpoint. A benchmark that differs is shown as **Replace** (delete, then recreate).
- Titles must be unique. A 409 `DuplicateFieldException` means a benchmark with that title already exists, and it is treated as a match.

### Sticky delete mode

- `AppState.mode` is kept in memory only, so the app always starts in Copy mode.
- Toggle it with ⌘D or the toolbar.
- When it's on:
  - a red banner is shown and the Run button turns red;
  - before each run, a confirmation dialog shows the destination tenant's name and the counts from the dry run;
  - deletes run in reverse order: Benchmarks and Blueprints first, then PreStages, then everything else. The gateway refuses to delete groups that are still in use (`422 HAS_DEPENDENCIES`).
- This removes the `DELETE` marker file, its 0.5 s polling loop, and the roughly 15 places that reset the mode.

## Interface (SwiftUI, Liquid Glass)

- **Window:** a `NavigationSplitView` with three parts.
  - **Sidebar:** source and destination tenants with their status, then object groups in step order, with counts and planned changes.
  - **Middle:** object list with checkboxes, search, and each object's dry-run outcome.
  - **Inspector:** details and a diff for the selected object.
- **Toolbar:** source → destination selector, Clone tenant, Preview, Run, and the Copy/Delete toggle. In delete mode, Clone tenant is replaced by a red **Wipe tenant** button.
- **Run and results:** a Run view with progress per step, and a Results report that replaces `SummaryView` and the HTML summary.
- **Settings scene:**
  - Copy and scope options
  - Export
  - Sites
  - Service-account secrets
  - Advanced: concurrency and throttling
- **Help:** a short in-app page plus the README.
- Look up the current Liquid Glass and toolbar APIs with DocumentationSearch before building the UI.

## Phases

| Phase | What happens |
|---|---|
| 0 – Setup | Create the `overhaul` branch. Rename the project and module to `JamfMigrator`. Move the Application Support and Logs folders and the keychain service names off "Replicator", migrating existing entries once. Remove TelemetryDeck. Add a Swift Testing target. |
| 1 – Platform client | Tenant model, `TokenProvider`, `PlatformClient`, retry and polling helpers, endpoint permission probe. Remove the old login code: Basic auth, user/password tokens, `/api/oauth/token`, sticky-session cookies, `healthCheck.html` and `urlFix`. Tests. |
| 2 – Registry and engine | `ObjectType` registry, `IDMap`, ported transformers, `MigrationEngine` and `DeleteEngine`, export, RunJournal. Steps 1–8 work on the new layer. |
| 3 – Planner | Preflight and dry-run outcomes, with diffs. |
| 4 – UI | SwiftUI shell, object lists, inspector, Run and Results views, Settings, sticky delete mode. |
| 5 – Clone and Wipe | Clone tenant: ADE and distribution-point mapping, collecting secrets, verifying the result, resuming. Wipe tenant: the protected-tenant flag, a required backup, the typed confirmation, and a report of anything left behind. |
| 6 – Platform objects | Enrollment customizations and PreStages, Blueprints, Compliance Benchmarks, tenant settings. |
| 7 – Cleanup | Delete the old `ViewController`, `SourceDestVC`, storyboards, `SummaryViewController`, `EndpointXml.swift` and `SaveDelegate.swift`. Also remove the duplicate icon pipeline, about 1,000 commented-out lines, the CLI parsing, help images and the `Notes` group. Rewrite the README: setting up the integration, the permission list, what is copied and what isn't, and the manual checklist. |
| 8 – Live validation | 1. Add sample Blueprints, a benchmark, PreStages and an enrollment customization to the sandbox. 2. Wipe demo, which proves Wipe works and gives an empty destination. 3. Clone sandbox → demo. 4. Run it again; every object should be Unchanged. 5. Test resuming after an interruption. 6. Wipe demo again. |

## Bugs from the code review

Each is fixed as its code is ported, or disappears when the old code is deleted.

| # | Bug | Location |
|---|---|---|
| 1 | `pagedGet` never signals its semaphore, so the thread hangs | `Jpapi.swift:751-779` |
| 2 | `runComplete` watches an unused icon queue | `ViewController.swift:4810` |
| 3 | `updateUiDelegate` is never set, so the icon label and the "Stop" option don't work | `IconDelegate`, `Jpapi` |
| 4 | Patch default path `v2/…` is missing the `api/` prefix | `PatchManagementApi.swift:155` |
| 5 | Object type checked with a substring match, and crashes when the list is empty | `CreateEndpoints.swift:113,243`, `RemoveObjects.swift:119` |
| 6 | Counter increments aren't atomic | `ViewController.swift:36+` |
| 7 | `saveTrimmedXmlScope` reads the raw XML pref | `ViewController.swift:1266` |
| 8 | API roles/integrations: wrong source/destination counts, a race, and wrong results on multi-page lists | `Jpapi.swift:351-363, 483-488` |
| 9 | Missing token is stored as nil, then force-unwrapped | `JamfPro.swift:186,205` |
| 10 | Export path display still strips the old `com.jamf.jamf-migrator` container prefix | `PreferencesViewController.swift:571,786` |
| 11 | Every TLS certificate is accepted (`serverTrust!`) | 6 files |
| 12 | Main thread blocked by `sleep()` and semaphores; Summary window observer leaks | `AppDelegate:97`, `ViewController:4851,6488` |
| 13 | Release builds `print` headers and full request bodies | `ViewController.swift:4835,3654` and others |
| 14 | Destination credentials keyed as `"destination"` instead of `"dest"` | `Credentials.swift:221` |

## Gateway findings (tested live, 2026-10-03)

The write tests ran on the demo tenant. All test objects were named `JM-TEST …`, scoped to an empty static group, and deleted afterwards. The sandbox was only read.

- **Sandbox (source):** Jamf Pro 11.32.0. Contents:
  - 52 policies, 48 macOS profiles, 0 mobile profiles
  - 47 computer groups (53 groups in total in `/pro/v2/groups`)
  - 178 App Installers, 30 scripts, 27 categories, 22 computer EAs
  - 15 mobile apps, 5 Mac apps, 5 packages
  - 1 ADE instance, 0 sites
  - 0 Blueprints, 0 benchmarks, 0 PreStages, 0 enrollment customizations
- **Demo (destination):** Jamf Pro 11.33.0 beta, so the two tenants run different versions. The registry and transforms must handle a source that's one version older.

- **Auth:** `POST /auth/token` returns `expires_in: 900` and `refresh_expires_in: 0`, so there is no refresh token. Re-authenticate with the client credentials.
- **Only the newest API version is served:**
  - `/pro/v1/check-in` → 403, `/pro/v3/check-in` → 200
  - `/pro/v1/sso` and `/pro/v2/sso` → 403, `/pro/v3/sso` → 200
  - `/pro/v1/smtp-server` → 403, `/pro/v2/smtp-server` → 200
  - `/pro/v1/computer-groups/smart-groups` → 403, `/pro/v2/...` → 200
- **Endpoints that worked:**
  - Read: categories, buildings, departments, scripts, packages, sites, `/pro/v2/groups`, `/pro/v3/*-prestages`, `/pro/v1/device-enrollments`, `/pro/v2/enrollment-customizations`, App Installers, `/pro/v2/patch-*`, EAs, inventory collection, Self Service settings, re-enrollment, LAPS settings, onboarding, cloud distribution point, `/pro/v1/csa/token`.
  - Classic: policies, configuration profiles, computer groups, webhooks, accounts, LDAP servers, sites, SMTP server, check-in.
  - Full lifecycle, plus Blueprints, Device Groups and Benchmarks: a Classic category was created, read back immediately and deleted.
- **403 for the demo integration:**
  - `api-roles` (expected)
  - `self-service-branding`
  - `cloud-ldaps`
  - `ldap-servers` (the Pro API version; Classic `ldapservers` worked)
  - `engage`
  - `client-check-in`
  - Each of these is either a missing permission or an endpoint the gateway doesn't serve. The permission probe will tell them apart.
- **Write responses:**
  - `href` points at internal hosts (`us.int.apigw.jamf.com`, `use1.tyk-external.jprosvc.jamfapps.io`). Never follow it.
  - A Classic POST returns `<category><id>26</id></category>` (201). A Classic DELETE returns 200.
- **Three error shapes:**
  - Gateway/Pro: `{httpStatus, traceId, errors[{code, field, description}]}`
  - Benchmarks: `{message, error, statusCode, logref}`
  - Device groups: pretty-printed variant of the gateway shape
- **Device groups:**
  - A newly created group can be read back immediately.
  - `groupPlatformId` in `/pro/v2/groups` is the same as `id` in `/device-groups/v1`.
  - Deleting a group that a Blueprint still uses returns `422 HAS_DEPENDENCIES`.
- **Blueprints:**
  - Component settings use `{Included, Value}` objects. GET returns `Included`, so a read-then-write round trip loses nothing.
  - Passcode settings require `RequirePasscode` whenever any other field is set.
  - `PATCH` with `steps` replaces all steps.
  - Any `PATCH`, even one that only changes the description, makes a deployed Blueprint `OUT_OF_DATE`.
  - `deploy` returns 202; it was `DEPLOYED/SUCCEEDED` within about 3 s. A second deploy right away also returns 202 and is harmless.
  - Two Blueprints can have the same name.
  - Deleting a deployed Blueprint works without undeploying first (204).
- **Benchmarks:**
  - `POST` returns 201 with the full body and reaches `SYNCED` within about 5 s.
  - The GET detail contains only the rules that were sent; when `selectedOsVersions` is omitted, it defaults to every available version.
  - A duplicate title returns 409.
  - `DELETE` returns 204, and the benchmark is gone within about 5 s.
- **PreStages:**
  - The demo tenant has one computer PreStage: ADE instance `1`, cloud distribution point `-2`, one package, `versionLock` 6, and `accountSettings.versionLock` 2.
  - `adminPassword` is never returned.

## Open items

- **Sandbox content:** it has no Blueprints, benchmarks or PreStages yet. Add examples before Phase 8.
- **Demo isn't empty:** it already contains Terraform-managed objects (prefixed `TF - `). Phase 8 wipes it first, so the Clone test starts from a truly empty tenant.
- **Rate limits:** no numbers are published, so throttle writes and back off on CDN firewall 403s.
- **VPP mapping:** whether `app-managed` Blueprint components can be mapped to the destination's VPP automatically.
- **Unsupported content:** which Classic payloads trigger the `file://` CDN firewall block, and which configuration-profile payload types Blueprints accept.
