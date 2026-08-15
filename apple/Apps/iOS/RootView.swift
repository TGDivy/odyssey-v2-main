import OdysseyApplication
import OdysseyIntelligence
import SwiftUI
import UIKit

private enum PrimarySpace: Hashable {
    case now
    case map
    case archive
    case workshop
}

struct RootView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @State private var selection: PrimarySpace = .now
    @State private var isCapturePresented = false

    var body: some View {
        Group {
            switch model.state.localReadiness {
            case .launching:
                ProgressView("Opening your local ledger…")
            case let .unavailable(message):
                ContentUnavailableView {
                    Label("Local data unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await model.bootstrap() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .ready:
                tabs
            }
        }
        .sheet(isPresented: $isCapturePresented) {
            CaptureSheet()
                .environmentObject(model)
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            NavigationStack {
                NowView(openCapture: presentCapture)
            }
            .tabItem { Label("Now", systemImage: "location.fill") }
            .tag(PrimarySpace.now)

            NavigationStack {
                PlaceholderSpace(
                    title: "Map",
                    symbol: "map",
                    description: "The current season map will remain calm and locally available."
                )
            }
            .tabItem { Label("Map", systemImage: "map") }
            .tag(PrimarySpace.map)

            NavigationStack {
                ArchiveView()
            }
            .tabItem { Label("Archive", systemImage: "books.vertical") }
            .tag(PrimarySpace.archive)

            NavigationStack {
                WorkshopView()
            }
            .tabItem { Label("Workshop", systemImage: "slider.horizontal.3") }
            .tag(PrimarySpace.workshop)
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: presentCapture) {
                Image(systemName: "square.and.pencil")
                    .font(.title2)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Capture")
            .accessibilityHint("Saves a note to the local ledger before any network request")
            .padding(.trailing, 20)
            .padding(.bottom, 72)
        }
    }

    private func presentCapture() {
        model.dismissCaptureStatus()
        isCapturePresented = true
    }
}

private struct ArchiveView: View {
    @EnvironmentObject private var model: OdysseyAppModel

    var body: some View {
        Group {
            if model.state.recentCaptures.isEmpty {
                ContentUnavailableView(
                    "No captures yet",
                    systemImage: "books.vertical",
                    description: Text("New captures appear here from the local ledger.")
                )
            } else {
                List(model.state.recentCaptures, id: \.metadata.id) { capture in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(captureTitle(capture))
                            .lineLimit(3)
                        Text(capture.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Archive")
    }

    private func captureTitle(_ capture: CaptureRecord) -> String {
        switch capture.originalPayload.kind {
        case .text:
            String(capture.originalPayload.contentOrObjectRef.prefix(500))
        case .audio:
            "Audio capture"
        case .imageReference:
            "Image capture"
        case .fileReference:
            "File capture"
        case .structuredQuickAction:
            "Quick capture"
        }
    }
}

private struct NowView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    let openCapture: () -> Void

    private let context = DeterministicContextProjector().project(
        DeterministicContextInput(
            unresolvedDecisionCount: 0,
            preparationDeadlineCount: 0,
            materialHealthConstraintCount: 0,
            disruptionCount: 0,
            explicitlyOpen: false
        )
    )

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ContentUnavailableView {
                    Label("Nothing requires attention", systemImage: "water.waves")
                } description: {
                    Text("Odyssey is intentionally quiet. Your current state is \(context.rawValue).")
                } actions: {
                    Button("Capture", action: openCapture)
                        .buttonStyle(.borderedProminent)
                }

                if let diagnostics = model.state.diagnostics,
                   diagnostics.operationsQueued > 0
                {
                    Label(
                        "\(diagnostics.operationsQueued) local change\(diagnostics.operationsQueued == 1 ? "" : "s") safely queued",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "\(diagnostics.operationsQueued) changes safely queued for sync"
                    )
                }

                if case let .saved(_, capturedAt) = model.state.capturePhase {
                    Label(
                        "Saved locally \(capturedAt.formatted(date: .omitted, time: .shortened))",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .navigationTitle("Now")
    }
}

private struct CaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: OdysseyAppModel
    @FocusState private var isFocused: Bool
    @State private var text = ""

    private var isSaving: Bool {
        model.state.capturePhase == .saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .focused($isFocused)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Capture text")
                } header: {
                    Text("What should Odyssey remember?")
                } footer: {
                    Text("Save commits the original text locally before sync or interpretation.")
                }

                if case let .failed(message) = model.state.capturePhase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task {
                            if await model.captureText(text) {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .onAppear { isFocused = true }
        }
    }
}

private struct WorkshopView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @State private var confirmsProjectionRebuild = false

    var body: some View {
        Form {
            Section("Device Enrollment") {
                enrollmentStatus
                remoteStatus

                if canOfferEnrollment {
                    Button {
                        Task { await model.enrollWithApple() }
                    } label: {
                        Label("Enroll this device with Apple", systemImage: "apple.logo")
                    }
                    .disabled(model.state.enrollmentPhase == .authorizing)
                }

                if model.state.enrollmentPhase == .credentialStored {
                    Button("Remove local sync credential", role: .destructive) {
                        Task { await model.removeLocalEnrollment() }
                    }
                    Text("This removes only the local credential; use the owner device registry to revoke a device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Synchronization") {
                syncStatus
                if let diagnostics = model.state.diagnostics {
                    LabeledContent("Queued", value: String(diagnostics.operationsQueued))
                    LabeledContent("Conflicts", value: String(diagnostics.conflictCount))
                    LabeledContent("Device cursor", value: diagnostics.deviceCursor.description)
                    LabeledContent("Server cursor", value: diagnostics.serverCursor.description)
                    LabeledContent(
                        "Schema",
                        value: diagnostics.schemaCompatibility.rawValue.replacingOccurrences(
                            of: "_",
                            with: " "
                        )
                    )
                    if let oldest = diagnostics.oldestUnsyncedOperationAt {
                        LabeledContent(
                            "Oldest queued",
                            value: oldest.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    if let pushed = diagnostics.lastSuccessfulPushAt {
                        LabeledContent(
                            "Last push",
                            value: pushed.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    if let pulled = diagnostics.lastSuccessfulPullAt {
                        LabeledContent(
                            "Last pull",
                            value: pulled.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }

                Button {
                    Task { await model.synchronize() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!model.state.canSynchronize)
            }

            Section("Local Repair") {
                maintenanceStatus
                Button("Verify local integrity") {
                    Task { await model.verifyLocalData() }
                }
                .disabled(model.state.maintenancePhase == .running)

                Button("Rebuild projections from ledger") {
                    confirmsProjectionRebuild = true
                }
                .disabled(model.state.maintenancePhase == .running)
            }
        }
        .navigationTitle("Workshop")
        .confirmationDialog(
            "Rebuild local projections?",
            isPresented: $confirmsProjectionRebuild,
            titleVisibility: .visible
        ) {
            Button("Rebuild") {
                Task { await model.rebuildLocalProjections() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The immutable ledger remains unchanged. Derived local projections are recreated transactionally.")
        }
    }

    @ViewBuilder
    private var enrollmentStatus: some View {
        switch model.state.enrollmentPhase {
        case .checking:
            Label("Checking local credential", systemImage: "key.horizontal")
        case .notEnrolled:
            Label("No local sync credential", systemImage: "key.slash")
        case .credentialStored:
            Label("Device credential stored in Keychain", systemImage: "checkmark.shield")
        case .authorizing:
            HStack {
                ProgressView()
                Text("Waiting for Apple authorization")
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var remoteStatus: some View {
        switch model.state.remoteReadiness {
        case .checking:
            Label("Checking remote configuration", systemImage: "network")
        case .available:
            Label("Remote services configured", systemImage: "network")
        case let .unavailable(message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Remote services unavailable", systemImage: "network.slash")
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch model.state.syncPhase {
        case .idle:
            EmptyView()
        case .synchronizing:
            HStack {
                ProgressView()
                Text("Synchronizing")
            }
        case let .succeeded(report):
            Label(
                "Pushed \(report.pushedOperationCount), pulled \(report.pulledChangeCount)",
                systemImage: "checkmark.circle"
            )
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var maintenanceStatus: some View {
        switch model.state.maintenancePhase {
        case .idle:
            EmptyView()
        case .running:
            HStack {
                ProgressView()
                Text("Working from the local ledger")
            }
        case let .succeeded(message):
            Label(message, systemImage: "checkmark.circle")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var canOfferEnrollment: Bool {
        guard model.state.remoteReadiness == .available else { return false }
        switch model.state.enrollmentPhase {
        case .credentialStored:
            false
        default:
            true
        }
    }
}

private struct PlaceholderSpace: View {
    let title: String
    let symbol: String
    let description: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: symbol,
            description: Text(description)
        )
        .navigationTitle(title)
    }
}
