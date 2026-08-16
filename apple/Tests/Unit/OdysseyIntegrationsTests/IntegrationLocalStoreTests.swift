import Foundation
import OdysseyIntegrations
import Testing

private let integrationStoreDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func syntheticIntegrationStoreAppliesCursorDeleteAndImmutableDedupAtomically() async throws {
    let store = SyntheticIntegrationLocalStore()
    let record = try integrationRecord(document: Data("first".utf8))
    let page = try IntegrationLocalPage(
        connector: .health,
        stream: "heart_rate",
        records: [record],
        deletedExternalIdentifiers: [],
        nextCursor: Data([1]),
        appliedAt: integrationStoreDate,
        allowsUpdates: false
    )
    let first = try await store.applyIntegrationPage(page)
    let duplicate = try await store.applyIntegrationPage(page)

    #expect(first.insertedCount == 1)
    #expect(duplicate.duplicateCount == 1)
    #expect(try await store.integrationSnapshot(
        connector: .health,
        stream: "heart_rate"
    ).cursor == Data([1]))

    let conflicting = try integrationRecord(
        document: Data("changed".utf8)
    )
    let conflict = try await store.applyIntegrationPage(IntegrationLocalPage(
        connector: .health,
        stream: "heart_rate",
        records: [conflicting],
        deletedExternalIdentifiers: [],
        nextCursor: Data([2]),
        appliedAt: integrationStoreDate,
        allowsUpdates: false
    ))
    #expect(conflict.rejectedCount == 1)

    let deletion = try await store.applyIntegrationPage(IntegrationLocalPage(
        connector: .health,
        stream: "heart_rate",
        records: [],
        deletedExternalIdentifiers: [record.externalIdentifier],
        nextCursor: Data([3]),
        appliedAt: integrationStoreDate,
        allowsUpdates: false
    ))
    let empty = try await store.integrationSnapshot(
        connector: .health,
        stream: "heart_rate"
    )
    #expect(deletion.deletedCount == 1)
    #expect(empty.records.isEmpty)
    #expect(empty.cursor == Data([3]))
}

@Test
func syntheticIntegrationStoreAllowsMutableMirrorsAndConnectorRevocation() async throws {
    let store = SyntheticIntegrationLocalStore()
    let first = try integrationRecord(
        connector: .calendar,
        stream: "events",
        document: Data("first".utf8)
    )
    let changed = try integrationRecord(
        connector: .calendar,
        stream: "events",
        document: Data("changed".utf8)
    )
    _ = try await store.applyIntegrationPage(IntegrationLocalPage(
        connector: .calendar,
        stream: "events",
        records: [first],
        deletedExternalIdentifiers: [],
        nextCursor: nil,
        appliedAt: integrationStoreDate,
        allowsUpdates: true
    ))
    let update = try await store.applyIntegrationPage(IntegrationLocalPage(
        connector: .calendar,
        stream: "events",
        records: [changed],
        deletedExternalIdentifiers: [],
        nextCursor: nil,
        appliedAt: integrationStoreDate,
        allowsUpdates: true
    ))

    #expect(update.updatedCount == 1)
    #expect(try await store.clearIntegrationData(connector: .calendar) == 1)
    #expect(try await store.integrationSnapshot(
        connector: .calendar,
        stream: "events"
    ).records.isEmpty)
}

private func integrationRecord(
    connector: IntegrationConnector = .health,
    stream: String = "heart_rate",
    document: Data
) throws -> IntegrationLocalRecord {
    try IntegrationLocalRecord(
        connector: connector,
        stream: stream,
        externalIdentifier: "00000000-0000-4000-8000-000000000001",
        sourceTimestamp: integrationStoreDate,
        document: document
    )
}
