//
//  GuidedTour.swift
//  JamfMigrator
//
//  An interactive walkthrough of the migration workflow: a dimmed overlay
//  with a spotlight on the relevant part of the window and a callout card
//  per step. It needs no tenants configured, starts automatically on first
//  launch, and can be replayed from Help › Guided Tour.
//

import SwiftUI

// MARK: - Anchors

/// Parts of the window the tour can spotlight.
enum TourAnchorID: Hashable {
    case tenants
    case objectTypes
    case plan
    case inspector
}

/// Collects every anchor per target: a modifier on a List `Section` lands on
/// each of its rows, so the spotlight unions all of them into one rectangle.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourAnchorID: [Anchor<CGRect>]] = [:]
    static func reduce(value: inout [TourAnchorID: [Anchor<CGRect>]],
                       nextValue: () -> [TourAnchorID: [Anchor<CGRect>]]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

extension View {
    /// Marks a view as a tour spotlight target.
    func tourAnchor(_ id: TourAnchorID) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: [$0]] }
    }
}

// MARK: - Steps

struct TourStep {
    let title: String
    let text: String
    /// The spotlighted part of the window; nil centers the card.
    var anchor: TourAnchorID?
    /// Where the card goes when the target is in the toolbar, which the
    /// spotlight cannot reach.
    var pointsAtToolbar = false

    static let all: [TourStep] = [
        TourStep(title: "Welcome to Jamf Migrator",
                 text: "This app copies a source Jamf tenant to a destination tenant — everything, or any selection down to a single object. This tour walks through the workflow; nothing is read or written while it runs."),
        TourStep(title: "1 · Tenants",
                 text: "Pick the source and destination tenants here. Tenants are added in Settings › Tenants, either through the Jamf Platform API gateway or as a direct Jamf Pro connection. Mark the source tenant Protected so it can never be wiped.",
                 anchor: .tenants),
        TourStep(title: "2 · Object types",
                 text: "Choose what to copy. The steps mirror dependency order — sites before groups, groups before policies. Use Check all / Uncheck all for quick selections; a bolt icon marks types that need the Platform API gateway.",
                 anchor: .objectTypes),
        TourStep(title: "3 · Preview",
                 text: "Preview (⇧⌘P) in the toolbar runs a dry run: both tenants are read, nothing is written. Every object is matched by name and labeled Create, Update, Replace, Unchanged, or Blocked — with the reason.",
                 pointsAtToolbar: true),
        TourStep(title: "4 · The plan",
                 text: "The preview's result lands here: every object with its outcome and a checkbox. To copy a single script: uncheck all types, check Scripts, then uncheck every script except the one you want.",
                 anchor: .plan),
        TourStep(title: "5 · The inspector",
                 text: "Select an object to see why it changed: a field-level diff against the destination, plus warnings about anything that needs attention — secrets the API never returns, references that don't exist yet.",
                 anchor: .inspector),
        TourStep(title: "6 · Run",
                 text: "Run (⌘R) confirms the counts, then writes in dependency order. Every run is journaled: stop it or lose the connection and the next run resumes where it left off, skipping everything already done.",
                 pointsAtToolbar: true),
        TourStep(title: "7 · Clone tenant",
                 text: "The Clone tenant button runs the whole flow guided: connect and probe permissions, work through the manual checklist, map ADE instances and distribution points, preview, run — and Verify, which plans again to prove a second run would write nothing.",
                 pointsAtToolbar: true),
        TourStep(title: "8 · Delete mode",
                 text: "⌘D switches to delete mode for the session: a red banner, a red Run, and a confirmation for every run. The Wipe tenant button deletes every selected type from a tenant — behind gates: a preview, a verified backup, and the tenant's name typed out.",
                 pointsAtToolbar: true),
        TourStep(title: "That's the tour",
                 text: "Start by adding your tenants in Settings › Tenants, then Preview. Logs and exports live in the app's Application Support folder. Replay this tour any time from Help › Guided Tour."),
    ]
}

// MARK: - Overlay

/// The dimmed overlay with the spotlight cutout and the callout card.
/// Attach with `.guidedTour()` on the window's root view.
struct GuidedTourOverlay: View {

    @Environment(AppState.self) private var appState
    let anchors: [TourAnchorID: [Anchor<CGRect>]]

    var body: some View {
        if let index = appState.tourIndex, TourStep.all.indices.contains(index) {
            let step = TourStep.all[index]
            GeometryReader { proxy in
                let target = step.anchor
                    .flatMap { anchors[$0] }
                    .flatMap { list -> CGRect? in
                        // a List section can emit a zero-sized placeholder at
                        // the origin; it must not poison the union
                        let rects = list.map { proxy[$0] }.filter { $0.width > 1 && $0.height > 1 }
                        guard let first = rects.first else { return nil }
                        return rects.dropFirst().reduce(first) { $0.union($1) }
                    }
                    .map { $0.insetBy(dx: -4, dy: -4) }

                ZStack {
                    spotlight(in: proxy, cutout: target)
                    card(for: step, index: index)
                        .frame(maxWidth: 400)
                        .position(cardPosition(for: step, target: target, in: proxy.size))
                }
            }
            .transition(.opacity)
        }
    }

    /// The dim layer; a rounded cutout is left clear over the target. The
    /// rect extends into the safe areas by hand — `ignoresSafeArea` would
    /// shift the whole path's coordinate space up by the title-bar inset.
    private func spotlight(in proxy: GeometryProxy, cutout: CGRect?) -> some View {
        let insets = proxy.safeAreaInsets
        var path = Path(CGRect(x: -insets.leading,
                               y: -insets.top,
                               width: proxy.size.width + insets.leading + insets.trailing,
                               height: proxy.size.height + insets.top + insets.bottom))
        if let cutout {
            path.addRoundedRect(in: cutout, cornerSize: CGSize(width: 8, height: 8))
        }
        return path
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
    }

    private func card(for step: TourStep, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if step.pointsAtToolbar {
                    Image(systemName: "arrow.up")
                }
                Text(step.title)
                    .font(.headline)
                Spacer()
                Text("\(index + 1) / \(TourStep.all.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(step.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Skip tour") { appState.endTour() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if index > 0 {
                    Button("Back") { appState.tourIndex = index - 1 }
                }
                if index + 1 < TourStep.all.count {
                    Button("Next") { appState.tourIndex = index + 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { appState.endTour() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(radius: 12)
    }

    /// The card sits next to its target, clamped to the window; toolbar
    /// steps pin it top-trailing, anchorless steps center it.
    private func cardPosition(for step: TourStep, target: CGRect?, in size: CGSize) -> CGPoint {
        let cardSize = CGSize(width: 400, height: 190)
        var point: CGPoint
        if let target {
            // beside the target when it hugs a window edge, otherwise below
            if target.maxX + cardSize.width + 24 < size.width {
                point = CGPoint(x: target.maxX + 24 + cardSize.width / 2, y: target.midY)
            } else if target.minX - cardSize.width - 24 > 0 {
                point = CGPoint(x: target.minX - 24 - cardSize.width / 2, y: target.midY)
            } else {
                point = CGPoint(x: target.midX, y: target.maxY + 24 + cardSize.height / 2)
            }
        } else if step.pointsAtToolbar {
            point = CGPoint(x: size.width - cardSize.width / 2 - 24, y: cardSize.height / 2 + 24)
        } else {
            point = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        point.x = min(max(point.x, cardSize.width / 2 + 12), size.width - cardSize.width / 2 - 12)
        point.y = min(max(point.y, cardSize.height / 2 + 12), size.height - cardSize.height / 2 - 12)
        return point
    }
}

extension View {
    /// Shows the guided tour over this view whenever `AppState.tourIndex`
    /// is set, and starts it automatically on first launch.
    func guidedTour(appState: AppState) -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GuidedTourOverlay(anchors: anchors)
                .animation(.easeInOut(duration: 0.2), value: appState.tourIndex)
        }
        .task {
            appState.startTourOnFirstLaunch()
        }
    }
}
