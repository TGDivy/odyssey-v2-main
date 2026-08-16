import Foundation
import OdysseyApplication
import OdysseyAuth
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let mediaCaptureDate = Date(timeIntervalSince1970: 1_735_689_600)

@Test
func mediaCaptureCopiesContentBeforeOneDurableCaptureCommit() async throws {
    let directory = mediaCaptureTemporaryDirectory("commit")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceURL = directory.appendingPathComponent("recording.m4a")
    let sourceData = Data("synthetic recorded audio".utf8)
    try sourceData.write(to: sourceURL)
    let deviceID = try mediaCaptureIdentifier(1)
    let ledgerStore = try SQLiteLedgerStore(
        configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: deviceID,
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { mediaCaptureDate }
        )
    )
    let captureIdentifiers = MediaCaptureIdentifiers(startingAt: 100)
    let captureService = try ManualCaptureService(
        store: ledgerStore,
        deviceID: deviceID,
        clock: { mediaCaptureDate },
        identifier: { captureIdentifiers.next() }
    )
    let attachmentStore = try LocalCaptureAttachmentStore(
        configuration: LocalCaptureAttachmentStoreConfiguration(
            rootDirectory: directory.appendingPathComponent("Attachments")
        ),
        clock: { mediaCaptureDate },
        identifier: { try! mediaCaptureIdentifier(2) }
    )
    let service = LocalMediaCaptureService(
        attachmentStore: attachmentStore,
        captureService: captureService
    )

    let receipt = try await service.record(LocalMediaCaptureDraft(
        source: .file(sourceURL),
        kind: .audio,
        mediaType: "audio/mp4",
        timeZoneID: "UTC",
        locationPermissionState: .denied,
        invokingSurface: .iPhoneGlobalCapture
    ))
    try FileManager.default.removeItem(at: sourceURL)

    let capture = receipt.captureReceipt.capture
    let reference = try receipt.attachment.captureReference
    #expect(receipt.finalizationState == .committed)
    #expect(receipt.attachment.state == .committed)
    #expect(capture.originalPayload.kind == .audio)
    #expect(capture.originalPayload.contentOrObjectRef == receipt.attachment.objectReference)
    #expect(
        capture.originalPayload.contentHash
            == SHA256Digest.hexDigest(of: Data(receipt.attachment.objectReference.utf8))
    )
    #expect(capture.attachments == [reference])
    #expect(capture.interpretationStatus == .pending)
    #expect(capture.interpretationVersions.isEmpty)
    let contentURL = try await attachmentStore.verifiedContentURL(for: reference)
    #expect(try Data(contentsOf: contentURL) == sourceData)
    let diagnostics = try await ledgerStore.localSyncDiagnostics()
    #expect(diagnostics.operationsQueued == 1)

    let interpretation = try await CaptureInterpretationService(store: ledgerStore).interpret(
        captureID: capture.metadata.id,
        using: DeterministicCaptureInterpreter()
    )
    #expect(interpretation == .deferred(.mediaContentUnavailable))
    let projected = try ledgerStore.projectedEntity(
        entityType: ManualCaptureService.entityType,
        entityID: capture.metadata.id
    )
    let unchanged = try #require(projected)
    #expect(unchanged.revision == 1)
}

@Test
func mediaCaptureFailureDiscardsUnreferencedStaging() async throws {
    let directory = mediaCaptureTemporaryDirectory("rollback")
    defer { try? FileManager.default.removeItem(at: directory) }
    let deviceID = try mediaCaptureIdentifier(10)
    let ledgerStore = try SQLiteLedgerStore(
        configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: deviceID,
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { mediaCaptureDate }
        )
    )
    let captureService = try ManualCaptureService(
        store: ledgerStore,
        deviceID: deviceID,
        clock: { Date(timeIntervalSinceReferenceDate: .nan) }
    )
    let attachmentStore = try LocalCaptureAttachmentStore(
        configuration: LocalCaptureAttachmentStoreConfiguration(
            rootDirectory: directory.appendingPathComponent("Attachments")
        ),
        clock: { mediaCaptureDate },
        identifier: { try! mediaCaptureIdentifier(11) }
    )
    let service = LocalMediaCaptureService(
        attachmentStore: attachmentStore,
        captureService: captureService
    )
    let draft = try LocalMediaCaptureDraft(
        source: .data(Data("temporary audio".utf8)),
        kind: .audio,
        mediaType: "audio/mp4",
        timeZoneID: "UTC",
        locationPermissionState: .unavailable,
        invokingSurface: .iPhoneGlobalCapture
    )

    await #expect(throws: ManualCaptureError.invalidClock) {
        try await service.record(draft)
    }
    #expect(try await attachmentStore.manifests().isEmpty)
    #expect(try await ledgerStore.localSyncDiagnostics().operationsQueued == 0)
}

@Test
func nativeBootstrapReconcilesInterruptedMediaCaptureHandoff() async throws {
    let directory = mediaCaptureTemporaryDirectory("bootstrap-recovery")
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try NativeLocalConfiguration(
        applicationIdentifier: "com.example.odyssey.app",
        applicationSupportDirectory: directory
    )
    let deviceID = try mediaCaptureIdentifier(20)
    let interrupted = try await seedInterruptedMediaCapture(
        configuration: configuration,
        deviceID: deviceID
    )

    let services = try await NativeLocalServices.bootstrap(
        configuration: configuration,
        vault: MediaCaptureMemoryVault(deviceID: deviceID)
    )
    guard case let .completed(report) = services.attachmentRecoveryState else {
        Issue.record("Expected attachment recovery to complete")
        return
    }
    #expect(report.stagedAttachmentsCommitted == 1)
    #expect(report.stagedAttachmentsAwaitingReview == 1)
    #expect(report.missingReferencedAttachments == 0)
    #expect(
        try await services.captureAttachmentStore.manifest(
            for: interrupted.referencedAttachmentID
        ).state == .committed
    )
    #expect(
        try await services.captureAttachmentStore.manifest(
            for: interrupted.abandonedAttachmentID
        ).state == .staged
    )
    #expect(try await services.localDiagnostics().attachmentBacklog == 1)
    #expect(try services.recentCaptures().count == 1)
}

private struct InterruptedMediaCapture {
    let referencedAttachmentID: UUIDv7
    let abandonedAttachmentID: UUIDv7
}

private func seedInterruptedMediaCapture(
    configuration: NativeLocalConfiguration,
    deviceID: UUIDv7
) async throws -> InterruptedMediaCapture {
    let ledgerStore = try SQLiteLedgerStore(
        configuration: SQLiteLedgerConfiguration(
            databaseURL: configuration.databaseURL,
            deviceID: deviceID,
            preMigrationBackupDirectory: configuration.preMigrationBackupDirectory,
            clock: { mediaCaptureDate }
        )
    )
    let captureService = try ManualCaptureService(
        store: ledgerStore,
        deviceID: deviceID,
        clock: { mediaCaptureDate }
    )
    let identifiers = MediaCaptureIdentifiers(startingAt: 30)
    let attachmentStore = try LocalCaptureAttachmentStore(
        configuration: LocalCaptureAttachmentStoreConfiguration(
            rootDirectory: configuration.attachmentDirectory
        ),
        clock: { mediaCaptureDate },
        identifier: { identifiers.next() }
    )
    let referenced = try await attachmentStore.stageData(
        Data("referenced interrupted audio".utf8),
        kind: .audio,
        mediaType: "audio/mp4"
    )
    let abandoned = try await attachmentStore.stageData(
        Data("abandoned interrupted audio".utf8),
        kind: .audio,
        mediaType: "audio/mp4"
    )
    _ = try await captureService.record(ManualCaptureDraft(
        kind: .audio,
        contentOrObjectReference: referenced.objectReference,
        timeZoneID: "UTC",
        locationPermissionState: .unavailable,
        invokingSurface: .iPhoneGlobalCapture,
        attachments: [referenced.captureReference]
    ))
    return InterruptedMediaCapture(
        referencedAttachmentID: referenced.attachmentID,
        abandonedAttachmentID: abandoned.attachmentID
    )
}

private func mediaCaptureTemporaryDirectory(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-media-capture-\(suffix)-\(UUID().uuidString)",
        isDirectory: true
    )
}

private func mediaCaptureIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}

private final class MediaCaptureIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(startingAt value: Int) {
        self.value = value
    }

    func next() -> UUIDv7 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return try! mediaCaptureIdentifier(value)
    }
}

private actor MediaCaptureMemoryVault: CredentialVault {
    private let deviceID: UUIDv7

    init(deviceID: UUIDv7) {
        self.deviceID = deviceID
    }

    func loadOrCreateDeviceID() async throws -> UUIDv7 { deviceID }

    func storeRefreshCredential(_: StoredRefreshCredential) async throws {}

    func refreshCredential() async throws -> StoredRefreshCredential? { nil }

    func clearRefreshCredential() async throws {}

    func clearAll() async throws {}
}
