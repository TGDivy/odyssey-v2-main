import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let captureFixtureDate = Date(timeIntervalSince1970: 1_710_000_000)

@Test
func manualCaptureWritesImmutableEventProjectionAndOutboxAtomically() async throws {
    let deviceID = try captureIdentifier(1)
    let store = RecordingLedgerStore(deviceID: deviceID)
    let service = try ManualCaptureService(
        store: store,
        deviceID: deviceID,
        clock: { captureFixtureDate },
        identifier: SequentialCaptureIdentifiers().next,
        provenanceIdentifier: { UUID(uuidString: "10000000-0000-4000-8000-000000000001")! }
    )
    let originalText = "  Keep the original spacing.  "

    let receipt = try await service.record(
        .text(
            originalText,
            timeZoneID: "Europe/London",
            locationPermissionState: .denied,
            broadLocation: "office",
            invokingSurface: .iPhoneNow
        )
    )

    let commit = try #require(await store.recordedCommit())
    #expect(commit.entry.eventType == "capture.recorded.v1")
    #expect(commit.entry.aggregateType == "capture")
    #expect(commit.entry.aggregateID == receipt.capture.metadata.id)
    #expect(commit.projection?.document == commit.entry.payload)
    #expect(commit.syncMutation?.payload == commit.entry.payload)
    #expect(commit.syncMutation?.operationID == receipt.operationID)
    #expect(receipt.deviceSequence == 1)

    let decoded = try SyncJSONCoding.makeDecoder().decode(
        CaptureRecord.self,
        from: commit.entry.payload
    )
    #expect(decoded.originalPayload.contentOrObjectRef == originalText)
    #expect(decoded.originalPayload.contentHash == SHA256Digest.hexDigest(of: Data(originalText.utf8)))
    #expect(decoded.initialContext.deviceID == deviceID)
    #expect(decoded.initialContext.locationPermissionState == .denied)
    #expect(decoded.interpretationStatus == .pending)
    #expect(decoded.interpretationVersions.isEmpty)
    let serializedPayload = try JSONSerialization.jsonObject(with: commit.entry.payload)
    let payloadObject = try #require(serializedPayload as? [String: Any])
    let initialContext = try #require(payloadObject["initial_context"] as? [String: Any])
    #expect(initialContext["invoking_surface"] as? String == "iphone.now")
}

@Test
func manualCapturePreservesOccurrenceTimeBeforeDurableCommit() async throws {
    let deviceID = try captureIdentifier(20)
    let store = RecordingLedgerStore(deviceID: deviceID)
    let service = try ManualCaptureService(
        store: store,
        deviceID: deviceID,
        clock: { captureFixtureDate },
        identifier: SequentialCaptureIdentifiers().next,
        provenanceIdentifier: { UUID(uuidString: "10000000-0000-4000-8000-000000000020")! }
    )
    let occurredAt = captureFixtureDate.addingTimeInterval(-120)

    let receipt = try await service.record(
        .text(
            "Queued while the app was closed",
            capturedAt: occurredAt,
            timeZoneID: "UTC",
            locationPermissionState: .unavailable,
            invokingSurface: .appIntent
        )
    )

    let commit = try #require(await store.recordedCommit())
    #expect(receipt.capture.capturedAt == occurredAt)
    #expect(receipt.capture.metadata.createdAt == captureFixtureDate)
    #expect(commit.entry.occurredAt == occurredAt)
    #expect(commit.entry.recordedAt == captureFixtureDate)
    #expect(commit.syncMutation?.createdAt == captureFixtureDate)
}

@Test
func manualCaptureRejectsEmptyAndOperationalSecretPayloads() throws {
    #expect(throws: CaptureContractError.emptyPayload) {
        try ManualCaptureDraft.text(
            "   \n",
            timeZoneID: "UTC",
            locationPermissionState: .unavailable,
            invokingSurface: .iPhoneGlobalCapture
        )
    }
    #expect(throws: CaptureContractError.invalidContext("sensitivity")) {
        try ManualCaptureDraft.text(
            "credential material",
            timeZoneID: "UTC",
            locationPermissionState: .unavailable,
            invokingSurface: .iPhoneGlobalCapture,
            sensitivity: .operationalSecret
        )
    }
}

@Test
func manualCapturePersistsThroughSQLiteBeforeReturning() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("odyssey-capture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let deviceID = try captureIdentifier(50)
    let store = try SQLiteLedgerStore(
        configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: deviceID,
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { captureFixtureDate }
        )
    )
    let service = try ManualCaptureService(
        store: store,
        deviceID: deviceID,
        clock: { captureFixtureDate }
    )

    let receipt = try await service.record(
        .text(
            "Offline capture",
            timeZoneID: "UTC",
            locationPermissionState: .notDetermined,
            invokingSurface: .iPhoneNow
        )
    )

    let entries = try store.storedEntries()
    let storedProjection = try store.projectedEntity(
        entityType: "capture",
        entityID: receipt.capture.metadata.id
    )
    let projection = try #require(storedProjection)
    let pending = try await store.pendingSyncOperations()
    #expect(entries.count == 1)
    #expect(projection.document == entries[0].entry.payload)
    #expect(pending.count == 1)
    #expect(pending[0].operationID == receipt.operationID)
}

private actor RecordingLedgerStore: LedgerStore {
    private let deviceID: UUIDv7
    private var commitValue: LedgerCommit?

    init(deviceID: UUIDv7) {
        self.deviceID = deviceID
    }

    func append(_ entry: LedgerEntry) async throws {
        _ = try await commit(LedgerCommit(entry: entry))
    }

    func commit(_ commit: LedgerCommit) async throws -> LedgerCommitReceipt {
        commitValue = commit
        let queued = commit.syncMutation.map {
            PendingSyncOperation(
                operationID: $0.operationID,
                deviceSequence: 1,
                entityType: $0.entityType,
                entityID: $0.entityID,
                mutationType: $0.mutationType,
                baseRevision: $0.baseRevision,
                payload: $0.payload,
                payloadSHA256: SHA256Digest.hexDigest(of: $0.payload),
                createdAt: $0.createdAt,
                idempotencyKey: $0.idempotencyKey,
                sensitivityClass: $0.sensitivityClass,
                sourceEventID: commit.entry.eventID,
                status: .pending,
                attemptCount: 0,
                nextAttemptAt: nil,
                lastError: nil
            )
        }
        return LedgerCommitReceipt(localSequence: 1, queuedOperation: queued)
    }

    func entries(after eventID: UUIDv7?, limit: Int) async throws -> [LedgerEntry] {
        commitValue.map(\.entry).map { [$0] } ?? []
    }

    func recordedCommit() -> LedgerCommit? {
        commitValue
    }
}

private final class SequentialCaptureIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100

    func next() -> UUIDv7 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return try! captureIdentifier(value)
    }
}

private func captureIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
