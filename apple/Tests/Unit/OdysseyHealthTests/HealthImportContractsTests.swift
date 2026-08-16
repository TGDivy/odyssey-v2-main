import Foundation
import OdysseyHealth
import OdysseyIntegrations
import Testing

private let healthImportDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func healthImportProjectionDeduplicatesAndDeletesBySourceIdentity() throws {
    let sample = try syntheticHealthSample(value: 72)
    let firstCursor = try HealthImportCursor(data: Data([1]))
    let batch = try HealthImportBatch(
        kind: .heartRate,
        queriedAt: healthImportDate,
        samples: [sample, sample],
        deletedIdentities: [],
        nextCursor: firstCursor,
        outcome: .imported
    )
    let first = try HealthImportProjection().applying(batch)

    #expect(first.insertedCount == 1)
    #expect(first.duplicateCount == 1)
    #expect(first.rejectedCount == 0)
    #expect(first.projection.samples == [sample])
    #expect(first.projection.cursors[.heartRate] == firstCursor)

    let deletion = try HealthImportBatch(
        kind: .heartRate,
        queriedAt: healthImportDate.addingTimeInterval(1),
        samples: [],
        deletedIdentities: [sample.identity],
        nextCursor: try HealthImportCursor(data: Data([2])),
        outcome: .imported
    )
    let deleted = first.projection.applying(deletion)
    #expect(deleted.deletedCount == 1)
    #expect(deleted.projection.samples.isEmpty)
}

@Test
func healthImportProjectionRejectsConflictingImmutableDuplicates() throws {
    let existing = try syntheticHealthSample(value: 72)
    let conflicting = try syntheticHealthSample(value: 99)
    let conflictedPage = try HealthImportBatch(
        kind: .heartRate,
        queriedAt: healthImportDate,
        samples: [existing, conflicting],
        deletedIdentities: [],
        nextCursor: nil,
        outcome: .imported
    )
    let pageResult = try HealthImportProjection().applying(conflictedPage)
    #expect(pageResult.rejectedCount == 1)
    #expect(pageResult.projection.samples.isEmpty)

    let projection = try HealthImportProjection(samples: [existing])
    let batch = try HealthImportBatch(
        kind: .heartRate,
        queriedAt: healthImportDate,
        samples: [conflicting],
        deletedIdentities: [],
        nextCursor: nil,
        outcome: .imported
    )
    let result = projection.applying(batch)

    #expect(result.insertedCount == 0)
    #expect(result.rejectedCount == 1)
    #expect(result.projection.samples == [existing])
}

@Test
func syntheticHealthAdapterMakesDeniedAccessExplicitAndPagesByAnchor() async throws {
    let denied = SyntheticHealthImportAdapter(
        capability: HealthImportCapability(
            availability: .available,
            supportedKinds: [.workout]
        ),
        initialPermission: .denied,
        authorizationAfterRequest: .denied,
        clock: { healthImportDate }
    )
    let deniedBatch = try await denied.changes(
        for: .workout,
        after: nil,
        limit: 100
    )
    #expect(deniedBatch.outcome == .permissionDenied)
    #expect(deniedBatch.samples.isEmpty)

    let cursor = try HealthImportCursor(data: Data([7]))
    let page = try HealthImportBatch(
        kind: .heartRate,
        queriedAt: healthImportDate,
        samples: [syntheticHealthSample(value: 65)],
        deletedIdentities: [],
        nextCursor: cursor,
        outcome: .imported
    )
    let authorized = SyntheticHealthImportAdapter(
        capability: HealthImportCapability(
            availability: .available,
            supportedKinds: [.heartRate]
        ),
        initialPermission: .notDetermined,
        authorizationAfterRequest: .authorized,
        pages: [.heartRate: [SyntheticHealthImportPage(
            expectedCursor: nil,
            batch: page
        )]]
    )
    #expect(try await authorized.requestAuthorization(for: [.heartRate]) == .authorized)
    #expect(try await authorized.changes(
        for: .heartRate,
        after: nil,
        limit: 100
    ) == page)
    await #expect(throws: HealthImportError.unexpectedSyntheticCursor) {
        try await authorized.changes(
            for: .heartRate,
            after: cursor,
            limit: 100
        )
    }
}

private func syntheticHealthSample(value: Double) throws -> HealthImportedSample {
    try HealthImportedSample(
        identity: HealthSampleIdentity(
            kind: .heartRate,
            externalIdentifier: "00000000-0000-4000-8000-000000000001"
        ),
        startDate: healthImportDate.addingTimeInterval(-60),
        endDate: healthImportDate,
        source: HealthSourceMetadata(
            bundleIdentifier: "com.example.synthetic-health",
            displayName: "Synthetic Health Source",
            version: "1"
        ),
        payload: .quantity(value: value, unit: "count/min")
    )
}
