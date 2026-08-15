import Foundation
@testable import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let acceptanceCoordinatorDate = Date(timeIntervalSince1970: 1_786_752_000.125)
private let acceptancePolicyVersion = "life-model-acceptance-policy-1.0"

@Test
func acceptanceCoordinatorCoalescesSequentialDeliveryAndCachesHistory() async throws {
    let fixture = try AcceptanceCoordinatorFixture()
    defer { fixture.remove() }
    let command = try fixture.command(index: 1, kind: .charter)
    _ = try fixture.store.enqueueLifeModelAcceptance(command)
    let envelope = try fixture.envelope(for: command, acceptanceSequence: 1)
    let transport = ScriptedLifeModelTransport(
        submissions: [command.eventID: .receipt(fixture.receipt(envelope))],
        histories: [
            .charter: LifeModelHistoryResponse(
                kind: .charter,
                versions: [envelope],
                policyVersion: acceptancePolicyVersion
            ),
            .lifeStage: LifeModelHistoryResponse(
                kind: .lifeStage,
                versions: [],
                policyVersion: acceptancePolicyVersion
            ),
            .season: LifeModelHistoryResponse(
                kind: .season,
                versions: [],
                policyVersion: acceptancePolicyVersion
            ),
        ],
        submitDelayNanoseconds: 30_000_000
    )
    let coordinator = try LifeModelAcceptanceCoordinator(
        store: fixture.store,
        transport: transport,
        clock: { acceptanceCoordinatorDate.addingTimeInterval(5) }
    )

    async let first = coordinator.synchronize()
    async let second = coordinator.synchronize()
    let firstReport = try await first
    let secondReport = try await second

    #expect(firstReport == secondReport)
    #expect(firstReport.attemptedCount == 1)
    #expect(firstReport.acceptedCount == 1)
    #expect(firstReport.cachedHistoryVersionCount == 1)
    #expect(firstReport.failedHistoryKinds.isEmpty)
    #expect(await transport.submissionCount() == 1)
    #expect(await transport.historyKinds() == LifeModelKind.allCases)
    let stored = try #require(fixture.store.lifeModelAcceptances().first)
    #expect(stored.deliveryStatus == .accepted)
    #expect(stored.lastErrorMessage == nil)
    #expect(
        try fixture.store.cachedLifeModelVersions(kind: .charter).map(\.versionID)
            == [command.versionID]
    )
}

@Test
func acceptanceCoordinatorRecordsConflictWithCurrentOrientationAndRedactedMessage() async throws {
    let fixture = try AcceptanceCoordinatorFixture()
    defer { fixture.remove() }
    let command = try fixture.command(index: 10, kind: .season)
    _ = try fixture.store.enqueueLifeModelAcceptance(command)
    let currentCommand = try fixture.command(index: 11, kind: .season)
    let current = try fixture.envelope(
        for: currentCommand,
        acceptanceSequence: 4,
        status: "active"
    )
    let privateServerMessage = "The owner named Synthetic Person changed a private value."
    let error = APIErrorBody(
        code: "LIFE_MODEL_CURRENT_VERSION_CONFLICT",
        message: privateServerMessage,
        retryable: false,
        correlationID: "correlation-private"
    )
    let transport = ScriptedLifeModelTransport(
        submissions: [command.eventID: .failure(.api(statusCode: 409, error: error))],
        orientationResponse: CurrentOrientationResponse(
            asOf: acceptanceCoordinatorDate,
            charter: nil,
            lifeStage: nil,
            season: current,
            policyVersion: acceptancePolicyVersion
        ),
        histories: fixture.emptyHistories()
    )
    let coordinator = try LifeModelAcceptanceCoordinator(
        store: fixture.store,
        transport: transport,
        clock: { acceptanceCoordinatorDate.addingTimeInterval(10) }
    )

    let report = try await coordinator.synchronize()

    #expect(report.conflictCount == 1)
    #expect(report.orientationRefreshFailureCount == 0)
    #expect(await transport.orientationCount() == 1)
    let stored = try #require(fixture.store.lifeModelAcceptances().first)
    #expect(stored.deliveryStatus == .conflict)
    #expect(stored.actualCurrentVersionID == current.versionID)
    #expect(stored.lastErrorCode == "LIFE_MODEL_CURRENT_VERSION_CONFLICT")
    #expect(stored.lastErrorMessage == "The accepted current version changed and requires owner review.")
    #expect(stored.lastErrorMessage?.contains(privateServerMessage) == false)
    #expect(
        try fixture.store.cachedLifeModelVersions(kind: .season).map(\.versionID)
            == [current.versionID]
    )
}

@Test
func acceptanceCoordinatorBoundsRetriesAndRejectsNonretryableFailures() async throws {
    let fixture = try AcceptanceCoordinatorFixture()
    defer { fixture.remove() }
    let retryCommand = try fixture.command(index: 20, kind: .lifeStage)
    let rejectedCommand = try fixture.command(index: 21, kind: .charter)
    _ = try fixture.store.enqueueLifeModelAcceptance(retryCommand)
    _ = try fixture.store.enqueueLifeModelAcceptance(rejectedCommand)
    try fixture.store.recordLifeModelRetry(
        eventID: retryCommand.eventID,
        errorCode: "NETWORK",
        message: "Synthetic prior retry.",
        nextAttemptAt: acceptanceCoordinatorDate,
        updatedAt: acceptanceCoordinatorDate.addingTimeInterval(-1)
    )
    let rejection = APIErrorBody(
        code: "REQUEST_VALIDATION_FAILED",
        message: "Private rejected body detail.",
        retryable: false,
        correlationID: "correlation-rejected"
    )
    let transport = ScriptedLifeModelTransport(
        submissions: [
            retryCommand.eventID: .failure(.network(code: -1_009)),
            rejectedCommand.eventID: .failure(.api(statusCode: 422, error: rejection)),
        ],
        histories: fixture.emptyHistories()
    )
    let runDate = acceptanceCoordinatorDate.addingTimeInterval(1)
    let coordinator = try LifeModelAcceptanceCoordinator(
        store: fixture.store,
        transport: transport,
        configuration: LifeModelAcceptanceCoordinatorConfiguration(
            retryBaseDelay: 10,
            retryMaximumDelay: 15
        ),
        clock: { runDate }
    )

    let report = try await coordinator.synchronize()

    #expect(report.retryScheduledCount == 1)
    #expect(report.rejectedCount == 1)
    let stored = try fixture.store.lifeModelAcceptances()
    let retry = try #require(stored.first { $0.command.eventID == retryCommand.eventID })
    let rejected = try #require(stored.first { $0.command.eventID == rejectedCommand.eventID })
    #expect(retry.deliveryStatus == .retry)
    #expect(retry.attemptCount == 2)
    #expect(retry.nextAttemptAt == runDate.addingTimeInterval(15))
    #expect(retry.lastErrorMessage == "Delivery could not be completed and will retry.")
    #expect(rejected.deliveryStatus == .rejected)
    #expect(rejected.lastErrorCode == "REQUEST_VALIDATION_FAILED")
    #expect(rejected.lastErrorMessage == "The server or transport rejected this acceptance command.")
    #expect(rejected.lastErrorMessage?.contains("Private rejected body detail.") == false)
}

private enum ScriptedLifeModelSubmission: Sendable {
    case receipt(LifeModelRevisionReceipt)
    case failure(LifeModelTransportError)
}

private actor ScriptedLifeModelTransport: LifeModelTransport {
    private let submissions: [UUIDv7: ScriptedLifeModelSubmission]
    private let orientationResponse: CurrentOrientationResponse?
    private let histories: [LifeModelKind: LifeModelHistoryResponse]
    private let submitDelayNanoseconds: UInt64
    private var submittedEvents: [UUIDv7] = []
    private var requestedHistoryKinds: [LifeModelKind] = []
    private var orientationRequests = 0

    init(
        submissions: [UUIDv7: ScriptedLifeModelSubmission],
        orientationResponse: CurrentOrientationResponse? = nil,
        histories: [LifeModelKind: LifeModelHistoryResponse],
        submitDelayNanoseconds: UInt64 = 0
    ) {
        self.submissions = submissions
        self.orientationResponse = orientationResponse
        self.histories = histories
        self.submitDelayNanoseconds = submitDelayNanoseconds
    }

    func submit(_ command: LifeModelAcceptanceCommand) async throws -> LifeModelRevisionReceipt {
        submittedEvents.append(command.eventID)
        if submitDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: submitDelayNanoseconds)
        }
        guard let result = submissions[command.eventID] else {
            throw LifeModelTransportError.network(code: -1_008)
        }
        switch result {
        case let .receipt(receipt):
            return receipt
        case let .failure(error):
            throw error
        }
    }

    func orientation(asOf: Date?) async throws -> CurrentOrientationResponse {
        orientationRequests += 1
        guard let orientationResponse else {
            throw LifeModelTransportError.network(code: -1_008)
        }
        return orientationResponse
    }

    func history(
        kind: LifeModelKind,
        limit: Int
    ) async throws -> LifeModelHistoryResponse {
        requestedHistoryKinds.append(kind)
        guard let response = histories[kind] else {
            throw LifeModelTransportError.network(code: -1_008)
        }
        return response
    }

    func submissionCount() -> Int {
        submittedEvents.count
    }

    func historyKinds() -> [LifeModelKind] {
        requestedHistoryKinds
    }

    func orientationCount() -> Int {
        orientationRequests
    }
}

private struct AcceptanceCoordinatorFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-acceptance-coordinator-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        store = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: directory.appendingPathComponent("ledger.sqlite3"),
                deviceID: try Self.identifier(900),
                preMigrationBackupDirectory: directory,
                clock: { acceptanceCoordinatorDate }
            )
        )
    }

    func command(
        index: Int,
        kind: LifeModelKind
    ) throws -> LifeModelAcceptanceCommand {
        let eventID = try Self.identifier(index * 10 + 1)
        let versionID = try Self.identifier(index * 10 + 2)
        let logicalID = try Self.identifier(index * 10 + 3)
        let document: [String: JSONValue] = [
            "metadata": .object([
                "id": .string(versionID.description),
                "revision": .number(1),
            ]),
            "title": .string("Synthetic \(kind.rawValue)"),
        ]
        return try LifeModelAcceptanceCommand(
            eventID: eventID,
            kind: kind,
            versionID: versionID,
            logicalID: logicalID,
            versionNumber: 1,
            expectedCurrentVersionID: nil,
            acceptanceMethod: .ownerAuthored,
            acceptedAt: acceptanceCoordinatorDate,
            requestBody: SyncJSONCoding.makeEncoder().encode([
                "event_id": JSONValue.string(eventID.description),
                "document": JSONValue.object(document),
            ]),
            document: SyncJSONCoding.makeEncoder().encode(document),
            createdAt: acceptanceCoordinatorDate
        )
    }

    func envelope(
        for command: LifeModelAcceptanceCommand,
        acceptanceSequence: Int,
        status: String? = nil
    ) throws -> LifeModelVersionEnvelope {
        LifeModelVersionEnvelope(
            kind: command.kind,
            versionID: command.versionID,
            logicalID: command.logicalID,
            versionNumber: command.versionNumber,
            acceptanceSequence: acceptanceSequence,
            eventID: command.eventID,
            ledgerSequence: Int64(acceptanceSequence),
            supersedesVersionID: command.expectedCurrentVersionID,
            status: status,
            acceptanceMethod: command.acceptanceMethod,
            acceptedAt: command.acceptedAt,
            contentHash: String(repeating: "a", count: 64),
            document: try SyncJSONCoding.makeDecoder().decode(
                [String: JSONValue].self,
                from: command.document
            )
        )
    }

    func receipt(_ envelope: LifeModelVersionEnvelope) -> LifeModelRevisionReceipt {
        LifeModelRevisionReceipt(
            version: envelope,
            eventID: envelope.eventID,
            ledgerSequence: envelope.ledgerSequence,
            created: true,
            warnings: [],
            policyVersion: acceptancePolicyVersion
        )
    }

    func emptyHistories() -> [LifeModelKind: LifeModelHistoryResponse] {
        Dictionary(uniqueKeysWithValues: LifeModelKind.allCases.map {
            (
                $0,
                LifeModelHistoryResponse(
                    kind: $0,
                    versions: [],
                    policyVersion: acceptancePolicyVersion
                )
            )
        })
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func identifier(_ value: Int) throws -> UUIDv7 {
        let suffix = String(format: "%012x", value)
        return try UUIDv7(
            validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
        )
    }
}
