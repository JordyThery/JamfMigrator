# Change log

## v1.0.5
- Fixed: patch management titles were never copied — the type always
  appeared empty, and patch policies were blocked as a result. Titles are
  now listed, created by subscribing the destination to the same title
  from the same patch source, and updated with the source's display name,
  category, site, notifications, packages and accepted extension
  attributes.
- The Permissions page notes the patch source reads a new title needs on
  the destination.

## v1.0.4
- Licensed software is now copied (step 7). The licenses and their
  purchasing details are copied; the list of matching computers comes
  from inventory and is not, and license attachments are left behind with
  a warning in the run report.
- The Permissions page lists the new type, and notes Jamf Pro's separate
  View License Serial Numbers privilege for direct connections.

## v1.0.3
- An update check: at launch, at most once a day, the app asks GitHub
  for the latest release and offers a newer one with its release notes
  and a download. Check on demand from Jamf Migrator › Check for
  Updates…; turn the daily check off in Settings › Updates.

## v1.0.2
- A dry run now shows a clear progress view while it plans ("type 12 of
  51"), and opens on a new Summary page: totals per outcome, every
  planned type with its counts, and a legend for the sidebar badges.
- Clone tenant: missing permissions and a non-empty destination are
  warnings now and no longer block the wizard ("Continue anyway"), with a
  button to leave the denied types out. Blueprints and Compliance
  Benchmarks are skipped on direct connections instead of being reported
  as missing permissions.

## v1.0.1
- Fixed: secrets and passwords entered in Settings were not saved in the
  released build, so every tenant failed with "No client secret or
  password is stored". Secrets now go to the login keychain, and Settings
  shows a warning if the Keychain ever refuses a save.

## v1.0
First release. A complete rewrite of Replicator as a SwiftUI app for
macOS 26: 52 object types over the Jamf Platform API gateway or direct
Jamf Pro connections, a dry-run preview with field-level diffs,
selective migration down to a single object, a resumable journaled
engine, the Clone tenant and Wipe tenant guided flows, a verify pass,
and a guided tour.
