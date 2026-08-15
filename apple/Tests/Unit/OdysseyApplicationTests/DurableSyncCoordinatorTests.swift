import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let coordinatorFixtureDate = Date(timeIntervalSince1970: 1_720_000_000)

@Test
func coordinatorCoalescesPushThenResumablePullAndPersistsEveryPage() async throws {
    let fixture = try CoordinatorStoreFixture()
    defer { fixture.remove() }
    let capture = try await fixture.capture("local")
    let initialPending = try await fixture.store.pendingSyncOperations()
    let pending = try #require(initialPending.first)
    let localPayload = try SyncJSONCoding.makeDecoder().decode(
        [String: JSONValue].self,
        from: pending.payload
    )
    let remoteEntityID = try coordinatorIdentifier(20)
    let remoteOperationID = try coordinatorIdentifier(21)
    let remoteDeviceID = try coordinatorIdentifier(22)
    let transport = ScriptedSyncTransport(
        pushResponses: [
            SyncPushResponse(
                accepted: [
                    AcceptedOperation(
                        operationID: pending.operationID,
                        canonicalRevision: 1,
                        serverChangeID: 1,
                        mergeResult: "created"
                    ),
                ],
                nextCursor: try SyncCursor(value: 1),
                serverTime: coordinatorFixtureDate.addingTimeInterval(1),
                serverSchemaVersion: 1,
                minimumClientSchemaVersion: 1
            ),
        ],
        pullResponses: [
            SyncPullResponse(
                changes: [
                    SyncChange(
                        changeID: 1,
                        canonicalRevision: 1,
                        entityType: "capture",
                        entityID: capture.capture.metadata.id,
                        mutationType: .create,
                        payload: localPayload,
                        tombstone: false,
                        deletionEpoch: nil,
                        mergeResult: "created",
                        originDeviceID: fixture.deviceID,
                        originOperationID: pending.operationID,
                        serverReceivedAt: coordinatorFixtureDate.addingTimeInterval(1)
                    ),
                ],
                nextCursor: try SyncCursor(value: 1),
                hasMore: true,
                serverTime: coordinatorFixtureDate.addingTimeInterval(2),
                serverSchemaVersion: 1,
                minimumClientSchemaVersion: 1
            ),
            SyncPullResponse(
                changes: [
                    SyncChange(
                        changeID: 2,
                        canonicalRevision: 1,
                        entityType: "capture",
                        entityID: remoteEntityID,
                        mutationType: .create,
                        payload: ["text": .string("other device")],
                        tombstone: false,
                        deletionEpoch: nil,
                        mergeResult: "created",
                        originDeviceID: remoteDeviceID,
                        originOperationID: remoteOperationID,
                        serverReceivedAt: coordinatorFixtureDate.addingTimeInterval(2)
                    ),
                ],
                nextCursor: try SyncCursor(value: 2),
                hasMore: false,
                serverTime: coordinatorFixtureDate.addingTimeInterval(3),
                serverSchemaVersion: 1,
                minimumClientSchemaVersion: 1
            ),
        ],
        pushDelayNanoseconds: 30_000_000
    )
    let coordinator = try DurableSyncCoordinator(
        store: fixture.store,
        transport: transport,
        clock: { coordinatorFixtureDate.addingTimeInterval(10) }
    )

    async let first = coordinator.synchronize()
    async let second = coordinator.synchronize()
    let firstReport = try await first
    let secondReport = try await second

    #expect(firstReport == secondReport)
    #expect(firstReport.pushedOperationCount == 1)
    #expect(firstReport.pulledChangeCount == 2)
    let expectedFinalCursor = try SyncCursor(value: 2)
    #expect(firstReport.finalCursor == expectedFinalCursor)
    #expect(await transport.calls() == ["push:c_0", "pull:c_0", "pull:c_1"])
    #expect(await transport.pushCount() == 1)
    let keys = await transport.idempotencyKeys()
    #expect(keys.count == 1)
    #expect(keys[0].hasPrefix("sync-v1-"))
    #expect(keys[0].count == 72)

    let state = try await fixture.store.syncState()
    let localDiagnostics = try await fixture.store.localSyncDiagnostics()
    let receipts = try await fixture.store.remoteChangeReceipts(limit: 10)
    #expect(state.cursor == "c_2")
    #expect(state.serverCursor == "c_2")
    #expect(localDiagnostics.operationsQueued == 0)
    #expect(receipts.map(\.applicationKind) == [.localReconciliation, .remoteCommit])
    let remoteProjection = try fixture.store.projectedEntity(
        entityType: "capture",
        entityID: remoteEntityID
    )
    #expect(remoteProjection != nil)

    let nativeDiagnostics = try await coordinator.localDiagnostics()
    #expect(nativeDiagnostics.schemaCompatibility == .compatible)
    #expect(nativeDiagnostics.deviceCursor.value == 2)
    #expect(nativeDiagnostics.conflictCount == 0)
}

@Test
func coordinatorSchedulesRetryWithoutPersistingPrivateServerMessage() async throws {
    let fixture = try CoordinatorStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.capture("retry me")
    let initialPending = try await fixture.store.pendingSyncOperations()
    let pending = try #require(initialPending.first)
    let transport = ScriptedSyncTransport(
        pushResponses: [
            SyncPushResponse(
                rejected: [
                    RejectedOperation(
                        operationID: pending.operationID,
                        code: "temporarily_unavailable",
                        message: "private payload must not be retained",
                        retryable: true
                    ),
                ],
                nextCursor: try SyncCursor(value: 0),
                serverTime: coordinatorFixtureDate.addingTimeInterval(1),
                serverSchemaVersion: 1,
                minimumClientSchemaVersion: 1
            ),
        ],
        pullResponses: [emptyPullResponse()]
    )
    let coordinator = try DurableSyncCoordinator(
        store: fixture.store,
        transport: transport,
        configuration: DurableSyncCoordinatorConfiguration(
            retryBaseDelay: 60,
            retryMaximumDelay: 600
        ),
        clock: { coordinatorFixtureDate }
    )

    let report = try await coordinator.synchronize()

    #expect(report.pushedOperationCount == 1)
    let notReady = try await fixture.store.pendingSyncOperations(
        readyAt: coordinatorFixtureDate
    )
    #expect(notReady.isEmpty)
    let ready = try await fixture.store.pendingSyncOperations(
        readyAt: coordinatorFixtureDate.addingTimeInterval(60)
    )
    let retry = try #require(ready.first)
    #expect(retry.attemptCount == 1)
    #expect(retry.nextAttemptAt == coordinatorFixtureDate.addingTimeInterval(60))
    #expect(retry.lastError == "The server rejected this operation.")
    #expect(retry.lastError?.contains("private payload") == false)
}

@Test
func coordinatorRejectsIncompletePushResultsBeforeMutatingDurableState() async throws {
    let fixture = try CoordinatorStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.capture("must remain queued")
    let transport = ScriptedSyncTransport(
        pushResponses: [
            SyncPushResponse(
                nextCursor: try SyncCursor(value: 0),
                serverTime: coordinatorFixtureDate,
                serverSchemaVersion: 1,
                minimumClientSchemaVersion: 1
            ),
        ],
        pullResponses: []
    )
    let coordinator = try DurableSyncCoordinator(
        store: fixture.store,
        transport: transport,
        clock: { coordinatorFixtureDate }
    )

    await #expect(throws: DurableSyncCoordinatorError.invalidPushResponse(
        "Every pushed operation must receive exactly one result."
    )) {
        try await coordinator.synchronize()
    }

    let state = try await fixture.store.syncState()
    let pending = try await fixture.store.pendingSyncOperations()
    #expect(state.lastSuccessfulPushAt == nil)
    #expect(pending.count == 1)
    #expect(await transport.calls() == ["push:c_0"])
}

@Test
func coordinatorRejectsNonadvancingResumablePageBeforeApplyingIt() async throws {
    let fixture = try CoordinatorStoreFixture()
    defer { fixture.remove() }
    let transport = ScriptedSyncTransport(
        pushResponses: [],
        pullResponses: [
            SyncPullResponse(
                changes: [],
                nextCursor: try SyncCursor(value: 0),
                hasMore: true,
                serverTime: coordinatorFixtureDate,
                serverSchemaVersion: 1,
                minimumClientSchemaVersion: 1
            ),
        ]
    )
    let coordinator = try DurableSyncCoordinator(
        store: fixture.store,
        transport: transport,
        clock: { coordinatorFixtureDate }
    )

    await #expect(throws: DurableSyncCoordinatorError.invalidPullResponse(
        "A resumable pull page must advance its cursor when more data remains."
    )) {
        try await coordinator.synchronize()
    }

    let state = try await fixture.store.syncState()
    #expect(state.lastSuccessfulPullAt == nil)
}

@Test
func coordinatorFailsClosedWhenServerRequiresANewerClientSchema() async throws {
    let fixture = try CoordinatorStoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.capture("wait for an app upgrade")
    let transport = ScriptedSyncTransport(
        pushResponses: [
            SyncPushResponse(
                nextCursor: try SyncCursor(value: 0),
                serverTime: coordinatorFixtureDate,
                serverSchemaVersion: 2,
                minimumClientSchemaVersion: 2
            ),
        ],
        pullResponses: []
    )
    let coordinator = try DurableSyncCoordinator(
        store: fixture.store,
        transport: transport,
        clock: { coordinatorFixtureDate }
    )

    await #expect(throws: DurableSyncCoordinatorError.clientUpgradeRequired(
        minimumVersion: 2,
        currentVersion: 1
    )) {
        try await coordinator.synchronize()
    }

    let diagnostics = try await coordinator.localDiagnostics()
    let pending = try await fixture.store.pendingSyncOperations()
    #expect(diagnostics.schemaCompatibility == .clientUpgradeRequired)
    #expect(pending.count == 1)
}

private final class CoordinatorStoreFixture: @unchecked Sendable {
    let directory: URL
    let deviceID: UUIDv7
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-sync-coordinator-\(UUID().uuidString)",
            isDirectory: true
        )
        deviceID = try coordinatorIdentifier(1)
        store = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: directory.appendingPathComponent("ledger.sqlite"),
                deviceID: deviceID,
                preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
                clock: { coordinatorFixtureDate }
            )
        )
    }

    func capture(_ text: String) async throws -> ManualCaptureReceipt {
        let service = try ManualCaptureService(
            store: store,
            deviceID: deviceID,
            clock: { coordinatorFixtureDate }
        )
        return try await service.record(
            .text(
                text,
                timeZoneID: "UTC",
                locationPermissionState: .notDetermined,
                invokingSurface: .iPhoneNow
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ScriptedSyncTransport: SyncTransport {
    private var pushResponses: [SyncPushResponse]
    private var pullResponses: [SyncPullResponse]
    private let pushDelayNanoseconds: UInt64
    private var recordedCalls: [String] = []
    private var recordedIdempotencyKeys: [String] = []

    init(
        pushResponses: [SyncPushResponse],
        pullResponses: [SyncPullResponse],
        pushDelayNanoseconds: UInt64 = 0
    ) {
        self.pushResponses = pushResponses
        self.pullResponses = pullResponses
        self.pushDelayNanoseconds = pushDelayNanoseconds
    }

    func push(
        _ request: SyncPushRequest,
        batchIdempotencyKey: String
    ) async throws -> SyncPushResponse {
        recordedCalls.append("push:\(request.baseCursor)")
        recordedIdempotencyKeys.append(batchIdempotencyKey)
        if pushDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: pushDelayNanoseconds)
        }
        guard !pushResponses.isEmpty else {
            throw CoordinatorFixtureError.unscriptedCall
        }
        return pushResponses.removeFirst()
    }

    func pull(
        after cursor: SyncCursor,
        limit: Int,
        deviceID: UUIDv7
    ) async throws -> SyncPullResponse {
        recordedCalls.append("pull:\(cursor)")
        guard !pullResponses.isEmpty else {
            throw CoordinatorFixtureError.unscriptedCall
        }
        return pullResponses.removeFirst()
    }

    func reportDiagnostics(
        deviceID: UUIDv7,
        diagnostics: SyncDeviceDiagnosticsInput
    ) async throws -> SyncDeviceDiagnostics {
        throw CoordinatorFixtureError.unscriptedCall
    }

    func diagnostics() async throws -> SyncDiagnosticsResponse {
        throw CoordinatorFixtureError.unscriptedCall
    }

    func conflicts(
        status: SyncConflictStatusFilter,
        limit: Int
    ) async throws -> SyncConflictListResponse {
        throw CoordinatorFixtureError.unscriptedCall
    }

    func resolveConflict(
        conflictID: UUIDv7,
        request: SyncConflictResolutionRequest
    ) async throws -> SyncConflictResolutionResponse {
        throw CoordinatorFixtureError.unscriptedCall
    }

    func calls() -> [String] {
        recordedCalls
    }

    func pushCount() -> Int {
        recordedIdempotencyKeys.count
    }

    func idempotencyKeys() -> [String] {
        recordedIdempotencyKeys
    }
}

private enum CoordinatorFixtureError: Error {
    case unscriptedCall
}

private func emptyPullResponse() -> SyncPullResponse {
    SyncPullResponse(
        changes: [],
        nextCursor: try! SyncCursor(value: 0),
        hasMore: false,
        serverTime: coordinatorFixtureDate.addingTimeInterval(2),
        serverSchemaVersion: 1,
        minimumClientSchemaVersion: 1
    )
}

private func coordinatorIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
