# Permissions

Jamf Migrator only needs the permissions for the object types you copy.
This page lists them per type, so you can give each tenant's API
integration (or API role) the least it needs.

## How to read this page

Each tenant connects one of two ways (see [Connections](../README.md#connections)),
and the two name permissions differently:

- **Platform API gateway**: an API integration in Jamf Account, granted
  *capabilities*. Each capability has actions such as Read, Create, Update and
  Delete. The API refers to them as `policies:read`, `policies:create`, and so on.
- **Direct Jamf Pro**: an API client with an API role, or a Jamf Pro user,
  granted Jamf Pro *privileges* named `<Action> <group>`, e.g. **Read
  Policies** or **Create Policies**.

What each tenant needs depends on its role:

| Tenant | Actions | Used for |
|---|---|---|
| Source | Read | Listing and reading every object of the selected types |
| Destination | Read, Create, Update | Matching objects by name, comparing them in the dry run, and writing changes |
| Destination, delete mode or Wipe tenant | Read, Delete | Listing the tenant and deleting objects |

The Wipe tenant backup reads the tenant being wiped, so it needs no extra
permissions.

## Object types

For each type, grant the actions above on its **gateway capability** or its
**Jamf Pro privilege group**. A few types share one capability; granting it
once covers them all.

**Also reads** lists the types this type references: categories, sites,
groups and so on. The app lists those on **both tenants** to map ids from
the source to the destination, even when you aren't copying them, so both
integrations need **Read** on them. If one of those reads is denied, the
whole type is blocked in the dry run.

| Step | Object type | Gateway capability | Jamf Pro privilege group | Also reads |
|---|---|---|---|---|
| 1 | Sites | `sites` | Sites | — |
| 2 | Categories | `categories` | Categories | — |
| 2 | Buildings | `buildings` | Buildings | — |
| 2 | Departments | `departments` | Departments | — |
| 2 | Network segments | `network-segments` | Network Segments | — |
| 3 | Computer extension attributes | `extension-attributes` | Computer Extension Attributes | — |
| 3 | Mobile device extension attributes | `extension-attributes` | Mobile Device Extension Attributes | — |
| 3 | User extension attributes | `user-extension-attributes` | User Extension Attributes | — |
| 4 | Scripts | `scripts` | Scripts | Categories |
| 4 | Packages | `packages` | Packages | Categories |
| 4 | Distribution points | `distribution-points` | Distribution Points | — |
| 5 | LDAP servers | `ldap-servers` | LDAP Servers | — |
| 5 | Jamf user accounts | `accounts` | Accounts | Sites |
| 5 | Jamf group accounts | `accounts` | Accounts | Sites, LDAP servers |
| 5 | Users | `users` | User | Sites |
| 5 | User groups | `user-groups` | Smart User Groups, Static User Groups | Users, Sites |
| 5 | Directory bindings | `directory-bindings` | Directory Bindings | — |
| 5 | Software update servers | `software-update-servers` | Software Update Servers | — |
| 6 | Smart computer groups | `device-groups` | Smart Computer Groups | Sites, Computer extension attributes |
| 6 | Static computer groups | `device-groups` | Static Computer Groups | Sites |
| 6 | Smart mobile device groups | `device-groups` | Smart Mobile Device Groups | Sites, Mobile device extension attributes |
| 6 | Static mobile device groups | `device-groups` | Static Mobile Device Groups | Sites |
| 6 | Advanced computer searches | `advanced-device-searches` | Advanced Computer Searches | Sites, Computer extension attributes |
| 6 | Advanced mobile device searches | `advanced-device-searches` | Advanced Mobile Device Searches | Sites |
| 6 | Advanced user searches | `advanced-user-searches` | Advanced User Searches | Sites |
| 7 | macOS configuration profiles | `configuration-profiles` | macOS Configuration Profiles | Categories, Sites, Smart computer groups, Static computer groups |
| 7 | Mobile device configuration profiles | `configuration-profiles` | iOS Configuration Profiles | Categories, Sites, Smart mobile device groups, Static mobile device groups |
| 7 | Mac applications | `applications` | Mac Applications | Categories, Sites, Smart computer groups, Static computer groups |
| 7 | Mobile device applications | `applications` | Mobile Device Applications | Categories, Sites, Smart mobile device groups, Static mobile device groups |
| 7 | eBooks | `ebooks` | eBooks | Categories, Sites |
| 7 | Classes | `classes` | Classes | Sites, User groups, Static mobile device groups |
| 7 | Restricted software | `restricted-software` | Restricted Software | Sites, Smart computer groups, Static computer groups |
| 7 | Printers | `printers` | Printers | Categories |
| 7 | Dock items | `dock-items` | Dock Items | — |
| 8 | Policies | `policies` | Policies | Categories, Sites, Smart computer groups, Static computer groups, Packages, Scripts, Printers, Dock items, Network segments, Distribution points |
| 8 | Patch management titles | `patch-management-software-titles` | Patch Management Software Titles | Categories, Sites, Packages |
| 8 | Patch policies | `patch-policies` | Patch Policies | Patch management titles, Smart computer groups, Static computer groups |
| 8 | App Installers | `applications` | Mac Applications | Categories, Sites, Smart computer groups |
| 9 | Enrollment customizations | `enrollment-customization` | Enrollment Customizations | Sites |
| 10 | Computer PreStages | `prestage-enrollments` | Computer PreStage Enrollments | Sites, Buildings, Departments, Packages, macOS configuration profiles, Enrollment customizations, Distribution points |
| 10 | Mobile device PreStages | `prestage-enrollments` | Mobile Device PreStage Enrollments | Sites, Mobile device configuration profiles, Enrollment customizations |
| 11 | Blueprints | `blueprints` | — (gateway only) | Device groups — `device-groups:read` |
| 12 | Compliance Benchmarks | `compliance-benchmarks` | — (gateway only) | Device groups — `device-groups:read` |
| 13 | Webhooks | `webhooks` | Webhooks | Smart computer groups, Static computer groups |

### Settings

Settings exist exactly once per tenant, so they are only read and updated:
**Read** on the source, **Read** and **Update** on the destination. Delete
mode leaves them as they are.

| Settings | Gateway capability | Jamf Pro privilege group |
|---|---|---|
| Check-in settings | `computer-check-in` | Computer Check-In |
| Inventory collection settings | `computer-inventory-collection-settings` | Computer Inventory Collection Settings |
| SMTP server | `smtp-server` | SMTP Server |
| Self Service settings | `self-service` | Self Service |
| Re-enrollment settings | `re-enrollment` | Re-enrollment |
| LAPS settings | `local-admin-passwords` | Local Admin Password Settings |
| Onboarding | `onboarding` | Onboarding Configuration |
| Single sign-on | `sso-settings` | SSO Settings |

## Exceptions

- **Compliance Benchmarks** have no update endpoint. A changed benchmark is
  deleted and recreated, so the destination needs `compliance-benchmarks`
  **Delete** as well as Create, even when you're only copying.
- **Blueprints** that are deployed on the source are deployed on the
  destination after they're created, which needs `blueprints` **Deploy** on
  the destination.
- **Blueprints and Compliance Benchmarks** are only available through the
  Platform API gateway. They reference device groups by their platform id, so
  both tenants also need `device-groups` **Read**.
- **LAPS settings**: Jamf's API spec requires the update permission even for
  reading them, so both tenants need `local-admin-passwords` **Update**. On a
  direct connection, both tenants need **Update Local Admin Password
  Settings**.
- **Distribution points**: Jamf's spec lists Read alongside Update for
  updating them. The destination has Read anyway.
- **Categories**: the category list also accepts Read Self Service. Grant
  Read Categories.
- **Self Service icons** of policies, Mac applications and mobile device
  applications are downloaded from the source and uploaded to the
  destination. Jamf's spec lists no separate privilege for the icon
  endpoints.

## Clone tenant wizard

The Prepare step maps ADE instances and distribution points between the
tenants. It reads both on both tenants:

| Reads | Gateway capability | Jamf Pro privilege |
|---|---|---|
| ADE instances | `device-enrollment-program-instances` | Read Device Enrollment Program Instances |
| Distribution points | `distribution-points` | Read Distribution Points |

Both are optional: without them, the Prepare step has nothing to map.

The Connect step checks each selected type by reading its list on both
tenants, and names the types the integration can't read. It can't detect a
missing Create, Update or Delete permission without writing. Those show up
as failed objects in the run report, with Jamf's error.

## Sources

The permissions are taken from the `x-required-privileges` of every
endpoint the app calls, in the API specs Jamf publishes in
[jamfplatform-go-sdk](https://github.com/jamf/jamfplatform-go-sdk) (Jamf Pro
API 11.33.0, Classic API 11.32.0, Blueprints, Compliance Benchmarks). The Jamf
Pro API spec also names the matching Jamf Pro privilege. The Classic API spec
only names gateway capabilities, so the privilege groups for Classic types
were matched by name. Every privilege on this page is checked against the
privilege list of a Jamf Pro 11.32 instance.
