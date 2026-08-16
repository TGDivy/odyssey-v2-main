import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import SwiftUI

private enum WorkshopEditorRoute: Identifiable {
    case charter(CharterDraftEditor)
    case lifeStage(LifeStageDraftEditor)
    case season(SeasonDraftEditor)

    var id: String {
        switch self {
        case let .charter(editor):
            "charter-\(editor.draftID)"
        case let .lifeStage(editor):
            "life-stage-\(editor.draftID)"
        case let .season(editor):
            "season-\(editor.draftID)"
        }
    }
}

struct WorkshopView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @State private var editorRoute: WorkshopEditorRoute?
    @State private var localFailure: String?
    @State private var confirmsProjectionRebuild = false
    @State private var draftToAbandon: LifeModelDraftRecord?

    var body: some View {
        Form {
            workshopStateSection
            lifeModelSection(.charter)
            lifeModelSection(.lifeStage)
            lifeModelSection(.season)
            acceptanceQueueSection
            acceptedHistorySection
            enrollmentSection
            synchronizationSection
            repairSection
        }
        .navigationTitle("Workshop")
        .refreshable { await model.refreshWorkshop() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refreshWorkshop() }
                } label: {
                    Label("Refresh Workshop", systemImage: "arrow.clockwise")
                }
                .disabled(!model.state.canUseWorkshop)
            }
        }
        .sheet(item: $editorRoute) { route in
            editorSheet(route)
                .environmentObject(model)
        }
        .sheet(
            isPresented: Binding(
                get: { model.state.workshopReview != nil },
                set: { presented in
                    if !presented {
                        model.dismissWorkshopReview()
                    }
                }
            )
        ) {
            if let review = model.state.workshopReview {
                WorkshopReviewView(review: review)
                    .environmentObject(model)
            }
        }
        .confirmationDialog(
            "Abandon this unaccepted draft?",
            isPresented: Binding(
                get: { draftToAbandon != nil },
                set: { presented in
                    if !presented {
                        draftToAbandon = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Abandon Draft", role: .destructive) {
                guard let draft = draftToAbandon else { return }
                draftToAbandon = nil
                Task { await model.abandonWorkshopDraft(draft) }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The draft history remains in the immutable local ledger. It will never be accepted or synced.")
        }
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
            Text(
                "The immutable ledger remains unchanged. Derived local projections are "
                    + "recreated transactionally."
            )
        }
    }

    private var workshopStateSection: some View {
        Section {
            workshopStatus
            if let localFailure {
                Label(localFailure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Text(
                "Charter, life-stage, and season drafts remain local until you review the "
                    + "plain-language change and explicitly accept that exact version."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Reviewed Life Model")
        }
    }

    @ViewBuilder
    private func lifeModelSection(_ kind: LifeModelKind) -> some View {
        Section(kind.sectionTitle) {
            if let draft = openDraft(kind) {
                draftCard(draft)
            } else if let pending = pendingAcceptance(kind) {
                pendingSummary(pending)
            } else if let accepted = currentAcceptedVersion(kind) {
                acceptedSummary(accepted)
                revisionButton(for: accepted)
            } else {
                Text(kind.emptyExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.createInitialWorkshopDraft(kind) }
                } label: {
                    Label(kind.createLabel, systemImage: "plus.circle")
                }
                .disabled(!model.state.canUseWorkshop || !canCreateInitial(kind))
            }
        }
    }

    @ViewBuilder
    private func draftCard(_ draft: LifeModelDraftRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(draftTitle(draft), systemImage: draft.kind.symbolName)
                .font(.headline)
            Text("Version \(draft.versionNumber) · \(draft.phase.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if draft.phase == .reviewed {
                Text("This exact content was reviewed. Editing it will require a new review.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)

        if draft.phase == .editing || draft.phase == .reviewed {
            Button {
                openEditor(draft)
            } label: {
                Label("Edit \(draft.kind.displayName)", systemImage: "pencil")
            }
            .disabled(!model.state.canUseWorkshop)

            Button {
                Task { await model.prepareWorkshopReview(for: draft) }
            } label: {
                Label("Review Complete Change", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(!model.state.canUseWorkshop)

            Button("Abandon Unaccepted Draft", role: .destructive) {
                draftToAbandon = draft
            }
            .disabled(!model.state.canUseWorkshop)
        }
    }

    private func pendingSummary(_ acceptance: StoredLifeModelAcceptance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Version \(acceptance.command.versionNumber) is \(acceptance.deliveryStatus.displayName)",
                systemImage: acceptance.deliveryStatus.symbolName
            )
            .font(.headline)
            Text(acceptance.deliveryStatus.ownerExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func acceptedSummary(_ version: CachedLifeModelVersion) -> some View {
        NavigationLink {
            AcceptedLifeModelVersionView(version: version)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(acceptedTitle(version), systemImage: "checkmark.seal")
                    .font(.headline)
                Text(
                    "Accepted version \(version.versionNumber) · "
                        + version.acceptedAt.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func revisionButton(for version: CachedLifeModelVersion) -> some View {
        if version.kind == .season, version.status == SeasonStatus.complete.rawValue
            || version.status == SeasonStatus.abandoned.rawValue
        {
            Button {
                Task { await model.createSuccessorSeason(after: version) }
            } label: {
                Label("Start Successor Season", systemImage: "arrow.forward.circle")
            }
            .disabled(!model.state.canUseWorkshop)
        } else {
            Button {
                Task { await model.createWorkshopRevision(of: version) }
            } label: {
                Label("Create Reviewed Revision", systemImage: "square.and.pencil")
            }
            .disabled(!model.state.canUseWorkshop)
        }
    }

    @ViewBuilder
    private var acceptanceQueueSection: some View {
        if let snapshot = model.state.workshopSnapshot,
           !snapshot.acceptanceCommands.isEmpty
        {
            Section("Acceptance Queue") {
                LabeledContent("Waiting", value: String(snapshot.queueDiagnostics.queuedCount))
                LabeledContent("Conflicts", value: String(snapshot.queueDiagnostics.conflictCount))
                LabeledContent("Rejected", value: String(snapshot.queueDiagnostics.rejectedCount))

                ForEach(snapshot.acceptanceCommands, id: \.command.eventID) { acceptance in
                    AcceptanceCommandRow(acceptance: acceptance)
                }

                if snapshot.queueDiagnostics.queuedCount > 0
                    || snapshot.queueDiagnostics.conflictCount > 0
                {
                    Button {
                        Task { await model.synchronize() }
                    } label: {
                        Label("Deliver and Refresh History", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!model.state.canSynchronize || !model.state.canUseWorkshop)
                }
            }
        }
    }

    @ViewBuilder
    private var acceptedHistorySection: some View {
        if let versions = model.state.workshopSnapshot?.acceptedVersions,
           !versions.isEmpty
        {
            Section("Immutable Accepted History") {
                ForEach(versions, id: \.versionID) { version in
                    NavigationLink {
                        AcceptedLifeModelVersionView(version: version)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(acceptedTitle(version))
                            Text(
                                "Version \(version.versionNumber) · "
                                    + version.acceptedAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var enrollmentSection: some View {
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
                Text(
                    "This removes only the local credential; use the owner device registry "
                        + "to revoke a device."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var synchronizationSection: some View {
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
    }

    private var repairSection: some View {
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

    @ViewBuilder
    private func editorSheet(_ route: WorkshopEditorRoute) -> some View {
        switch route {
        case let .charter(editor):
            CharterDraftEditorView(editor: editor)
        case let .lifeStage(editor):
            LifeStageDraftEditorView(editor: editor)
        case let .season(editor):
            SeasonDraftEditorView(editor: editor)
        }
    }

    private func openEditor(_ draft: LifeModelDraftRecord) {
        do {
            switch draft.kind {
            case .charter:
                editorRoute = .charter(try CharterDraftEditor(draft: draft))
            case .lifeStage:
                editorRoute = .lifeStage(try LifeStageDraftEditor(draft: draft))
            case .season:
                editorRoute = .season(try SeasonDraftEditor(draft: draft))
            }
            localFailure = nil
        } catch {
            localFailure = "This typed draft could not be opened safely."
        }
    }

    private func openDraft(_ kind: LifeModelKind) -> LifeModelDraftRecord? {
        model.state.workshopSnapshot?.drafts.first {
            $0.kind == kind && ($0.phase == .editing || $0.phase == .reviewed)
        }
    }

    private func pendingAcceptance(
        _ kind: LifeModelKind
    ) -> StoredLifeModelAcceptance? {
        model.state.workshopSnapshot?.acceptanceCommands.first {
            $0.command.kind == kind
                && ($0.deliveryStatus == .pending || $0.deliveryStatus == .retry)
        }
    }

    private func currentAcceptedVersion(
        _ kind: LifeModelKind
    ) -> CachedLifeModelVersion? {
        model.state.workshopSnapshot?.acceptedVersions.first { $0.kind == kind }
    }

    private func canCreateInitial(_ kind: LifeModelKind) -> Bool {
        kind != .season
            || currentAcceptedVersion(.charter) != nil
            || pendingAcceptance(.charter) != nil
    }

    private func draftTitle(_ draft: LifeModelDraftRecord) -> String {
        switch draft.kind {
        case .charter:
            "Editable Charter"
        case .lifeStage:
            (try? decodeDocument(LifeStageVersion.self, from: draft.document).title)
                ?? "Editable Life Stage"
        case .season:
            (try? decodeDocument(Season.self, from: draft.document).title)
                ?? "Editable Season"
        }
    }

    private func acceptedTitle(_ version: CachedLifeModelVersion) -> String {
        switch version.kind {
        case .charter:
            "Charter"
        case .lifeStage:
            (try? SyncJSONCoding.makeDecoder().decode(
                LifeStageVersion.self,
                from: version.document
            ).title) ?? "Life Stage"
        case .season:
            (try? SyncJSONCoding.makeDecoder().decode(
                Season.self,
                from: version.document
            ).title) ?? "Season"
        }
    }

    @ViewBuilder
    private var workshopStatus: some View {
        switch model.state.workshopPhase {
        case .idle:
            Label("Workshop is waiting for local storage", systemImage: "tray")
        case .loading:
            activityLabel("Loading immutable local history")
        case .ready:
            EmptyView()
        case .saving:
            activityLabel("Saving to the local ledger")
        case .reviewing:
            activityLabel("Preparing the semantic review")
        case .queueing:
            activityLabel("Queueing the exact reviewed version")
        case .delivering:
            activityLabel("Delivering and refreshing accepted history")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func activityLabel(_ title: String) -> some View {
        HStack {
            ProgressView()
            Text(title)
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
            activityLabel("Waiting for Apple authorization")
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
            activityLabel("Synchronizing")
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
            activityLabel("Working from the local ledger")
        case let .succeeded(message):
            Label(message, systemImage: "checkmark.circle")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var canOfferEnrollment: Bool {
        guard model.state.remoteReadiness == .available else { return false }
        return model.state.enrollmentPhase != .credentialStored
    }
}

private struct AcceptanceCommandRow: View {
    let acceptance: StoredLifeModelAcceptance

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                "\(acceptance.command.kind.displayName) version "
                    + "\(acceptance.command.versionNumber)",
                systemImage: acceptance.deliveryStatus.symbolName
            )
            .font(.subheadline.weight(.semibold))
            Text(acceptance.deliveryStatus.displayName)
                .font(.caption)
                .foregroundStyle(acceptance.deliveryStatus.tint)
            Text(acceptance.deliveryStatus.ownerExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if acceptance.deliveryStatus == .conflict {
                Text(
                    "No merge was applied. Refresh accepted history, inspect its meaning, "
                        + "and create a new reviewed revision."
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WorkshopReviewView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsImmutableAcceptance = false

    let review: LifeModelDraftReview

    var body: some View {
        NavigationStack {
            List {
                Section("Exact Version") {
                    LabeledContent("Kind", value: review.draft.kind.displayName)
                    LabeledContent("Version", value: String(review.draft.versionNumber))
                    Text(
                        "Acceptance appends this exact reviewed document to immutable history. "
                            + "Future changes require a new version; they never rewrite this one."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if !review.warnings.isEmpty {
                    Section("Attention Cost") {
                        ForEach(Array(review.warnings.enumerated()), id: \.offset) { entry in
                            Label(entry.element, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Plain-Language Change") {
                    if review.changes.isEmpty {
                        Text("This is the first accepted version of this life-model layer.")
                    } else {
                        ForEach(review.changes, id: \.path) { change in
                            SemanticChangeRow(change: change)
                        }
                    }
                }

                Section("Explicit Confirmation") {
                    Toggle(
                        "I reviewed this complete version and understand acceptance is immutable",
                        isOn: $confirmsImmutableAcceptance
                    )
                    Button {
                        Task {
                            await model.queueWorkshopAcceptance(review)
                            if model.state.workshopReview == nil {
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Accept Exact Reviewed Version", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !confirmsImmutableAcceptance
                            || model.state.workshopPhase.isBusy
                    )
                    Text(
                        "Without enrollment, the signed-in owner command remains durably queued "
                            + "on this device until remote delivery is available."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Review Before Acceptance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct SemanticChangeRow: View {
    let change: LifeModelSemanticChange

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(change.label)
                .font(.subheadline.weight(.semibold))
            if let before = change.before {
                LabeledContent("Before", value: before)
                    .font(.footnote)
            }
            if let after = change.after {
                LabeledContent("After", value: after)
                    .font(.footnote)
            }
            Text(change.kind.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CharterDraftEditorView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: CharterDraftEditor
    @State private var localFailure: String?

    init(editor: CharterDraftEditor) {
        _editor = State(initialValue: editor)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let localFailure {
                    Section {
                        Label(localFailure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section("Chosen Values") {
                    ForEach($editor.values) { $value in
                        DisclosureGroup(value.title.isEmpty ? "New value" : value.title) {
                            TextField("Value name", text: $value.title)
                            TextField(
                                "What this value means",
                                text: $value.description,
                                axis: .vertical
                            )
                            TextField(
                                "How it looks when lived",
                                text: $value.positiveExpression,
                                axis: .vertical
                            )
                            TextField(
                                "Anti-value or failure mode (optional)",
                                text: $value.antiValueOrFailureMode,
                                axis: .vertical
                            )
                        }
                    }
                    .onDelete { editor.values.remove(atOffsets: $0) }
                    Button("Add Chosen Value", systemImage: "plus") {
                        editor.values.append(CharterValueEditor())
                    }
                }
                stringListSection("Responsibilities", items: $editor.responsibilities)
                stringListSection("Desired Ways of Being", items: $editor.desiredWaysOfBeing)
                stringListSection(
                    "Non-Negotiable Boundaries",
                    items: $editor.nonNegotiableBoundaries
                )
                stringListSection(
                    "Odyssey Must Never Optimize Me Into…",
                    items: $editor.antiOptimizationStatements
                )
                Section("Interpretation Notes") {
                    TextEditor(text: $editor.interpretationNotes)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("Edit Charter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar(save: save) }
        }
    }

    private func save() {
        do {
            let document = try editor.document()
            localFailure = nil
            Task {
                if await model.saveWorkshopDraft(
                    draftID: editor.draftID,
                    expectedStateRevision: editor.expectedStateRevision,
                    document: document
                ) {
                    dismiss()
                }
            }
        } catch {
            localFailure = error.localizedDescription
        }
    }

    @ToolbarContentBuilder
    private func editorToolbar(save: @escaping () -> Void) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save)
                .disabled(model.state.workshopPhase.isBusy)
        }
    }
}

private struct LifeStageDraftEditorView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: LifeStageDraftEditor
    @State private var localFailure: String?

    init(editor: LifeStageDraftEditor) {
        _editor = State(initialValue: editor)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let localFailure {
                    Section {
                        Label(localFailure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section("Current Chapter") {
                    TextField("Life-stage title", text: $editor.title)
                    contextField("Career", text: $editor.careerContext)
                    contextField("Partnership and family", text: $editor.partnershipFamilyContext)
                    contextField("Health and capability", text: $editor.healthCapabilityContext)
                    contextField("Geography", text: $editor.geographyContext)
                    contextField("Financial context", text: $editor.financialContext)
                }
                stringListSection(
                    "Care Responsibilities",
                    items: $editor.careResponsibilities
                )
                stringListSection(
                    "Identity Transitions",
                    items: $editor.identityTransitions
                )
                stringListSection("Major Horizons", items: $editor.horizons)
                stringListSection("Uncertainties", items: $editor.uncertainties)
                Section {
                    Text(
                        "Life stage is descriptive, not a milestone checklist. Leave culturally "
                            + "common expectations out unless they are actually yours."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Life Stage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(model.state.workshopPhase.isBusy)
                }
            }
        }
    }

    private func contextField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("Describe, do not prescribe", text: text, axis: .vertical)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        do {
            let document = try editor.document()
            localFailure = nil
            Task {
                if await model.saveWorkshopDraft(
                    draftID: editor.draftID,
                    expectedStateRevision: editor.expectedStateRevision,
                    document: document
                ) {
                    dismiss()
                }
            }
        } catch {
            localFailure = error.localizedDescription
        }
    }
}

private struct SeasonDraftEditorView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: SeasonDraftEditor
    @State private var localFailure: String?

    private let roles: [DirectionRole] = [
        .primary,
        .foundation,
        .maintenance,
        .exploration,
        .dormant,
    ]
    private let allocations: [AllocationBand] = [
        .minimal,
        .low,
        .moderate,
        .high,
        .dominant,
    ]

    init(editor: SeasonDraftEditor) {
        _editor = State(initialValue: editor)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let localFailure {
                    Section {
                        Label(localFailure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section("Decision Policy") {
                    TextField("Season title", text: $editor.title)
                    Picker("Status", selection: $editor.status) {
                        ForEach(editor.allowedStatuses, id: \.rawValue) { status in
                            Text(status.displayName).tag(status)
                        }
                    }
                    TextField("Why this season exists", text: $editor.rationale, axis: .vertical)
                    TextField(
                        "What a good week feels like",
                        text: $editor.goodWeekDescription,
                        axis: .vertical
                    )
                    TextField("Review cadence", text: $editor.reviewCadence)
                    TextField(
                        "Transition notes (optional)",
                        text: $editor.transitionNotes,
                        axis: .vertical
                    )
                }

                Section("Portfolio") {
                    ForEach($editor.portfolioItems) { $item in
                        DisclosureGroup(item.role.displayName) {
                            Picker("Role", selection: $item.role) {
                                ForEach(roles, id: \.rawValue) { role in
                                    Text(role.displayName).tag(role)
                                }
                            }
                            Picker("Attention", selection: $item.allocationBand) {
                                ForEach(allocations, id: \.rawValue) { allocation in
                                    Text(allocation.displayName).tag(allocation)
                                }
                            }
                            TextField(
                                "Minimum viable commitment",
                                text: $item.minimumViableCommitment,
                                axis: .vertical
                            )
                            TextField(
                                "Sacrifice limit",
                                text: $item.sacrificeLimit,
                                axis: .vertical
                            )
                            EditableStringList(
                                items: $item.successSignals,
                                placeholder: "Success signal"
                            )
                            OptionalLocalDateField(
                                title: "Review date",
                                value: $item.reviewDate
                            )
                        }
                    }
                    .onDelete { editor.portfolioItems.remove(atOffsets: $0) }
                    Button("Add Portfolio Direction", systemImage: "plus") {
                        editor.portfolioItems.append(SeasonPortfolioItemEditor())
                    }
                }

                stringListSection("Triggering Context", items: $editor.triggeringContext)
                stringListSection("Explicit Non-Goals", items: $editor.explicitNonGoals)
                stringListSection("Hard Constraints", items: $editor.constraints)
                stringListSection(
                    "Opportunity and Spontaneity Budgets",
                    items: $editor.opportunityBudgets
                )
                stringListSection("Progress Signals", items: $editor.progressSignals)
                stringListSection("Failure Guardrails", items: $editor.failureGuardrails)
                stringListSection(
                    "Protected Experiences and Relationships",
                    items: $editor.protectedExperiences
                )
                stringListSection("Known Trade-Offs", items: $editor.knownTradeoffs)
                stringListSection(
                    "Transition Conditions",
                    items: $editor.transitionTriggers
                )
                Section("Exceptional Attention Cost") {
                    TextField(
                        "Why more than two primary directions are justified (optional)",
                        text: $editor.primaryOverrideExplanation,
                        axis: .vertical
                    )
                    Text(
                        "One primary direction is the normal attention budget. Exceptions remain "
                            + "possible, but the review will make their likely cost visible."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Season")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(model.state.workshopPhase.isBusy)
                }
            }
        }
    }

    private func save() {
        do {
            let document = try editor.document()
            localFailure = nil
            Task {
                if await model.saveWorkshopDraft(
                    draftID: editor.draftID,
                    expectedStateRevision: editor.expectedStateRevision,
                    document: document
                ) {
                    dismiss()
                }
            }
        } catch {
            localFailure = error.localizedDescription
        }
    }
}

private struct EditableStringList: View {
    @Binding var items: [String]
    let placeholder: String

    var body: some View {
        ForEach(items.indices, id: \.self) { index in
            TextField(
                placeholder,
                text: Binding(
                    get: { items[index] },
                    set: { items[index] = $0 }
                ),
                axis: .vertical
            )
        }
        .onDelete { items.remove(atOffsets: $0) }
        Button("Add", systemImage: "plus") {
            items.append("")
        }
    }
}

private struct OptionalLocalDateField: View {
    let title: String
    @Binding var value: LocalDate?

    var body: some View {
        Toggle(
            "Use \(title.lowercased())",
            isOn: Binding(
                get: { value != nil },
                set: { enabled in
                    value = enabled ? Self.localDate(from: Date()) : nil
                }
            )
        )
        if value != nil {
            DatePicker(
                title,
                selection: Binding(
                    get: { value.flatMap(Self.date(from:)) ?? Date() },
                    set: { value = Self.localDate(from: $0) }
                ),
                displayedComponents: .date
            )
        }
    }

    private static func localDate(from date: Date) -> LocalDate {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return LocalDate(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    private static func date(from value: LocalDate) -> Date? {
        Calendar.current.date(
            from: DateComponents(year: value.year, month: value.month, day: value.day)
        )
    }
}

private struct AcceptedLifeModelVersionView: View {
    let version: CachedLifeModelVersion

    var body: some View {
        List {
            Section("Acceptance") {
                LabeledContent("Layer", value: version.kind.displayName)
                LabeledContent("Version", value: String(version.versionNumber))
                LabeledContent(
                    "Accepted",
                    value: version.acceptedAt.formatted(date: .long, time: .shortened)
                )
                LabeledContent(
                    "Method",
                    value: version.acceptanceMethod.displayName
                )
                Text("This historical version is immutable and remains inspectable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            acceptedDocument
        }
        .navigationTitle(version.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var acceptedDocument: some View {
        switch version.kind {
        case .charter:
            if let charter = try? SyncJSONCoding.makeDecoder().decode(
                CharterVersion.self,
                from: version.document
            ) {
                CharterAcceptedSections(charter: charter)
            } else {
                invalidDocument
            }
        case .lifeStage:
            if let lifeStage = try? SyncJSONCoding.makeDecoder().decode(
                LifeStageVersion.self,
                from: version.document
            ) {
                LifeStageAcceptedSections(lifeStage: lifeStage)
            } else {
                invalidDocument
            }
        case .season:
            if let season = try? SyncJSONCoding.makeDecoder().decode(
                Season.self,
                from: version.document
            ) {
                SeasonAcceptedSections(season: season)
            } else {
                invalidDocument
            }
        }
    }

    private var invalidDocument: some View {
        Section {
            ContentUnavailableView(
                "Version unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The cached typed document could not be decoded safely.")
            )
        }
    }
}

private struct CharterAcceptedSections: View {
    let charter: CharterVersion

    var body: some View {
        Section("Chosen Values") {
            ForEach(charter.values, id: \.id) { value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.title).font(.headline)
                    Text(value.description)
                    Text(value.positiveExpression).foregroundStyle(.secondary)
                    if let failure = value.antiValueOrFailureMode {
                        Text("Guardrail: \(failure)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        readOnlyListSection("Responsibilities", values: charter.responsibilities)
        readOnlyListSection("Desired Ways of Being", values: charter.desiredWaysOfBeing)
        readOnlyListSection("Boundaries", values: charter.nonNegotiableBoundaries)
        readOnlyListSection(
            "Anti-Optimization Statements",
            values: charter.antiOptimizationStatements
        )
        if !charter.interpretationNotes.isEmpty {
            Section("Interpretation") { Text(charter.interpretationNotes) }
        }
    }
}

private struct LifeStageAcceptedSections: View {
    let lifeStage: LifeStageVersion

    var body: some View {
        Section("Current Chapter") {
            LabeledContent("Title", value: lifeStage.title)
            context("Career", value: lifeStage.careerContext)
            context("Partnership and family", value: lifeStage.partnershipFamilyContext)
            context("Health and capability", value: lifeStage.healthCapabilityContext)
            context("Geography", value: lifeStage.geographyContext)
            context("Financial", value: lifeStage.financialContext)
        }
        readOnlyListSection("Care Responsibilities", values: lifeStage.careResponsibilities)
        readOnlyListSection("Identity Transitions", values: lifeStage.identityTransitions)
        readOnlyListSection("Horizons", values: lifeStage.horizons)
        readOnlyListSection("Uncertainties", values: lifeStage.uncertainties)
    }

    @ViewBuilder
    private func context(_ title: String, value: String) -> some View {
        if !value.isEmpty {
            LabeledContent(title, value: value)
        }
    }
}

private struct SeasonAcceptedSections: View {
    let season: Season

    var body: some View {
        Section("Decision Policy") {
            LabeledContent("Title", value: season.title)
            LabeledContent("Status", value: season.status.displayName)
            Text(season.rationale)
            LabeledContent("Good week", value: season.goodWeekDescription)
            LabeledContent("Review cadence", value: season.reviewCadence)
        }
        Section("Portfolio") {
            ForEach(season.portfolioItems, id: \.directionID) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.role.displayName).font(.headline)
                    Text("Attention: \(item.allocationBand.displayName)")
                    if let commitment = item.minimumViableCommitment {
                        Text(commitment)
                    }
                    if let limit = item.sacrificeLimit {
                        Text("Sacrifice limit: \(limit)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(item.successSignals.enumerated()), id: \.offset) { entry in
                        Label(entry.element, systemImage: "waveform.path.ecg")
                    }
                }
            }
        }
        readOnlyListSection("Explicit Non-Goals", values: season.explicitNonGoals)
        readOnlyListSection("Constraints", values: season.constraints)
        readOnlyListSection("Opportunity Budgets", values: season.opportunityBudgets)
        readOnlyListSection("Progress Signals", values: season.progressSignals)
        readOnlyListSection("Failure Guardrails", values: season.failureGuardrails)
        readOnlyListSection("Protected Experiences", values: season.protectedExperiences)
        readOnlyListSection("Known Trade-Offs", values: season.knownTradeoffs)
        readOnlyListSection("Transition Conditions", values: season.transitionTriggers)
        if let notes = season.transitionNotes, !notes.isEmpty {
            Section("Transition Notes") { Text(notes) }
        }
    }
}

private func stringListSection(
    _ title: String,
    items: Binding<[String]>
) -> some View {
    Section(title) {
        EditableStringList(items: items, placeholder: title)
    }
}

private func readOnlyListSection(
    _ title: String,
    values: [String]
) -> some View {
    Section(title) {
        if values.isEmpty {
            Text("None recorded").foregroundStyle(.secondary)
        } else {
            ForEach(Array(values.enumerated()), id: \.offset) { entry in
                Text(entry.element)
            }
        }
    }
}

private func decodeDocument<Value: Decodable>(
    _ type: Value.Type,
    from document: [String: JSONValue]
) throws -> Value {
    try SyncJSONCoding.makeDecoder().decode(
        type,
        from: SyncJSONCoding.makeEncoder().encode(document)
    )
}

private extension LifeModelKind {
    var sectionTitle: String {
        switch self {
        case .charter:
            "Enduring Charter"
        case .lifeStage:
            "Current Life Stage"
        case .season:
            "Season Decision Policy"
        }
    }

    var emptyExplanation: String {
        switch self {
        case .charter:
            "Start from the commission-derived seed, then affirm, revise, or abandon every word."
        case .lifeStage:
            "Describe current context without inferring culturally normal milestones."
        case .season:
            "Create a compact decision policy after a Charter is accepted or durably queued."
        }
    }

    var createLabel: String {
        switch self {
        case .charter:
            "Review Initial Charter Seed"
        case .lifeStage:
            "Describe Current Life Stage"
        case .season:
            "Review Initial Season Seed"
        }
    }

    var symbolName: String {
        switch self {
        case .charter:
            "text.book.closed"
        case .lifeStage:
            "person.crop.circle.badge.clock"
        case .season:
            "sailboat"
        }
    }
}

private extension LifeModelDraftPhase {
    var displayName: String {
        switch self {
        case .editing:
            "editing"
        case .reviewed:
            "reviewed"
        case .queued:
            "queued for immutable acceptance"
        case .abandoned:
            "abandoned"
        }
    }
}

private extension LifeModelDeliveryStatus {
    var displayName: String {
        switch self {
        case .pending:
            "Waiting for delivery"
        case .retry:
            "Retry scheduled"
        case .accepted:
            "Accepted"
        case .conflict:
            "Meaning conflict"
        case .rejected:
            "Rejected"
        }
    }

    var ownerExplanation: String {
        switch self {
        case .pending:
            "The exact reviewed command is durable on this device."
        case .retry:
            "Delivery was inconclusive. The bounded retry keeps the same immutable command."
        case .accepted:
            "The server accepted this immutable version and local history was refreshed."
        case .conflict:
            "Another accepted version changed the predecessor. Owner review is required."
        case .rejected:
            "The command was not accepted. Correct the issue through a new reviewed version."
        }
    }

    var symbolName: String {
        switch self {
        case .pending, .retry:
            "clock.arrow.circlepath"
        case .accepted:
            "checkmark.seal"
        case .conflict:
            "arrow.triangle.branch"
        case .rejected:
            "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .retry:
            .secondary
        case .accepted:
            .green
        case .conflict:
            .orange
        case .rejected:
            .red
        }
    }
}

private extension LifeModelSemanticChangeKind {
    var displayName: String {
        switch self {
        case .added:
            "Added"
        case .removed:
            "Removed"
        case .changed:
            "Changed"
        }
    }
}

private extension LifeModelAcceptanceMethod {
    var displayName: String {
        switch self {
        case .ownerAuthored:
            "Owner authored"
        case .ownerReviewedAssisted:
            "Owner reviewed assisted draft"
        case .ownerApprovedImport:
            "Owner approved import"
        }
    }
}

private extension SeasonStatus {
    var displayName: String {
        switch self {
        case .draft:
            "Draft"
        case .calibration:
            "Calibration"
        case .active:
            "Active"
        case .transitioning:
            "Transitioning"
        case .complete:
            "Complete"
        case .abandoned:
            "Abandoned"
        }
    }
}

private extension DirectionRole {
    var displayName: String {
        switch self {
        case .primary:
            "Primary direction"
        case .foundation:
            "Protected foundation"
        case .maintenance:
            "Maintenance"
        case .exploration:
            "Exploration"
        case .dormant:
            "Deliberately dormant"
        }
    }
}

private extension AllocationBand {
    var displayName: String {
        rawValue.capitalized
    }
}
