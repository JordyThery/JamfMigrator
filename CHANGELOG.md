# Changelog

## 1.2.3 — 2026-11-28

- A stopped run now shows as stopped, with how far it got, and Resume Run carries on where it left off, in the run window, Clone Tenant and Wipe Tenant alike.
- LDAP and directory binding passwords containing `$` or `\` are now written to the destination exactly as entered in Settings › Secrets.
- Wipe Tenant only accepts a backup made for the current Preview; a new Preview or a change of the selected types asks for a new backup.
- Backups and exports keep scripts and other object text as they are; only passwords and other secret fields, configuration profile passwords and license serial numbers included, are replaced by `<redacted>`.
- Copying no longer changes the destination accounts that keep it reachable: the account the destination signs in with and its full-access administrators are shown as Blocked, with the reason.
- Delete mode checks each Jamf Pro account again right before deleting it: if one became a full-access administrator since Preview, the run stops before deleting it and asks for a new Preview.
- A delete run that ends early lists the objects Jamf Pro refused and why, and an object still refused after every retry keeps Jamf Pro’s own reason.
- Run stays off after a tenant’s connection is edited in Settings until a new Preview. Jamf Migrator now has a single main window; Run, Clone Tenant and Wipe Tenant in the menu bar bring it back when it’s closed.
- Clone Tenant says when the ADE instances or distribution points couldn’t be read, with Load Again, instead of showing an empty tenant, and its connection check always matches the tenants shown.
- A Self Service icon whose file name contains quotes or line breaks now copies correctly.
- Jamf Migrator no longer asks for access to the Downloads folder.
- Settings › Export names the folder exports go to, also in Demo Mode, and the saved Verify report uses plain labels.

## 1.2.2 — 2026-11-23
- Policies with Fix Disk Permissions turned on now show a warning when copied
  to Jamf Pro 11.34 or later, which no longer keeps this setting.
- Policies with Fix Disk Permissions turned off no longer show as different
  after copying.
- Preview is more reliable when its checks run at the same time.

## 1.2.1 — 2026-11-16
- Preview and Verify no longer report a policy or macOS profile as different
  only because Jamf Pro left out its Self Service notification settings while
  notifications are off.
- The warning about Self Service notification settings that Jamf Pro doesn’t
  keep now also covers Jamf Pro 11.35.
- When the Keychain refuses to remove a tenant’s password, Settings keeps the
  tenant in the list and says so, so you can delete it again.

## 1.2.0 — 2026-11-02
- Settings asks to save or discard unsaved tenant changes, the Protected
  switch included, before it closes or another tab opens.
- Clone Tenant: Continue and Preview wait until the ADE instance and
  distribution point mappings have loaded; every step has a Back button, and
  after a run stops because something changed, Preview Again leads straight
  back to Preview. Changing a mapping after Preview turns Run off until the
  next Preview, and when Run or Verify can’t start, the wizard says why.
- A field Preview treats as unchanged (an empty value, or the same number
  written differently) no longer stops a run as “changed since Preview”.
- Stop shows “Stopping after the current object…” and ends a wait before a
  retry or a Blueprint deployment watch at once, also one that begins while
  the run stops; the object being written still finishes. The run view
  shows when Jamf asks the app to wait.
- Onboarding: a list the API client can’t read (policies, profiles, Mac apps
  or App Installers) only blocks the onboarding items that need it.
- Wipe Tenant’s backup covers the types Preview planned, so a tenant that
  connects directly to Jamf Pro is no longer refused because of Blueprints
  and Compliance Benchmarks.
- A Keychain that can’t be read is reported as such, instead of as a
  missing client secret, password or Settings › Secrets value.
- A server address saved without https:// gets it added; an http:// address
  asks for https.
- The object list shows each type’s counts and how many changes are checked,
  and the sidebar’s counts are in words; the inspector’s differences can be
  sorted by field, source or destination, and a missing value reads “Not set”.
- Opening Settings › Secrets no longer saves the stored passwords again.
- Self Service icons are copied also when their address redirects to another
  secure (https) address.
- Jamf Pro 11.34 doesn’t keep the Self Service notification settings of
  policies and macOS profiles: when a copied policy or profile has Self
  Service notifications turned on, Preview and the run report say so for an
  11.34 server, so you can set them in Jamf Pro after copying.
- The app follows the Mac’s Light or Dark appearance; Settings no longer has
  an Appearance choice or a General tab.
- The delete-mode banner names the tenant and has a Switch to Copy button;
  the wizards’ Close button is at the bottom.
- Clearer badges and status lines for VoiceOver and in high contrast.

## 1.1.0 — 2026-10-31
- Fixed: a Blueprint that isn’t deployed on the source was deployed on the
  destination, and an out-of-date one wasn’t deployed. Now only a deployed
  Blueprint is deployed, and an out-of-date one is deployed with a warning.
- Fixed: a run could skip objects a new Preview planned, and report them as
  done, when an earlier run of the same tenants had stopped or failed. Only
  Resume Run of the same Preview skips what was already done.
- Settings › Secrets values no longer appear in saved payloads (Settings ›
  Export) or in the inspector’s differences: passwords, password hashes,
  Secrets values and license serial numbers show as “<redacted>”.
- Delete mode and Wipe Tenant never remove the account a direct connection
  signs in with, nor a Jamf Pro account or group with full access and the
  Administrator privilege set; Preview lists them as kept.
- Clone Tenant’s Run and Resume Run now ask for the same confirmation as the
  toolbar’s Run, with the tenant name and counts.
- While a run is writing, the tenants and the Copy/Delete mode can’t be
  changed.
- Stop lets the object being written finish, so the report says what
  happened to it.
- Fixed: App Installer deployments lost their category and site.
- A Compliance Benchmark Replace that can’t delete or recreate the benchmark
  is reported as failed, and says when the benchmark was already deleted; a
  patch title whose settings couldn’t be written after subscribing says so.
- Onboarding items are matched by name on the destination (Preview blocks the
  setting when one isn’t there); single sign-on that is off on the
  destination stays off.
- Blueprints and Compliance Benchmarks can use device groups the same run
  creates.
- A list Jamf answers without its contents is an error, never an empty tenant.
- Wipe Tenant’s delete button stays off when Run can’t run, and the finished
  count shows only the objects actually deleted.
- Editing a tenant’s server, region or Environment ID clears the plan.
- Clearer, consistent wording throughout (Check All, Clone Tenant, counts with
  the right plural).
- Run now carries out exactly the plan Preview showed: only the checked
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
- Unchecking an object that a checked object needs (for example a script’s
  new category) turns Run off and says which object needs it.
- If creating an object fails during Run, the objects that need it are not
  written with a missing reference; they are reported as not written, and
  Resume Run retries them.
- Delete mode deletes only the objects Preview listed, and stops if one
  changed since Preview.
- Verify marks a type it couldn’t read as “Not checked” instead of
  passing it.
- Fixed: new static computer groups failed to copy (Jamf answered with
  an error); they are now created empty as intended.
- Blueprints and Compliance Benchmarks are left out of Preview while a
  tenant connects directly to Jamf Pro, instead of showing as blocked.
- The run window's help names where run reports are saved, also in demo
  mode.

## 1.0.5 — 2026-10-22
- Fixed: patch management titles were never copied — the type always
  appeared empty, and patch policies were blocked as a result. Titles are
  now listed, created by subscribing the destination to the same title
  from the same patch source, and updated with the source's display name,
  category, site, notifications, packages and accepted extension
  attributes.
- The Permissions page notes the patch source reads a new title needs on
  the destination.

## 1.0.4 — 2026-10-22
- Licensed software is now copied (step 7). The licenses and their
  purchasing details are copied; the list of matching computers comes
  from inventory and is not, and license attachments are left behind with
  a warning in the run report.
- The Permissions page lists the new type, and notes Jamf Pro's separate
  View License Serial Numbers privilege for direct connections.

## 1.0.3 — 2026-10-15
- An update check: at launch, at most once a day, the app asks GitHub
  for the latest release and offers a newer one with its release notes
  and a download. Check on demand from Jamf Migrator › Check for
  Updates…; turn the daily check off in Settings › Updates.

## 1.0.2 — 2026-10-15
- A dry run now shows a clear progress view while it plans (“type 12 of
  51”), and opens on a new Summary page: totals per outcome, every
  planned type with its counts, and a legend for the sidebar badges.
- Clone Tenant: missing permissions and a non-empty destination are
  warnings now and no longer block the wizard (“Continue Anyway”), with a
  button to leave the denied types out. Blueprints and Compliance
  Benchmarks are skipped on direct connections instead of being reported
  as missing permissions.

## 1.0.1 — 2026-10-05
- Fixed: secrets and passwords entered in Settings were not saved in the
  released build, so every tenant failed with “No client secret or
  password is stored”. Secrets now go to the login keychain, and Settings
  shows a warning if the Keychain ever refuses a save.

## 1.0 — 2026-10-04
First release. A complete rewrite of Replicator as a SwiftUI app for
macOS 26: 52 object types over the Jamf Platform API gateway or direct
Jamf Pro connections, a dry-run preview with field-level diffs,
selective migration down to a single object, a resumable journaled
engine, the Clone Tenant and Wipe Tenant guided flows, a verify pass,
and a guided tour.
