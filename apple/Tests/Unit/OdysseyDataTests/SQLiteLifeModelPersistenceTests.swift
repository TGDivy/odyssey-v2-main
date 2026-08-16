import Foundation
@testable import OdysseyData
import OdysseyDomain
import Testing

private let lifeModelFixtureDate = Date(timeIntervalSince1970: 1_786_752_000.125)

@Test
func lifeModelAcceptanceQueueIsDurableIdempotentAndOrdered() throws {
    let fixture = try LifeModelFixture()
    let first = try fixture.command(index: 1, kind: .charter)
    let second = try fixture.command(
        index: 2,
        kind: .charter,
        versionNumber: 2,
        expectedCurrentVersionID: first.versionID
    )

    let firstStored = try fixture.store.enqueueLifeModelAcceptance(first)
    let retry = try fixture.store.enqueueLifeModelAcceptance(first)
    let secondStored = try fixture.store.enqueueLifeModelAcceptance(second)

    #expect(firstStored.localSequence == 1)
    #expect(retry == firstStored)
    #expect(secondStored.localSequence == 2)
    #expect(
        try fixture.store.pendingLifeModelAcceptances(readyAt: lifeModelFixtureDate)
            .map(\.command.eventID) == [first.eventID, second.eventID]
    )
    #expect(
        try fixture.store.lifeModelAcceptances(kind: .charter)
            .map(\.command.eventID) == [second.eventID, first.eventID]
    )
    let diagnostics = try fixture.store.lifeModelQueueDiagnostics()
    #expect(diagnostics.queuedCount == 2)
    #expect(diagnostics.conflictCount == 0)
    #expect(diagnostics.oldestQueuedAt == lifeModelFixtureDate)
}

@Test
func delayedLifeModelRetryBlocksLaterCommandsUntilReady() throws {
    let fixture = try LifeModelFixture()
    let first = try fixture.command(index: 5, kind: .charter)
    let second = try fixture.command(index: 6, kind: .season)
    _ = try fixture.store.enqueueLifeModelAcceptance(first)
    _ = try fixture.store.enqueueLifeModelAcceptance(second)
    let retryAt = lifeModelFixtureDate.addingTimeInterval(60)
    try fixture.store.recordLifeModelRetry(
        eventID: first.eventID,
        errorCode: "NETWORK",
        message: "Synthetic delayed retry.",
        nextAttemptAt: retryAt,
        updatedAt: lifeModelFixtureDate
    )

    #expect(
        try fixture.store.pendingLifeModelAcceptances(readyAt: lifeModelFixtureDate).isEmpty
    )
    #expect(
        try fixture.store.pendingLifeModelAcceptances(readyAt: retryAt)
            .map(\.command.eventID) == [first.eventID, second.eventID]
    )
}

@Test
func lifeModelConflictIsTerminalAndNeverSilentlyMerged() throws {
    let fixture = try LifeModelFixture()
    let command = try fixture.command(index: 10, kind: .season)
    _ = try fixture.store.enqueueLifeModelAcceptance(command)
    let actualCurrent = try fixture.identifier(99)
    let completedAt = lifeModelFixtureDate.addingTimeInterval(1)

    try fixture.store.recordLifeModelConflict(
        eventID: command.eventID,
        errorCode: "LIFE_MODEL_CURRENT_VERSION_CONFLICT",
        message: "Review the accepted current version before revising.",
        actualCurrentVersionID: actualCurrent,
        completedAt: completedAt
    )

    let stored = try #require(fixture.store.lifeModelAcceptances().first)
    #expect(stored.deliveryStatus == .conflict)
    #expect(stored.actualCurrentVersionID == actualCurrent)
    #expect(stored.attemptCount == 1)
    #expect(try fixture.store.pendingLifeModelAcceptances(readyAt: completedAt).isEmpty)
    #expect(throws: SQLiteLedgerError.self) {
        try fixture.store.recordLifeModelRetry(
            eventID: command.eventID,
            errorCode: "NETWORK",
            message: "Must not retry a semantic conflict.",
            nextAttemptAt: completedAt.addingTimeInterval(30),
            updatedAt: completedAt
        )
    }
}

@Test
func acceptedLifeModelReceiptIsMatchedCachedAndExported() async throws {
    let fixture = try LifeModelFixture()
    let command = try fixture.command(index: 20, kind: .lifeStage)
    _ = try fixture.store.enqueueLifeModelAcceptance(command)
    let version = try fixture.cachedVersion(for: command, acceptanceSequence: 1)

    try fixture.store.recordLifeModelAccepted(
        eventID: command.eventID,
        version: version,
        completedAt: lifeModelFixtureDate.addingTimeInterval(2)
    )
    try fixture.store.cacheLifeModelVersion(version)

    let stored = try #require(fixture.store.lifeModelAcceptances().first)
    #expect(stored.deliveryStatus == .accepted)
    #expect(try fixture.store.cachedLifeModelVersions(kind: .lifeStage) == [version])
    let report = try fixture.store.integrityReport()
    #expect(report.lifeModelCommandCount == 1)
    #expect(report.cachedLifeModelVersionCount == 1)

    let exportURL = fixture.directory.appendingPathComponent("life-model-export.json")
    _ = try await fixture.store.exportAll(to: exportURL)
    let archive = try fixture.decodeExport(at: exportURL)
    #expect(archive.lifeModelAcceptances.count == 1)
    #expect(archive.cachedLifeModelVersions == [version])
}

private struct LifeModelFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-life-model-tests-\(UUID().uuidString)",
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
                clock: { lifeModelFixtureDate }
            )
        )
    }

    func command(
        index: Int,
        kind: LifeModelKind,
        versionNumber: Int = 1,
        expectedCurrentVersionID: UUIDv7? = nil
    ) throws -> LifeModelAcceptanceCommand {
        let versionID = try identifier(index * 10 + 1)
        let eventID = try identifier(index * 10 + 2)
        let logicalID = try identifier(index * 10 + 3)
        let document = try JSONSerialization.data(
            withJSONObject: [
                "metadata": ["id": versionID.description, "revision": versionNumber],
                "title": "Synthetic \(kind.rawValue) version",
            ],
            options: .sortedKeys
        )
        var requestObject: [String: Any] = [
            "event_id": eventID.description,
            "device_id": try identifier(900).description,
            "acceptance_method": LifeModelAcceptanceMethod.ownerAuthored.rawValue,
            "document": String(decoding: document, as: UTF8.self),
        ]
        if let expectedCurrentVersionID {
            requestObject["expected_current_version_id"] = expectedCurrentVersionID.description
        } else {
            requestObject["expected_current_version_id"] = NSNull()
        }
        let request = try JSONSerialization.data(withJSONObject: requestObject, options: .sortedKeys)
        return try LifeModelAcceptanceCommand(
            eventID: eventID,
            kind: kind,
            versionID: versionID,
            logicalID: logicalID,
            versionNumber: versionNumber,
            expectedCurrentVersionID: expectedCurrentVersionID,
            acceptanceMethod: .ownerAuthored,
            acceptedAt: lifeModelFixtureDate,
            requestBody: request,
            document: document,
            createdAt: lifeModelFixtureDate
        )
    }

    func cachedVersion(
        for command: LifeModelAcceptanceCommand,
        acceptanceSequence: Int
    ) throws -> CachedLifeModelVersion {
        try CachedLifeModelVersion(
            kind: command.kind,
            versionID: command.versionID,
            logicalID: command.logicalID,
            versionNumber: command.versionNumber,
            acceptanceSequence: acceptanceSequence,
            supersedesVersionID: command.expectedCurrentVersionID,
            status: nil,
            acceptanceMethod: command.acceptanceMethod,
            acceptedAt: command.acceptedAt,
            contentHash: String(repeating: "a", count: 64),
            document: command.document,
            eventID: command.eventID,
            ledgerSequence: Int64(acceptanceSequence),
            policyVersion: "life-model-acceptance-policy-1.0",
            cachedAt: lifeModelFixtureDate.addingTimeInterval(2)
        )
    }

    func identifier(_ value: Int) throws -> UUIDv7 {
        try Self.identifier(value)
    }

    func decodeExport(at url: URL) throws -> LedgerExportArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid fixture timestamp."
                )
            }
            return date
        }
        return try decoder.decode(LedgerExportArchive.self, from: Data(contentsOf: url))
    }

    private static func identifier(_ value: Int) throws -> UUIDv7 {
        let suffix = String(format: "%012x", value)
        return try UUIDv7(
            validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
        )
    }
}
