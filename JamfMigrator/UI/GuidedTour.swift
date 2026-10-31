//
//  GuidedTour.swift
//  JamfMigrator
//
//  The steps of the interactive walkthrough of the migration workflow. The
//  overlay itself (dim layer, spotlight, callout card) comes from JTKit. It
//  needs no tenants configured, starts automatically on first launch, and
//  can be replayed from Help › Guided Tour.
//

import JTKit

/// Parts of the window the tour can spotlight.
enum TourAnchorID: Hashable, Sendable {
    case tenants
    case objectTypes
    case plan
    case inspector
}

extension TourStep where AnchorID == TourAnchorID {

    static let all: [TourStep] = [
        TourStep(title: "Welcome to Jamf Migrator",
                 text: "This app copies a source Jamf tenant to a destination tenant — everything, or any selection down to a single object. This tour walks through the workflow; nothing is read or written while it runs."),
        TourStep(title: "1 · Tenants",
                 text: "Pick the source and destination tenants here. Tenants are added in Settings › Connections, either through the Jamf Platform API gateway or as a direct Jamf Pro connection. Mark the source tenant Protected so it can never be wiped.",
                 anchorID: .tenants),
        TourStep(title: "2 · Object Types",
                 text: "Choose what to copy. The steps mirror dependency order — sites before groups, groups before policies. Use Check All / Uncheck All for quick selections; a bolt icon marks types that need the Jamf Platform API gateway.",
                 anchorID: .objectTypes),
        TourStep(title: "3 · Preview",
                 text: "Preview (⇧⌘P) in the toolbar runs a dry run: both tenants are read, nothing is written. Every object is matched by name and labeled Create, Update, Replace, Unchanged, or Blocked — with the reason.",
                 pointsAtToolbar: true),
        TourStep(title: "4 · The Plan",
                 text: "The preview’s result lands here: every object with its outcome and a checkbox. To copy a single script: uncheck all types, check Scripts, then uncheck every script except the one you want.",
                 anchorID: .plan),
        TourStep(title: "5 · The Inspector",
                 text: "Select an object to see why it changed: a field-level diff against the destination, plus warnings about anything that needs attention — secrets the API never returns, references that don’t exist yet.",
                 anchorID: .inspector),
        TourStep(title: "6 · Run",
                 text: "Run (⌘R) confirms the counts, then carries out exactly what Preview showed, in dependency order. If anything changed since Preview, it stops before writing that object. Stop a run or lose the connection, and Resume Run carries on where it left off.",
                 pointsAtToolbar: true),
        TourStep(title: "7 · Clone Tenant",
                 text: "The Clone Tenant button runs the whole flow guided: connect and probe permissions, work through the manual checklist, map ADE instances and distribution points, preview, run — and Verify, which plans again to prove a second run would write nothing.",
                 pointsAtToolbar: true),
        TourStep(title: "8 · Delete Mode",
                 text: "⌘D switches to delete mode for the session: a red banner, a red Run, and a confirmation for every run. The Wipe Tenant button deletes every selected type from a tenant — behind gates: a preview, a verified backup, and the tenant’s name typed out. It never removes the account you sign in with or an administrator account.",
                 pointsAtToolbar: true),
        TourStep(title: "That’s the tour",
                 text: "Start by adding your tenants in Settings › Connections, then Preview. Run reports, backups and exports live in the app’s Application Support folder; the activity log is under Window › Activity Log. Replay this tour any time from Help › Guided Tour."),
    ]
}
