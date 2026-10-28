# Change log

## Unreleased
- Run now carries out exactly the plan Preview showed: only the ticked
  objects that Preview marked to create, update or delete. Unchanged
  objects are skipped, objects added after Preview are left alone, and
  changing the selected types after Preview turns Run off until you
  preview again.
- Run stops before writing an object that changed on the source or the
  destination since Preview, or when Settings › Secrets or the mappings
  changed, and asks for a new Preview. The run report says what changed
  (for Secrets only that they changed, never a value).
- Objects with the same name on the source are all blocked, as are
  duplicates on the destination; Run never picks one of them.
- Unticking an object that a ticked object needs (for example a script's
  new category) turns Run off and says which object needs it.
- If creating an object fails during Run, the objects that need it are not
  written with a missing reference; they are reported as not written, and
  Resume run retries them.
- Delete mode deletes only the objects Preview listed, and stops if one
  changed since Preview.
- Verify marks a type it couldn't read as "Not checked" instead of
  passing it.
- Fixed: new static computer groups failed to copy (Jamf answered with
  an error); they are now created empty as intended.
- Blueprints and Compliance Benchmarks are left out of Preview while a
  tenant connects directly to Jamf Pro, instead of showing as blocked.
- The run window's help names where run reports are saved, also in demo
  mode.

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
