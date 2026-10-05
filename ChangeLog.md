# Change log

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
