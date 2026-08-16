import Foundation
import OdysseyApplication
import OdysseyDomain
import OdysseyIntelligence
import OdysseySync
import OdysseyTelemetry
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum PrimarySpace: Hashable {
    case now
    case map
    case archive
    case workshop
}

private enum RootSheet: Identifiable {
    case capture
    case food(surface: WarmPathSurface, correlationID: UUID)

    var id: String {
        switch self {
        case .capture:
            "capture"
        case .food:
            "food"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @State private var selection: PrimarySpace = .now
    @State private var activeSheet: RootSheet?

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
        .sheet(
            item: $activeSheet,
            onDismiss: resumeExtensionPresentations
        ) { sheet in
            switch sheet {
            case .capture:
                CaptureSheet()
                    .environmentObject(model)
            case let .food(surface, correlationID):
                FoodQuickLogView(
                    warmPathSurface: surface,
                    warmPathCorrelationID: correlationID
                )
                    .environmentObject(model)
            }
        }
        .onChange(of: model.extensionPresentationRequest, initial: true) {
            _, request in
            guard let request else { return }
            switch request.kind {
            case .capture:
                presentCapture()
            case .food:
                presentFoodLog(
                    surface: request.invokingSurface.warmPathSurface,
                    correlationID: request.commandID.rawValue
                )
            }
            model.consumeExtensionPresentationRequest()
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            NavigationStack {
                NowView(
                    openCapture: presentCapture,
                    openFood: { presentFoodLog() },
                    openWorkshop: { selection = .workshop }
                )
            }
            .tabItem { Label("Now", systemImage: "location.fill") }
            .tag(PrimarySpace.now)

            NavigationStack {
                SeasonMapView { selection = .workshop }
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
            Menu {
                Button(action: { presentFoodLog() }) {
                    Label("Log Food", systemImage: "fork.knife")
                }
                Button(action: presentCapture) {
                    Label("Capture", systemImage: "square.and.pencil")
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title2)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Quick actions")
            .accessibilityHint("Log food or save a capture locally before any network request")
            .padding(.trailing, 20)
            .padding(.bottom, 72)
        }
    }

    private func presentCapture() {
        model.dismissCaptureStatus()
        activeSheet = .capture
    }

    private func presentFoodLog(
        surface: WarmPathSurface = .iPhone,
        correlationID: UUID = UUID()
    ) {
        model.dismissFoodStatus()
        activeSheet = .food(
            surface: surface,
            correlationID: correlationID
        )
    }

    private func resumeExtensionPresentations() {
        Task {
            await model.processPendingExtensionCommands()
        }
    }
}

private extension ExtensionInvokingSurface {
    var warmPathSurface: WarmPathSurface {
        switch self {
        case .appIntent:
            .appIntent
        case .control:
            .control
        case .widget:
            .widget
        case .watch:
            .watch
        }
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
                    NavigationLink(value: capture.metadata.id) {
                        CaptureArchiveRow(capture: capture)
                    }
                }
            }
        }
        .navigationTitle("Archive")
        .navigationDestination(for: UUIDv7.self) { captureID in
            CaptureDetailView(captureID: captureID)
        }
        .refreshable { await model.refreshCaptureArchive() }
    }
}

private struct CaptureArchiveRow: View {
    let capture: CaptureRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(captureTitle(capture))
                .lineLimit(3)
            HStack(alignment: .center) {
                Text(capture.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                CaptureInterpretationBadge(capture: capture)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureDetailView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @State private var isCorrectionPresented = false
    @State private var confirmsDismissal = false
    @State private var correctedCategory = CaptureReviewCategory.note
    @State private var pendingReviewDraft: CaptureInterpretationReviewDraft?
    @State private var isReviewing = false
    @State private var reviewMessage: String?
    @State private var reviewFailure: String?

    let captureID: UUIDv7

    private var capture: CaptureRecord? {
        model.state.recentCaptures.first { $0.metadata.id == captureID }
    }

    var body: some View {
        Group {
            if let capture {
                captureList(capture)
            } else {
                ContentUnavailableView {
                    Label("Capture unavailable", systemImage: "tray")
                } description: {
                    Text("Refresh the local Archive to load this capture again.")
                } actions: {
                    Button("Refresh") {
                        Task { await model.refreshCaptureArchive() }
                    }
                }
            }
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isCorrectionPresented) {
            CaptureCategoryCorrectionView(initialCategory: correctedCategory) { category in
                submitReview(
                    disposition: .corrected,
                    replacementValues: ["capture_type": .string(category.rawValue)]
                )
            }
        }
        .confirmationDialog(
            "Dismiss this interpretation?",
            isPresented: $confirmsDismissal,
            titleVisibility: .visible
        ) {
            Button("Dismiss Interpretation", role: .destructive) {
                submitReview(disposition: .dismissed)
            }
            Button("Keep Interpretation", role: .cancel) {}
        } message: {
            Text(
                "The original capture and every earlier interpretation remain unchanged. "
                    + "Dismissal appends a new owner-reviewed version."
            )
        }
        .alert(
            "Review not saved",
            isPresented: Binding(
                get: { reviewFailure != nil },
                set: { presented in
                    if !presented {
                        reviewFailure = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reviewFailure ?? "The owner review was not saved.")
        }
    }

    private func captureList(_ capture: CaptureRecord) -> some View {
        List {
            Section("Original Capture · Immutable") {
                Text(originalPayloadDescription(capture))
                    .textSelection(.enabled)
                LabeledContent("Kind", value: payloadKindTitle(capture.originalPayload.kind))
                LabeledContent(
                    "Captured",
                    value: capture.capturedAt.formatted(date: .long, time: .standard)
                )
                LabeledContent("Source", value: capture.initialContext.invokingSurface.rawValue)
                LabeledContent("Timezone", value: capture.initialContext.timeZoneID)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content hash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(capture.originalPayload.contentHash)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text(
                    "Owner review never edits this payload. It appends a source-linked "
                        + "interpretation version instead."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            let audioReferences = capture.attachments.filter { $0.kind == .audio }
            if !audioReferences.isEmpty {
                Section("Voice Playback") {
                    ForEach(audioReferences, id: \.attachmentID) { reference in
                        CaptureAudioPlaybackView(reference: reference)
                    }
                }
            }

            Section("Current Interpretation") {
                CaptureInterpretationBadge(capture: capture)
                Text(currentInterpretationExplanation(capture))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if capture.interpretationVersions.isEmpty {
                Section("Interpretation History") {
                    Text("No interpretation version has been appended yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(
                    Array(capture.interpretationVersions.enumerated()),
                    id: \.element.id
                ) { entry in
                    Section(versionSectionTitle(entry.element, index: entry.offset)) {
                        CaptureInterpretationVersionView(version: entry.element)
                    }
                }
            }

            ownerReviewSection(capture)
        }
        .refreshable { await model.refreshCaptureArchive() }
    }

    @ViewBuilder
    private func ownerReviewSection(_ capture: CaptureRecord) -> some View {
        Section("Owner Review") {
            Text(
                "Accept, correct, or dismiss only the latest interpretation. Each choice is "
                    + "durable and leaves earlier versions inspectable."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let reviewMessage {
                Label(reviewMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }

            if isReviewing {
                ProgressView("Saving owner review locally…")
            }

            if let latest = capture.interpretationVersions.last {
                if canAccept(latest) {
                    Button {
                        submitReview(disposition: .accepted)
                    } label: {
                        Label("Accept Inferred Fields", systemImage: "checkmark.seal")
                    }
                    .disabled(isReviewing)
                }

                Button {
                    presentCategoryCorrection(latest)
                } label: {
                    Label("Correct Category", systemImage: "square.and.pencil")
                }
                .disabled(isReviewing)

                if latest.status != .dismissed {
                    Button(role: .destructive) {
                        confirmsDismissal = true
                    } label: {
                        Label("Dismiss Interpretation", systemImage: "xmark.circle")
                    }
                    .disabled(isReviewing)
                }
            } else {
                Text("Review actions appear after interpretation completes.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func canAccept(_ version: CaptureInterpretationVersion) -> Bool {
        version.status != .dismissed
            && !version.proposedFields.isEmpty
            && version.ownerReviewDisposition == nil
    }

    private func presentCategoryCorrection(_ version: CaptureInterpretationVersion) {
        if let field = version.proposedFields["capture_type"],
           case let .string(value) = field.value,
           let category = CaptureReviewCategory(rawValue: value)
        {
            correctedCategory = category
        } else {
            correctedCategory = .note
        }
        isCorrectionPresented = true
    }

    private func submitReview(
        disposition: CaptureInterpretationReviewDisposition,
        replacementValues: [String: JSONValue] = [:]
    ) {
        guard let capture,
              let target = capture.interpretationVersions.last,
              !isReviewing
        else { return }

        let draft: CaptureInterpretationReviewDraft
        do {
            if let pendingReviewDraft,
               pendingReviewDraft.targetInterpretationVersionID == target.id,
               pendingReviewDraft.expectedCaptureRevision == capture.metadata.revision,
               pendingReviewDraft.disposition == disposition,
               pendingReviewDraft.replacementValues == replacementValues,
               pendingReviewDraft.note == nil
            {
                draft = pendingReviewDraft
            } else {
                draft = try CaptureInterpretationReviewDraft(
                    targetInterpretationVersionID: target.id,
                    expectedCaptureRevision: capture.metadata.revision,
                    disposition: disposition,
                    replacementValues: replacementValues
                )
            }
        } catch {
            reviewFailure = error.localizedDescription
            return
        }

        pendingReviewDraft = draft
        reviewMessage = nil
        reviewFailure = nil
        isReviewing = true
        Task {
            defer { isReviewing = false }
            do {
                try await model.reviewCapture(captureID: captureID, draft: draft)
                pendingReviewDraft = nil
                reviewMessage = reviewSuccessMessage(disposition)
            } catch {
                reviewFailure = error.localizedDescription
                await model.refreshCaptureArchive()
            }
        }
    }

    private func reviewSuccessMessage(
        _ disposition: CaptureInterpretationReviewDisposition
    ) -> String {
        switch disposition {
        case .accepted:
            "Accepted fields were appended as owner-reviewed history."
        case .corrected:
            "The corrected category was appended as owner-reviewed history."
        case .dismissed:
            "Dismissal was appended; the original capture remains unchanged."
        }
    }
}

private struct CaptureAudioPlaybackView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: OdysseyAppModel
    @StateObject private var player = CaptureAudioPlayer()
    @State private var loadTask: Task<Void, Never>?
    @State private var loadRequestID: UUID?

    let reference: CaptureAttachmentReference

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: playbackAction) {
                    Label(playbackTitle, systemImage: playbackSystemImage)
                }
                .disabled(player.state == .loading)

                if player.state == .playing || player.state == .paused {
                    Button("Stop", role: .destructive) {
                        stopPlayback()
                    }
                }
            }

            if player.duration > 0 {
                ProgressView(
                    value: min(player.elapsed, player.duration),
                    total: player.duration
                )
                Text(
                    "\(playbackTime(player.elapsed)) of "
                        + playbackTime(player.duration)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if case let .failed(message) = player.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text(
                "Playback opens only the hash-verified local attachment. "
                    + "It does not upload or interpret the recording."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                stopPlayback()
            }
        }
        .onDisappear(perform: stopPlayback)
    }

    private var playbackTitle: String {
        switch player.state {
        case .loading:
            "Verifying…"
        case .playing:
            "Pause"
        case .paused:
            "Resume"
        case .finished:
            "Play Again"
        case .idle, .failed:
            "Play Voice Capture"
        }
    }

    private var playbackSystemImage: String {
        switch player.state {
        case .loading:
            "checkmark.shield"
        case .playing:
            "pause.fill"
        case .paused, .finished, .idle, .failed:
            "play.fill"
        }
    }

    private func playbackAction() {
        switch player.state {
        case .playing:
            player.pause()
        case .paused:
            player.resume()
        case .idle, .finished, .failed:
            startPlayback()
        case .loading:
            break
        }
    }

    private func startPlayback() {
        stopPlayback()
        player.beginLoading()
        let requestID = UUID()
        loadRequestID = requestID
        loadTask = Task {
            do {
                let url = try await model.verifiedCaptureContentURL(for: reference)
                try Task.checkCancellation()
                guard loadRequestID == requestID else { return }
                player.playVerifiedContent(at: url)
            } catch is CancellationError {
                return
            } catch {
                guard loadRequestID == requestID else { return }
                player.fail("The local voice capture failed integrity verification.")
            }
            if loadRequestID == requestID {
                loadRequestID = nil
                loadTask = nil
            }
        }
    }

    private func stopPlayback() {
        loadRequestID = nil
        loadTask?.cancel()
        loadTask = nil
        player.stop()
    }

    private func playbackTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CaptureInterpretationVersionView: View {
    let version: CaptureInterpretationVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CaptureInterpretationBadge(version: version)
                Spacer(minLength: 12)
                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Status", value: interpretationStatusTitle(version.status))
            LabeledContent(
                "Interpreter",
                value: "\(version.interpreter) · \(version.interpreterVersion)"
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Version ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(version.id.description)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            if let superseded = version.supersedesInterpretationVersionID {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Supersedes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(superseded.description)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if version.proposedFields.isEmpty {
                Text("This version intentionally contains no interpreted fields.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(version.proposedFields.keys.sorted(), id: \.self) { name in
                    if let field = version.proposedFields[name] {
                        CaptureInterpretedFieldView(name: name, field: field)
                    }
                }
            }

            if let note = version.ownerReviewNote {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Owner note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(note)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CaptureInterpretedFieldView: View {
    let name: String
    let field: CaptureInterpretedField

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(captureFieldTitle(name))
                .font(.subheadline.weight(.semibold))
            Text(captureJSONDescription(field.value))
                .textSelection(.enabled)
            Text("Sources")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(field.sourceSpanRefs, id: \.self) { source in
                Text(source)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CaptureInterpretationBadge: View {
    private let title: String
    private let systemImage: String
    private let color: Color

    init(capture: CaptureRecord) {
        let presentation: (title: String, systemImage: String, color: Color)
        if let latest = capture.interpretationVersions.last {
            presentation = interpretationPresentation(
                status: latest.status,
                disposition: latest.ownerReviewDisposition
            )
        } else {
            presentation = interpretationPresentation(
                status: capture.interpretationStatus,
                disposition: nil
            )
        }
        title = presentation.title
        systemImage = presentation.systemImage
        color = presentation.color
    }

    init(version: CaptureInterpretationVersion) {
        let presentation = interpretationPresentation(
            status: version.status,
            disposition: version.ownerReviewDisposition
        )
        title = presentation.title
        systemImage = presentation.systemImage
        color = presentation.color
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private enum CaptureReviewCategory: String, CaseIterable, Identifiable {
    case note
    case food
    case caffeine
    case alcohol
    case decision
    case commitment
    case observation
    case symptom
    case outcome
    case personMoment = "person_moment"
    case idea
    case quickAction = "quick_action"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .note:
            "Note"
        case .food:
            "Food"
        case .caffeine:
            "Caffeine"
        case .alcohol:
            "Alcohol"
        case .decision:
            "Decision"
        case .commitment:
            "Commitment"
        case .observation:
            "Observation"
        case .symptom:
            "Symptom"
        case .outcome:
            "Outcome"
        case .personMoment:
            "Person Moment"
        case .idea:
            "Idea"
        case .quickAction:
            "Quick Action"
        }
    }
}

private struct CaptureCategoryCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: CaptureReviewCategory

    let apply: (CaptureReviewCategory) -> Void

    init(
        initialCategory: CaptureReviewCategory,
        apply: @escaping (CaptureReviewCategory) -> Void
    ) {
        _selection = State(initialValue: initialCategory)
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Correct Category") {
                    Picker("Category", selection: $selection) {
                        ForEach(CaptureReviewCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                }
                Section {
                    Text(
                        "Saving appends an owner-corrected interpretation. The original capture "
                            + "and inferred version remain unchanged and inspectable."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Correct Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        apply(selection)
                        dismiss()
                    }
                }
            }
        }
    }
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

private func originalPayloadDescription(_ capture: CaptureRecord) -> String {
    switch capture.originalPayload.kind {
    case .text, .structuredQuickAction:
        capture.originalPayload.contentOrObjectRef
    case .audio:
        "Protected audio reference: \(capture.originalPayload.contentOrObjectRef)"
    case .imageReference:
        "Protected image reference: \(capture.originalPayload.contentOrObjectRef)"
    case .fileReference:
        "Protected file reference: \(capture.originalPayload.contentOrObjectRef)"
    }
}

private func payloadKindTitle(_ kind: CapturePayloadKind) -> String {
    switch kind {
    case .text:
        "Text"
    case .audio:
        "Audio"
    case .imageReference:
        "Image Reference"
    case .fileReference:
        "File Reference"
    case .structuredQuickAction:
        "Structured Quick Action"
    }
}

private func currentInterpretationExplanation(_ capture: CaptureRecord) -> String {
    guard let latest = capture.interpretationVersions.last else {
        return "The original capture is durable. Interpretation can finish asynchronously."
    }
    switch latest.ownerReviewDisposition {
    case .some(.accepted):
        return "The latest fields were explicitly accepted by the owner."
    case .some(.corrected):
        return "The latest fields include an explicit owner correction."
    case .some(.dismissed):
        return "The latest interpretation was dismissed without changing the original capture."
    case .none:
        switch latest.status {
        case .interpreted:
            return "These fields are inferred and are not owner-reviewed canonical observations."
        case .needsClarification:
            return "Interpretation needs clarification before any field can be relied on."
        case .failed:
            return "Interpretation failed; the immutable original capture is still available."
        case .dismissed:
            return "This non-owner interpretation version is marked dismissed."
        case .pending, .processing:
            return "Interpretation has not produced a durable result yet."
        }
    }
}

private func versionSectionTitle(
    _ version: CaptureInterpretationVersion,
    index: Int
) -> String {
    let kind: String
    if version.ownerReviewDisposition != nil {
        kind = "Owner Review"
    } else if version.status == .interpreted {
        kind = "Inferred"
    } else {
        kind = "Interpretation"
    }
    return "\(kind) Version \(index + 1)"
}

private func interpretationPresentation(
    status: CaptureInterpretationStatus,
    disposition: CaptureInterpretationReviewDisposition?
) -> (title: String, systemImage: String, color: Color) {
    if let disposition {
        switch disposition {
        case .accepted:
            return ("Owner Accepted", "checkmark.seal.fill", .green)
        case .corrected:
            return ("Owner Corrected", "pencil.circle.fill", .blue)
        case .dismissed:
            return ("Owner Dismissed", "xmark.circle.fill", .secondary)
        }
    }
    switch status {
    case .pending, .processing:
        return ("Pending", "clock", .secondary)
    case .needsClarification:
        return ("Needs Review", "questionmark.circle", .orange)
    case .interpreted:
        return ("Inferred", "sparkles", .orange)
    case .failed:
        return ("Interpretation Failed", "exclamationmark.triangle", .red)
    case .dismissed:
        return ("Dismissed", "xmark.circle", .secondary)
    }
}

private func interpretationStatusTitle(_ status: CaptureInterpretationStatus) -> String {
    switch status {
    case .pending:
        "Pending"
    case .processing:
        "Processing"
    case .needsClarification:
        "Needs Clarification"
    case .interpreted:
        "Interpreted"
    case .failed:
        "Failed"
    case .dismissed:
        "Dismissed"
    }
}

private func captureFieldTitle(_ name: String) -> String {
    name.split(separator: "_")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

private func captureJSONDescription(_ value: JSONValue) -> String {
    switch value {
    case let .string(string):
        string
    case let .number(number):
        number.formatted(.number.precision(.fractionLength(0 ... 6)))
    case let .bool(boolean):
        boolean ? "Yes" : "No"
    case .null:
        "None"
    case .array, .object:
        if let data = try? SyncJSONCoding.makeEncoder().encode(value),
           let text = String(data: data, encoding: .utf8)
        {
            text
        } else {
            "Structured value"
        }
    }
}

private struct NowView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @State private var isPresentingCorrection = false
    @State private var isRespondingToReentry = false

    let openCapture: () -> Void
    let openFood: () -> Void
    let openWorkshop: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let reentry = model.reentrySurface {
                    reentryCard(reentry)
                }

                if let projection = model.nowContextProjection {
                    currentContextCard(projection.now)
                    tomorrowMapCard(projection.tomorrow)
                } else {
                    ContentUnavailableView {
                        Label("Current context unavailable", systemImage: "location.slash")
                    } description: {
                        Text(
                            model.nowExperienceMessage
                                ?? "Odyssey is still building a bounded view from local state."
                        )
                    } actions: {
                        Button("Retry") {
                            Task { await model.refreshNowExperience() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                operationalStatus
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Now")
        .refreshable { await model.refreshNowExperience() }
        .sheet(isPresented: $isPresentingCorrection) {
            NowStateCorrectionSheet(
                initialState: model.nowContextProjection?.now.state ?? .clear
            ) { state, reason in
                await model.setNowStateCorrection(state: state, reason: reason)
            }
        }
    }

    private func reentryCard(_ surface: ReentrySurface) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "No backlog is waiting. Here are only the changes that remain relevant now."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if surface.summary.isEmpty {
                    Label(
                        "No current material change needs replay.",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    ForEach(surface.summary, id: \.changeID) { item in
                        Label(item.summary, systemImage: "arrow.trianglehead.2.clockwise")
                            .font(.subheadline)
                    }
                }

                if let question = surface.oneQuestion {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("One useful question")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(question)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack {
                        reentryButtons(surface)
                    }
                    VStack(alignment: .leading) {
                        reentryButtons(surface)
                    }
                }
                .disabled(isRespondingToReentry)
            }
        } label: {
            Label("Welcome back", systemImage: "sunrise")
                .font(.headline)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func reentryButtons(_ surface: ReentrySurface) -> some View {
        if surface.options.contains(.continue) {
            Button("Continue") {
                respondToReentry(.continue)
            }
            .buttonStyle(.borderedProminent)
        }
        if surface.options.contains(.reviseSeason) {
            Button("Revise Season") {
                respondToReentry(.reviseSeason)
            }
            .buttonStyle(.bordered)
        }
        if surface.options.contains(.stayQuiet) {
            Button("Stay Quiet") {
                respondToReentry(.stayQuiet)
            }
            .buttonStyle(.bordered)
        }
    }

    private func currentContextCard(_ projection: NowContextProjection) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label(projection.state.ownerTitle, systemImage: projection.state.systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(projection.state.tint)
                    Spacer()
                    if projection.correction != nil {
                        Text("Manual")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                    }
                }

                Text(projection.summary)
                    .font(.body)

                if projection.isIntentionallySilent {
                    Label("Intentional quiet", systemImage: "speaker.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if projection.state == .clear {
                    Label(
                        "This is an empty state, not an inference that silence is appropriate.",
                        systemImage: "questionmark.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }

                if let currentThread = projection.currentThread {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current thread")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(currentThread)
                    }
                }

                if let transition = projection.nextTransition {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next transition")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(transition.label ?? "Calendar commitment")
                            Spacer()
                            Text(localTime(transition.startsAt, timeZoneID: projection.timeZoneID))
                                .foregroundStyle(.secondary)
                        }
                        if transition.isTentative {
                            Text("Tentative")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !projection.hasEnoughContextForSilence {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Context availability")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(projection.sources, id: \.source) { source in
                            HStack {
                                Text(source.source.ownerTitle)
                                Spacer()
                                Text(source.state.ownerTitle)
                                    .foregroundStyle(
                                        source.state == .fresh ? Color.green : Color.secondary
                                    )
                            }
                            .font(.caption)
                        }
                    }
                }

                Divider()
                HStack {
                    Button("Correct State", systemImage: "slider.horizontal.3") {
                        isPresentingCorrection = true
                    }
                    .buttonStyle(.bordered)
                    if let correction = projection.correction {
                        Spacer()
                        Button("Clear Correction", role: .destructive) {
                            Task { await model.clearNowStateCorrection() }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint(
                            "Removes the manual \(correction.state.ownerTitle) state immediately."
                        )
                    }
                }

                if let correction = projection.correction {
                    Text(
                        "Reason: \(correction.reason.ownerTitle). Expires "
                            + correction.expiresAt.formatted(date: .abbreviated, time: .shortened)
                            + "."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("Current Context")
                .font(.headline)
        }
    }

    private func tomorrowMapCard(_ projection: TomorrowMapProjection) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(projection.shape)

                if projection.calendarState == .stale {
                    Label(
                        projection.calendarState.ownerExplanation,
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }

                if !projection.hasEnoughContext {
                    Label(
                        projection.calendarState.ownerExplanation,
                        systemImage: "calendar.badge.exclamationmark"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    if let pressurePoint = projection.pressurePoint {
                        tomorrowMapRow(
                            title: "Likely pressure point",
                            value: pressurePoint,
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                    if let preparationAction = projection.preparationAction {
                        tomorrowMapRow(
                            title: "High-leverage preparation",
                            value: preparationAction,
                            systemImage: "checklist"
                        )
                    }
                    if let openPeriod = projection.protectedOpenPeriod {
                        tomorrowMapRow(
                            title: "Protected open period",
                            value: localInterval(
                                from: openPeriod.startsAt,
                                to: openPeriod.endsAt,
                                timeZoneID: projection.timeZoneID
                            ),
                            systemImage: "leaf"
                        )
                    }
                    if projection.isIntentionallyOpen {
                        Label(
                            "Known Calendar context leaves tomorrow open; Odyssey will not "
                                + "fill it automatically.",
                            systemImage: "wind"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    }

                    if !projection.transitions.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Known transitions")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(projection.transitions, id: \.identifier) { transition in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(transition.title ?? "Calendar commitment")
                                            .lineLimit(2)
                                        if transition.isTentative {
                                            Text("Tentative")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(
                                        transition.isAllDay
                                            ? "All day"
                                            : localTime(
                                                transition.startsAt,
                                                timeZoneID: projection.timeZoneID
                                            )
                                    )
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let thread = projection.currentSeasonThread {
                        Divider()
                        tomorrowMapRow(
                            title: "Season thread",
                            value: thread,
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                        )
                    }
                }
            }
        } label: {
            HStack {
                Label("Tomorrow Map", systemImage: "map")
                Spacer()
                Text(localDate(projection.localDay))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.headline)
        }
    }

    private func tomorrowMapRow(
        title: String,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var operationalStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Log Food", systemImage: "fork.knife", action: openFood)
                    .buttonStyle(.borderedProminent)
                Button("Capture", systemImage: "square.and.pencil", action: openCapture)
                    .buttonStyle(.bordered)
            }

            if let message = model.nowExperienceMessage {
                Label(message, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let diagnostics = model.state.diagnostics,
               diagnostics.operationsQueued > 0
            {
                Label(
                    "\(diagnostics.operationsQueued) local change"
                        + "\(diagnostics.operationsQueued == 1 ? "" : "s") safely queued",
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

            if let measurement = model.foodWarmPathMeasurement {
                Button {
                    model.dismissFoodWarmPathMeasurement()
                } label: {
                    Label(
                        foodWarmPathStatus(measurement),
                        systemImage: measurement.meetsTarget
                            ? "timer.circle.fill"
                            : "timer.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(
                        measurement.meetsTarget ? Color.green : Color.secondary
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Dismisses this food quick-log timing result.")
            }

            if let message = model.extensionCommandMessage {
                Button {
                    model.dismissExtensionCommandMessage()
                } label: {
                    Label(message, systemImage: "tray.and.arrow.down")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Dismisses this extension command status.")
            }
        }
    }

    private func respondToReentry(_ option: ReentryOption) {
        guard !isRespondingToReentry else { return }
        isRespondingToReentry = true
        Task {
            let succeeded = await model.respondToReentry(option)
            isRespondingToReentry = false
            if succeeded, option == .reviseSeason {
                openWorkshop()
            }
        }
    }

    private func foodWarmPathStatus(_ measurement: WarmPathMeasurement) -> String {
        let seconds = (measurement.durationMilliseconds / 1_000).formatted(
            .number.precision(.fractionLength(1))
        )
        let interactionLabel = measurement.interactionCount == 1
            ? "interaction"
            : "interactions"
        let target = measurement.meetsTarget ? "target met" : "target missed"
        return "Food quick log from \(foodWarmPathSurfaceName(measurement.surface)): "
            + "\(seconds) s, \(measurement.interactionCount) \(interactionLabel), "
            + target
    }

    private func foodWarmPathSurfaceName(_ surface: WarmPathSurface) -> String {
        switch surface {
        case .iPhone:
            "iPhone"
        case .appIntent:
            "App Intent"
        case .widget:
            "Widget"
        case .control:
            "Control Center"
        case .watch:
            "Watch"
        }
    }

    private func localDate(_ value: LocalDate) -> String {
        String(format: "%04d-%02d-%02d", value.year, value.month, value.day)
    }

    private func localTime(_ value: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: timeZoneID)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: value)
    }

    private func localInterval(
        from start: Date,
        to end: Date,
        timeZoneID: String
    ) -> String {
        "\(localTime(start, timeZoneID: timeZoneID))–"
            + localTime(end, timeZoneID: timeZoneID)
    }
}

private struct NowStateCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: NowState
    @State private var reason: NowStateCorrectionReason = .situationChanged
    @State private var isSaving = false

    let save: (NowState, NowStateCorrectionReason) async -> Void

    init(
        initialState: NowState,
        save: @escaping (NowState, NowStateCorrectionReason) async -> Void
    ) {
        _state = State(initialValue: initialState)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("State") {
                    Picker("Current state", selection: $state) {
                        ForEach(NowState.allCases, id: \.self) { state in
                            Label(state.ownerTitle, systemImage: state.systemImage)
                                .tag(state)
                        }
                    }
                    .disabled(reason == .ownerRequestedQuiet)
                }

                Section("Reason") {
                    Picker("Why is the projection wrong?", selection: $reason) {
                        ForEach(NowStateCorrectionReason.allCases, id: \.self) { reason in
                            Text(reason.ownerTitle).tag(reason)
                        }
                    }
                    .onChange(of: reason) { _, value in
                        if value == .ownerRequestedQuiet {
                            state = .clear
                        }
                    }
                }

                Section {
                    Text(
                        "This explicit local correction expires after 24 hours. It does not "
                            + "rewrite Calendar, Health, Season, or other source history."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Correct Current State")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        isSaving = true
                        Task {
                            await save(state, reason)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

private extension NowState {
    var ownerTitle: String {
        switch self {
        case .clear: "Clear"
        case .choice: "Choice"
        case .preparation: "Preparation"
        case .recovery: "Recovery"
        case .open: "Open"
        case .disrupted: "Disrupted"
        }
    }

    var systemImage: String {
        switch self {
        case .clear: "water.waves"
        case .choice: "arrow.triangle.branch"
        case .preparation: "checklist"
        case .recovery: "heart.text.square"
        case .open: "wind"
        case .disrupted: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .clear: .teal
        case .choice: .orange
        case .preparation: .blue
        case .recovery: .mint
        case .open: .green
        case .disrupted: .red
        }
    }
}

private extension NowStateCorrectionReason {
    var ownerTitle: String {
        switch self {
        case .situationChanged: "Situation changed"
        case .capacityChanged: "Capacity changed"
        case .planChanged: "Plan changed"
        case .ownerRequestedQuiet: "I want quiet"
        case .other: "Other"
        }
    }
}

private extension CurrentContextSource {
    var ownerTitle: String {
        switch self {
        case .season: "Season"
        case .calendar: "Calendar"
        case .health: "Health"
        case .weather: "Weather"
        case .location: "Location"
        }
    }
}

private extension CurrentContextSourceState {
    var ownerTitle: String {
        switch self {
        case .fresh: "Fresh"
        case .stale: "Stale"
        case .missing: "Not connected"
        case .denied: "Denied"
        case .unavailable: "Unavailable"
        }
    }
}

private extension TomorrowCalendarState {
    var ownerExplanation: String {
        switch self {
        case .fresh: "Calendar context is fresh."
        case .stale: "The Tomorrow Map uses stale local Calendar context."
        case .missing: "No local Calendar context is available."
        case .denied: "Calendar access is denied; no open day is inferred."
        case .unavailable: "Calendar context is unavailable on this device."
        }
    }
}
private enum CaptureInputMode: String, CaseIterable, Identifiable {
    case text
    case voice
    case photo
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text:
            "Text"
        case .voice:
            "Voice"
        case .photo:
            "Photo"
        case .file:
            "File"
        }
    }
}

private struct CaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: OdysseyAppModel
    @FocusState private var isFocused: Bool
    @StateObject private var voiceRecorder = VoiceCaptureRecorder()
    @State private var mode = CaptureInputMode.text
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var preparedMedia: PreparedCaptureMediaSelection?
    @State private var activeImportRequestID: UUID?
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var importError: String?

    private var isSaving: Bool {
        isSubmitting || model.state.capturePhase == .saving
    }

    private var isImporting: Bool {
        activeImportRequestID != nil
    }

    private var canSave: Bool {
        switch mode {
        case .text:
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .voice:
            voiceRecorder.preparedRecordingURL != nil
        case .photo:
            preparedMedia?.kind == .imageReference
        case .file:
            preparedMedia?.kind == .fileReference
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Capture format", selection: $mode) {
                        ForEach(CaptureInputMode.allCases) { inputMode in
                            Text(inputMode.title).tag(inputMode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(
                        isSaving
                            || isImporting
                            || voiceRecorder.isRecording
                            || voiceRecorder.state == .requestingPermission
                    )
                }

                switch mode {
                case .text:
                    textSection
                case .voice:
                    voiceSection
                case .photo:
                    photoSection
                case .file:
                    fileSection
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
            .interactiveDismissDisabled(isSaving || voiceRecorder.isRecording)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle, action: save)
                        .disabled(isSaving || isImporting || !canSave)
                }
            }
            .onAppear { isFocused = true }
            .onChange(of: mode) { _, newMode in
                isFocused = newMode == .text
                resetMediaDrafts(for: newMode)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    voiceRecorder.refreshPermissionState()
                } else {
                    voiceRecorder.stopForBackgrounding()
                }
            }
            .onDisappear {
                if !isSaving {
                    discardAllDraftMedia()
                }
            }
            .sheet(isPresented: $isPhotoPickerPresented) {
                if let importBuffer = model.captureImportBuffer,
                   let requestID = activeImportRequestID
                {
                    PhotoCapturePicker(
                        importBuffer: importBuffer,
                        requestID: requestID,
                        onCompletion: finishImport
                    )
                    .ignoresSafeArea()
                } else {
                    ProgressView("Opening photo picker…")
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false,
                onCompletion: handleFileImporterResult
            )
        }
    }

    private var textSection: some View {
        Section {
            TextEditor(text: $text)
                .focused($isFocused)
                .frame(minHeight: 180)
                .accessibilityLabel("Capture text")
                .disabled(isSaving)
        } header: {
            Text("What should Odyssey remember?")
        } footer: {
            Text("Save commits the original text locally before sync or interpretation.")
        }
    }

    private var voiceSection: some View {
        Section {
            switch voiceRecorder.state {
            case .idle:
                Label("No recording yet", systemImage: "waveform")
                    .foregroundStyle(.secondary)
                Button {
                    Task { await voiceRecorder.start() }
                } label: {
                    Label("Start Recording", systemImage: "mic.fill")
                }
                .disabled(isSaving)
            case .requestingPermission:
                ProgressView("Requesting microphone access…")
            case .recording:
                Label(
                    "Recording \(voiceDuration(voiceRecorder.elapsed))",
                    systemImage: "record.circle"
                )
                .foregroundStyle(.red)
                ProgressView(
                    value: voiceRecorder.elapsed,
                    total: VoiceCaptureRecorder.maximumDuration
                )
                Button(role: .destructive) {
                    voiceRecorder.stop()
                } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                }
            case .ready:
                Label(
                    "Recording ready · \(voiceDuration(voiceRecorder.elapsed))",
                    systemImage: "checkmark.circle"
                )
                Button {
                    Task { await voiceRecorder.start() }
                } label: {
                    Label("Record Again", systemImage: "arrow.counterclockwise")
                }
                .disabled(isSaving)
            case .permissionDenied:
                Label(
                    "Microphone access is off. Odyssey records only after you grant access.",
                    systemImage: "mic.slash"
                )
                .foregroundStyle(.secondary)
                Button("Open Settings", action: openSettings)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button {
                    Task { await voiceRecorder.start() }
                } label: {
                    Label("Try Again", systemImage: "arrow.counterclockwise")
                }
                .disabled(isSaving)
            }
        } header: {
            Text("Speak a note")
        } footer: {
            Text(
                "Recording stops after five minutes or when the app leaves the foreground. "
                    + "Save copies it into protected local storage and commits its immutable "
                    + "reference. Audio remains on this device only; it is not transcribed, "
                    + "uploaded, or remotely restorable."
            )
        }
    }

    private var photoSection: some View {
        Section {
            importSelectionContent(
                expectedKind: .imageReference,
                emptyTitle: "No photo selected",
                readyTitle: "Photo ready",
                chooseTitle: "Choose Photo",
                chooseAgainTitle: "Choose Another Photo",
                systemImage: "photo",
                action: startPhotoImport
            )
        } header: {
            Text("Choose one photo")
        } footer: {
            Text(
                "Odyssey receives only the photo you choose and keeps the selected "
                    + "representation, including its embedded metadata, unchanged in "
                    + "protected local storage. Save commits an opaque reference. It is "
                    + "not uploaded, opened by interpretation, or remotely restorable."
            )
        }
    }

    private var fileSection: some View {
        Section {
            importSelectionContent(
                expectedKind: .fileReference,
                emptyTitle: "No file selected",
                readyTitle: "File ready",
                chooseTitle: "Choose File",
                chooseAgainTitle: "Choose Another File",
                systemImage: "doc",
                action: startFileImport
            )
        } header: {
            Text("Choose one file")
        } footer: {
            Text(
                "Odyssey copies only the file you choose into protected local storage and "
                    + "keeps its bytes unchanged. The manifest does not add its source name "
                    + "or provider path. Save commits an opaque reference. The file is not "
                    + "uploaded, opened by interpretation, or remotely restorable."
            )
        }
    }

    @ViewBuilder
    private func importSelectionContent(
        expectedKind: CapturePayloadKind,
        emptyTitle: String,
        readyTitle: String,
        chooseTitle: String,
        chooseAgainTitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        if isImporting {
            ProgressView("Preparing selected item…")
        } else if let preparedMedia, preparedMedia.kind == expectedKind {
            Label(
                "\(readyTitle) · \(formattedByteCount(preparedMedia.preparedImport.byteCount))",
                systemImage: "checkmark.circle"
            )
            Text(preparedMedia.mediaType)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(chooseAgainTitle, action: action)
                .disabled(isSaving)
        } else {
            Label(emptyTitle, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Button(chooseTitle, action: action)
                .disabled(isSaving)
        }
        if let importError {
            Label(importError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var saveButtonTitle: String {
        if isSaving {
            return "Saving…"
        }
        switch mode {
        case .text:
            return "Save"
        case .voice:
            return "Save Voice"
        case .photo:
            return "Save Photo"
        case .file:
            return "Save File"
        }
    }

    private func save() {
        guard !isSaving, canSave else { return }
        isSubmitting = true
        isFocused = false
        let selectedMode = mode
        let selectedText = text
        let selectedVoiceURL = voiceRecorder.preparedRecordingURL
        let selectedMedia = preparedMedia
        Task {
            let saved: Bool
            switch selectedMode {
            case .text:
                saved = await model.captureText(selectedText)
            case .voice:
                guard let selectedVoiceURL else {
                    isSubmitting = false
                    return
                }
                saved = await model.captureVoiceRecording(at: selectedVoiceURL)
            case .photo:
                guard let selectedMedia,
                      selectedMedia.kind == .imageReference
                else {
                    isSubmitting = false
                    return
                }
                saved = await model.captureImportedMedia(
                    at: selectedMedia.preparedImport.fileURL,
                    kind: selectedMedia.kind,
                    mediaType: selectedMedia.mediaType
                )
            case .file:
                guard let selectedMedia,
                      selectedMedia.kind == .fileReference
                else {
                    isSubmitting = false
                    return
                }
                saved = await model.captureImportedMedia(
                    at: selectedMedia.preparedImport.fileURL,
                    kind: selectedMedia.kind,
                    mediaType: selectedMedia.mediaType
                )
            }
            guard saved else {
                isSubmitting = false
                return
            }
            voiceRecorder.completeSave()
            discardPreparedMedia(selectedMedia)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        }
    }

    private func cancel() {
        discardAllDraftMedia()
        dismiss()
    }

    private func startPhotoImport() {
        guard activeImportRequestID == nil, !isSaving else { return }
        guard model.captureImportBuffer != nil else {
            importError = "Protected local import storage is unavailable."
            return
        }
        activeImportRequestID = UUID()
        importError = nil
        isPhotoPickerPresented = true
    }

    private func startFileImport() {
        guard activeImportRequestID == nil, !isSaving else { return }
        guard model.captureImportBuffer != nil else {
            importError = "Protected local import storage is unavailable."
            return
        }
        activeImportRequestID = UUID()
        importError = nil
        isFileImporterPresented = true
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        guard let requestID = activeImportRequestID,
              let importBuffer = model.captureImportBuffer
        else { return }
        switch result {
        case let .success(urls):
            guard let sourceURL = urls.first else {
                finishImport(requestID, .cancelled)
                return
            }
            Task {
                let outcome = await Task.detached {
                    CaptureMediaImportPreparer.prepare(
                        sourceURL: sourceURL,
                        kind: .fileReference,
                        importBuffer: importBuffer
                    )
                }.value
                finishImport(requestID, outcome)
            }
        case let .failure(error):
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSUserCancelledError
            {
                finishImport(requestID, .cancelled)
            } else {
                finishImport(requestID, .failed("The selected file could not be opened."))
            }
        }
    }

    private func finishImport(_ requestID: UUID, _ outcome: CaptureMediaImportOutcome) {
        guard activeImportRequestID == requestID else {
            if case let .selected(selection) = outcome {
                discardPreparedMedia(selection)
            }
            return
        }
        isPhotoPickerPresented = false
        isFileImporterPresented = false
        activeImportRequestID = nil
        switch outcome {
        case let .selected(selection):
            discardPreparedMedia(preparedMedia)
            preparedMedia = selection
            importError = nil
        case .cancelled:
            importError = nil
        case let .failed(message):
            importError = message
        }
    }

    private func resetMediaDrafts(for newMode: CaptureInputMode) {
        importError = nil
        if newMode != .voice {
            voiceRecorder.cancel()
        }
        guard let preparedMedia else { return }
        let keepsSelection = switch newMode {
        case .photo:
            preparedMedia.kind == .imageReference
        case .file:
            preparedMedia.kind == .fileReference
        case .text, .voice:
            false
        }
        if !keepsSelection {
            discardPreparedMedia(preparedMedia)
            self.preparedMedia = nil
        }
    }

    private func discardAllDraftMedia() {
        activeImportRequestID = nil
        isPhotoPickerPresented = false
        isFileImporterPresented = false
        voiceRecorder.cancel()
        discardPreparedMedia(preparedMedia)
        preparedMedia = nil
    }

    private func discardPreparedMedia(_ selection: PreparedCaptureMediaSelection?) {
        guard let selection, let importBuffer = model.captureImportBuffer else { return }
        try? importBuffer.discard(selection.preparedImport)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func voiceDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
