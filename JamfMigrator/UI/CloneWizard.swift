//
//  CloneWizard.swift
//  JamfMigrator
//
//  The one-button "Clone tenant" flow: Connect → Checklist & mappings →
//  Preview → Run → Verify. Reuses the planner, engine and journal, so a
//  cancelled run resumes where it stopped.
//

import SwiftUI

struct CloneWizard: View {

    enum Step: Int, CaseIterable {
        case connect, prepare, preview, run, verify

        var title: String {
            switch self {
            case .connect: "Connect"
            case .prepare: "Prepare"
            case .preview: "Preview"
            case .run: "Run"
            case .verify: "Verify"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .connect

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clone \(appState.sourceTenant?.name ?? "?") → \(appState.destTenant?.name ?? "?")")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(appState.isRunning || appState.isBackingUp)
            }
            .padding()

            StepIndicator(current: step)
                .padding(.horizontal)

            Divider().padding(.top, 8)

            Group {
                switch step {
                case .connect: ConnectStep(next: advance)
                case .prepare: PrepareStep(next: advance)
                case .preview: PreviewStep(next: advance)
                case .run: RunStep(next: advance)
                case .verify: VerifyStep(done: { dismiss() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        }
    }
}

private struct StepIndicator: View {
    let current: CloneWizard.Step

    var body: some View {
        HStack {
            ForEach(CloneWizard.Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 4) {
                    Image(systemName: step.rawValue < current.rawValue
                          ? "checkmark.circle.fill"
                          : step == current ? "circle.inset.filled" : "circle")
                    Text(step.title)
                }
                .fixedSize()
                .foregroundStyle(step == current ? .primary : .secondary)
                if step != .verify {
                    Rectangle().fill(.quaternary).frame(height: 1)
                }
            }
        }
        .font(.callout)
    }
}

// MARK: - 1 Connect

private struct ConnectStep: View {
    @Environment(AppState.self) private var appState
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.isPlanning {
                ProgressView("Checking both tenants…")
            } else if let preflight = appState.preflight {
                Label("Source: Jamf Pro \(preflight.source.version ?? preflight.source.error ?? "unreachable")",
                      systemImage: preflight.source.reachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(preflight.source.reachable ? .green : .red)
                Label("Destination: Jamf Pro \(preflight.destination.version ?? preflight.destination.error ?? "unreachable")",
                      systemImage: preflight.destination.reachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(preflight.destination.reachable ? .green : .red)
                if preflight.deniedTypes.isEmpty {
                    Label("Both integrations have permission for every selected type.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Missing permission for: \(preflight.deniedTypes.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if !preflight.destinationIsEmpty {
                    Label("The destination is not empty; matching objects will be updated in place.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Validates both tenants and checks the integrations' permissions.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                if appState.preflight == nil || appState.isPlanning {
                    Button("Check tenants") { runPreflight() }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isPlanning || appState.destTenant == nil || appState.sourceTenant == nil)
                } else {
                    Button("Check again") { runPreflight() }
                    Button("Continue") { next() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!(appState.preflight?.isReady ?? false))
                }
            }
        }
        .padding()
        .onAppear { if appState.preflight == nil { runPreflight() } }
    }

    private func runPreflight() {
        guard let sourceTenant = appState.sourceTenant, let destTenant = appState.destTenant else { return }
        let source = appState.tenantStore.client(for: sourceTenant)
        let dest = appState.tenantStore.client(for: destTenant)
        let typeKeys = appState.selectedTypeKeys
        appState.isPlanning = true
        Task {
            appState.preflight = await Preflight.run(source: source, dest: dest, typeKeys: typeKeys)
            appState.isPlanning = false
        }
    }
}

// MARK: - 2 Prepare: checklist, mappings, secrets

private struct PrepareStep: View {
    @Environment(AppState.self) private var appState
    let next: () -> Void

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section("Done by hand — the API can't copy these") {
                ForEach(PreflightReport.manualChecklist, id: \.self) { item in
                    Label(item, systemImage: "checklist")
                        .font(.callout)
                }
            }

            Section("ADE instances") {
                if appState.isLoadingMappings {
                    ProgressView().controlSize(.small)
                } else if appState.sourceADEInstances.isEmpty {
                    Text("The source has no ADE instances.").foregroundStyle(.secondary)
                } else if appState.destADEInstances.isEmpty {
                    Label("The destination has no ADE instance; PreStages will be Blocked until one exists.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    ForEach(appState.sourceADEInstances, id: \.id) { instance in
                        Picker(instance.name, selection: mappingBinding(\.adeInstances, sourceId: instance.id)) {
                            Text("Not mapped").tag(String?.none)
                            ForEach(appState.destADEInstances, id: \.id) { dest in
                                Text(dest.name).tag(String?.some(dest.id))
                            }
                        }
                    }
                }
            }

            Section("Distribution points") {
                if appState.sourceDistributionPoints.isEmpty {
                    Text("The source has no file-share distribution points.").foregroundStyle(.secondary)
                } else {
                    ForEach(appState.sourceDistributionPoints, id: \.id) { dp in
                        Picker(dp.name, selection: mappingBinding(\.distributionPoints, sourceId: dp.id)) {
                            Text("Not mapped").tag(String?.none)
                            ForEach(appState.destDistributionPoints, id: \.id) { dest in
                                Text(dest.name).tag(String?.some(dest.id))
                            }
                        }
                    }
                }
            }

            Section("Secrets") {
                Text("Passwords the API won't return are written from Settings › Secrets, or as the \"\(placeholderSecret)\" placeholder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SettingsLink {
                    Text("Open Secrets settings…")
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Continue") { next() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .onAppear { appState.loadMappingCandidates() }
    }

    private func mappingBinding(_ keyPath: WritableKeyPath<TenantMappings, [String: String]>,
                                sourceId: String) -> Binding<String?> {
        Binding(
            get: { appState.mappings[keyPath: keyPath][sourceId] },
            set: { appState.mappings[keyPath: keyPath][sourceId] = $0 })
    }
}

// MARK: - 3 Preview

private struct PreviewStep: View {
    @Environment(AppState.self) private var appState
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.isPlanning {
                ProgressView("Planning… \(appState.planningStatus)")
            } else if let plan = appState.plan {
                let counts = plan.counts
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow { Text("Create").fontWeight(.semibold); Text("\(counts.create)") }
                    GridRow { Text("Update").fontWeight(.semibold); Text("\(counts.update)") }
                    GridRow { Text("Unchanged").fontWeight(.semibold); Text("\(counts.unchanged)") }
                    GridRow { Text("Blocked").fontWeight(.semibold); Text("\(counts.blocked)") }
                }
                Text("Close the wizard to review every object and its diff in the main window; the plan stays loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("The dry run reads both tenants and changes nothing.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                if appState.plan == nil || appState.isPlanning {
                    Button("Preview") { appState.preview() }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isPlanning)
                } else {
                    Button("Preview again") { appState.preview() }
                    Button("Continue") { next() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!appState.canRun && appState.plan?.changeCount != 0)
                }
            }
        }
        .padding()
    }
}

// MARK: - 4 Run

private struct RunStep: View {
    @Environment(AppState.self) private var appState
    let next: () -> Void
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.isRunning {
                if let latest = appState.runEvents.last {
                    let typeName = ObjectRegistry.type(latest.type)?.displayName ?? latest.type
                    ProgressView(value: Double(latest.completed), total: Double(max(latest.total, 1))) {
                        Text("\(typeName): \(latest.objectName)").lineLimit(1)
                    }
                } else {
                    ProgressView("Starting…")
                }
                Text("\(appState.runEvents.count) objects processed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let report = appState.report {
                let failures = report.failures
                Label(failures.isEmpty
                      ? "Run finished: \(report.entries.count) objects processed."
                      : "Run finished with \(failures.count) objects not migrated. Running again resumes and retries them.",
                      systemImage: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(failures.isEmpty ? .green : .orange)
            } else if appState.plan?.changeCount == 0 {
                Label("Nothing to do — every object is already on the destination.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Copies \(appState.plan?.changeCount ?? 0) changes to \(appState.destTenant?.name ?? "the destination"), in step order. The run can be stopped and resumed.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                if appState.isRunning {
                    Button("Stop", role: .destructive) { appState.cancel() }
                } else if started || appState.plan?.changeCount == 0 {
                    if appState.report?.failures.isEmpty == false {
                        Button("Run again (resume)") { appState.run() }
                    }
                    Button("Continue to Verify") { next() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Run") {
                        started = true
                        appState.run()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.canRun)
                }
            }
        }
        .padding()
    }
}

// MARK: - 5 Verify

private struct VerifyStep: View {
    @Environment(AppState.self) private var appState
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.isVerifying {
                ProgressView("Verifying… \(appState.planningStatus)")
            } else if let report = appState.verifyReport {
                Label(report.isClean
                      ? "Verified: a second run would write nothing."
                      : "\(report.discrepancyCount) objects differ or are missing.",
                      systemImage: report.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.isClean ? .green : .orange)
                    .font(.headline)
                List(report.types, id: \.typeKey) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(ObjectRegistry.type(result.typeKey)?.displayName ?? result.typeKey)
                            Spacer()
                            Text("\(result.sourceCount) source / \(result.destCount) destination")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ForEach(result.discrepancies, id: \.self) { item in
                            Label(item, systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        ForEach(result.blocked, id: \.self) { item in
                            Label(item, systemImage: "hand.raised")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Export report…") { exportReport(report) }
            } else {
                Text("Plans again and checks that every object is now Unchanged.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                if appState.verifyReport == nil {
                    Button("Verify") { appState.verify() }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isVerifying)
                } else {
                    Button("Done") { done() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }

    private func exportReport(_ report: VerifyReport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clone-verify-\(appState.destTenant?.name ?? "report").txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["Clone verification — \(Date().formatted())", ""]
        for result in report.types {
            lines.append("\(result.typeKey): \(result.sourceCount) source / \(result.destCount) destination")
            lines.append(contentsOf: result.discrepancies.map { "  DIFFERS \($0)" })
            lines.append(contentsOf: result.blocked.map { "  BLOCKED \($0)" })
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
