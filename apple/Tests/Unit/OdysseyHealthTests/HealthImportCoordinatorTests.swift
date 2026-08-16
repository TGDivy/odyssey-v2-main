import Foundation
import OdysseyHealth
import OdysseyIntegrations
import Testing

private let coordinatorDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func healthImportCoordinatorPersistsCanonicalPagesAndAnchoredCursors() async throws {
    let sample = try coordinatorSample(identifier: 1, value: 72)
    let firstCursor = try HealthImportCursor(data: Data([1]))
    let secondCursor = try HealthImportCursor(data: Data([2]))
    let thirdCursor = try HealthImportCursor(data: Data([3]))
    let importer = SyntheticHealthImportAdapter(
        capability: HealthImportCapability(
            availability: .available,
            supportedKinds: [.heartRate]
        ),
        initialPermission: .authorized,
        authorizationAfterRequest: .authorized,
        pages: [.heartRate: [
            SyntheticHealthImportPage(
                expectedCursor: nil,
                batch: try HealthImportBatch(
                    kind: .heartRate,
                    queriedAt: coordinatorDate,
                    samples: [sample, sample],
                    deletedIdentities: [],
                    nextCursor: firstCursor,
                    outcome: .imported,
                    rejectedRecordCount: 2
                )
            ),
            SyntheticHealthImportPage(
                expectedCursor: firstCursor,
                batch: try HealthImportBatch(
                    kind: .heartRate,
                    queriedAt: coordinatorDate.addingTimeInterval(1),
                    samples: [sample],
                    deletedIdentities: [],
                    nextCursor: secondCursor,
                    outcome: .imported
                )
            ),
            SyntheticHealthImportPage(
                expectedCursor: secondCursor,
                batch: try HealthImportBatch(
                    kind: .heartRate,
                    queriedAt: coordinatorDate.addingTimeInterval(2),
                    samples: [],
                    deletedIdentities: [],
                    nextCursor: thirdCursor,
                    outcome: .noChanges
                )
            ),
        ]]
    )
    let store = SyntheticIntegrationLocalStore()
    let coordinator = HealthImportCoordinator(importer: importer, store: store)

    let first = try await coordinator.importChanges(for: .heartRate, limit: 100)
    let second = try await coordinator.importChanges(for: .heartRate, limit: 100)
    let third = try await coordinator.importChanges(for: .heartRate, limit: 100)
    let snapshot = try await coordinator.localSnapshot(for: .heartRate)

    #expect(first.insertedCount == 1)
    #expect(first.duplicateCount == 1)
    #expect(first.rejectedCount == 2)
    #expect(first.cursorAdvanced)
    #expect(second.duplicateCount == 1)
    #expect(second.cursorAdvanced)
    #expect(third.outcome == .noChanges)
    #expect(third.cursorAdvanced)
    #expect(snapshot.samples == [sample])
    #expect(snapshot.cursor == thirdCursor)
}

@Test
func healthImportCoordinatorRejectsConflictsAndAppliesSourceDeletions() async throws {
    let existing = try coordinatorSample(identifier: 1, value: 72)
    let conflict = try coordinatorSample(identifier: 1, value: 99)
    let deleted = try coordinatorSample(identifier: 2, value: 64)
    let firstCursor = try HealthImportCursor(data: Data([1]))
    let secondCursor = try HealthImportCursor(data: Data([2]))
    let importer = SyntheticHealthImportAdapter(
        capability: HealthImportCapability(
            availability: .available,
            supportedKinds: [.heartRate]
        ),
        initialPermission: .authorized,
        authorizationAfterRequest: .authorized,
        pages: [.heartRate: [
            SyntheticHealthImportPage(
                expectedCursor: nil,
                batch: try HealthImportBatch(
                    kind: .heartRate,
                    queriedAt: coordinatorDate,
                    samples: [existing, deleted],
                    deletedIdentities: [],
                    nextCursor: firstCursor,
                    outcome: .imported
                )
            ),
            SyntheticHealthImportPage(
                expectedCursor: firstCursor,
                batch: try HealthImportBatch(
                    kind: .heartRate,
                    queriedAt: coordinatorDate.addingTimeInterval(1),
                    samples: [conflict],
                    deletedIdentities: [deleted.identity, deleted.identity],
                    nextCursor: secondCursor,
                    outcome: .imported
                )
            ),
        ]]
    )
    let store = SyntheticIntegrationLocalStore()
    let coordinator = HealthImportCoordinator(importer: importer, store: store)

    _ = try await coordinator.importChanges(for: .heartRate)
    let result = try await coordinator.importChanges(for: .heartRate)
    let snapshot = try await coordinator.localSnapshot(for: .heartRate)

    #expect(result.insertedCount == 0)
    #expect(result.deletedCount == 1)
    #expect(result.duplicateCount == 1)
    #expect(result.rejectedCount == 1)
    #expect(snapshot.samples == [existing])
    #expect(snapshot.cursor == secondCursor)
}

@Test
func deniedHealthImportPreservesMirrorUntilExplicitLocalRevocation() async throws {
    let sample = try coordinatorSample(identifier: 1, value: 72)
    let store = SyntheticIntegrationLocalStore()
    _ = try await store.applyIntegrationPage(IntegrationLocalPage(
        connector: .health,
        stream: HealthSampleKind.heartRate.rawValue,
        records: [IntegrationLocalRecord(
            connector: .health,
            stream: HealthSampleKind.heartRate.rawValue,
            externalIdentifier: sample.identity.externalIdentifier,
            sourceTimestamp: sample.endDate,
            document: Data("preserved".utf8)
        )],
        deletedExternalIdentifiers: [],
        nextCursor: Data([7]),
        appliedAt: coordinatorDate,
        allowsUpdates: false
    ))
    let denied = SyntheticHealthImportAdapter(
        capability: HealthImportCapability(
            availability: .available,
            supportedKinds: [.heartRate]
        ),
        initialPermission: .denied,
        authorizationAfterRequest: .denied,
        clock: { coordinatorDate }
    )
    let coordinator = HealthImportCoordinator(importer: denied, store: store)

    let result = try await coordinator.importChanges(for: .heartRate)
    let preserved = try await store.integrationSnapshot(
        connector: .health,
        stream: HealthSampleKind.heartRate.rawValue
    )

    #expect(result.outcome == .permissionDenied)
    #expect(preserved.records.count == 1)
    #expect(preserved.cursor == Data([7]))
    #expect(try await coordinator.revokeLocalHealthData() == 1)
    #expect(try await store.integrationSnapshot(
        connector: .health,
        stream: HealthSampleKind.heartRate.rawValue
    ).records.isEmpty)
}

private func coordinatorSample(
    identifier: Int,
    value: Double
) throws -> HealthImportedSample {
    let suffix = String(format: "%012x", identifier)
    return try HealthImportedSample(
        identity: HealthSampleIdentity(
            kind: .heartRate,
            externalIdentifier: "00000000-0000-4000-8000-\(suffix)"
        ),
        startDate: coordinatorDate.addingTimeInterval(-60),
        endDate: coordinatorDate,
        source: HealthSourceMetadata(
            bundleIdentifier: "com.example.synthetic-health",
            displayName: "Synthetic Health Source",
            version: "1"
        ),
        payload: .quantity(value: value, unit: "count/min")
    )
}
