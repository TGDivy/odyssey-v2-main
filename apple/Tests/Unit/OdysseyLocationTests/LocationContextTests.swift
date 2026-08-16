import Foundation
import OdysseyIntegrations
import OdysseyLocation
import Testing

private let locationContractDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func broadLocationContextRoundTripsWithoutCoordinates() throws {
    let context = try locationContext()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(context)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let roundTrip = try decoder.decode(BroadLocationContext.self, from: data)
    let encoded = String(decoding: data, as: UTF8.self)

    #expect(roundTrip == context)
    #expect(roundTrip.precision == .locality)
    #expect(!encoded.contains("latitude"))
    #expect(!encoded.contains("longitude"))
    #expect(!encoded.contains("horizontalAccuracyMeters"))
}

@Test
func locationCoordinatorPersistsOnlyBroadPlaceAndReturnsTransientFix() async throws {
    let first = try locationFix(identifier: "place_1", latitude: 40.7)
    let second = try locationFix(
        identifier: "place_2",
        latitude: 51.5,
        capturedAt: locationContractDate.addingTimeInterval(60),
        displayName: "Synthetic London",
        timeZoneID: "Europe/London"
    )
    let adapter = SyntheticLocationAdapter(
        capability: availableLocationCapability,
        initialPermission: .authorized,
        authorizationAfterRequest: .authorized,
        responses: [
            try BroadLocationResult(outcome: .acquired, fix: first),
            try BroadLocationResult(
                outcome: .acquired,
                fix: second,
                rejectedRecordCount: 1
            ),
        ]
    )
    let store = SyntheticIntegrationLocalStore()
    let coordinator = LocationContextCoordinator(
        adapter: adapter,
        store: store,
        clock: { locationContractDate.addingTimeInterval(120) }
    )

    let inserted = try await coordinator.refresh()
    let updated = try await coordinator.refresh()
    let snapshot = try await coordinator.localSnapshot()
    let overview = try await coordinator.overview(
        observedAt: locationContractDate.addingTimeInterval(180)
    )
    let stored = try await store.integrationSnapshot(
        connector: .location,
        stream: LocationContextCoordinator.stream
    )
    let encoded = String(decoding: stored.records[0].document, as: UTF8.self)

    #expect(inserted.insertedCount == 1)
    #expect(inserted.transientFix == first)
    #expect(updated.updatedCount == 1)
    #expect(updated.rejectedCount == 1)
    #expect(updated.transientFix == second)
    #expect(snapshot.context == second.context)
    #expect(overview.cachedPlace == second.context)
    #expect(overview.cacheIsFresh)
    #expect(stored.records.count == 1)
    #expect(!encoded.contains("latitude"))
    #expect(!encoded.contains("longitude"))
    #expect(!encoded.contains("horizontalAccuracyMeters"))
}

@Test
func deniedLocationRefreshPreservesBroadPlaceUntilLocalRevocation() async throws {
    let fix = try locationFix(identifier: "place_1", latitude: 40.7)
    let store = SyntheticIntegrationLocalStore()
    let authorized = LocationContextCoordinator(
        adapter: SyntheticLocationAdapter(
            capability: availableLocationCapability,
            initialPermission: .authorized,
            authorizationAfterRequest: .authorized,
            responses: [try BroadLocationResult(outcome: .acquired, fix: fix)]
        ),
        store: store,
        clock: { locationContractDate.addingTimeInterval(60) }
    )
    _ = try await authorized.refresh()
    let denied = LocationContextCoordinator(
        adapter: SyntheticLocationAdapter(
            capability: availableLocationCapability,
            initialPermission: .denied,
            authorizationAfterRequest: .denied
        ),
        store: store,
        clock: { locationContractDate.addingTimeInterval(120) }
    )

    let receipt = try await denied.refresh()
    let snapshot = try await denied.localSnapshot()

    #expect(receipt.outcome == .permissionDenied)
    #expect(receipt.transientFix == nil)
    #expect(snapshot.context == fix.context)
    #expect(snapshot.lastSuccessfulRefreshAt == locationContractDate.addingTimeInterval(60))
    #expect(snapshot.lastOutcome == .permissionDenied)
    #expect(try await denied.revokeLocalLocationData() == 1)
    #expect(try await denied.localSnapshot().context == nil)
}

@Test
func locationContractsRejectInvalidAccuracyFreshnessAndResultShape() throws {
    #expect(throws: LocationContextError.invalidClock) {
        try BroadLocationContext(
            placeIdentifier: "place_1",
            displayName: "Synthetic Place",
            timeZoneID: "UTC",
            capturedAt: locationContractDate,
            expiresAt: locationContractDate,
            precision: .locality
        )
    }
    #expect(throws: LocationContextError.invalidLocation) {
        try TransientLocationFix(
            context: locationContext(),
            latitude: 91,
            longitude: 0,
            horizontalAccuracyMeters: 10
        )
    }
    #expect(throws: LocationContextError.invalidResult) {
        try BroadLocationResult(
            outcome: .permissionDenied,
            fix: locationFix(identifier: "place_1", latitude: 40.7)
        )
    }
}

private let availableLocationCapability = LocationContextCapability(
    availability: .available,
    supportsForegroundBroadPlace: true,
    supportsSignificantChanges: false
)

private func locationContext(
    identifier: String = "place_1",
    capturedAt: Date = locationContractDate,
    displayName: String = "Synthetic New York",
    timeZoneID: String = "America/New_York"
) throws -> BroadLocationContext {
    try BroadLocationContext(
        placeIdentifier: identifier,
        displayName: displayName,
        timeZoneID: timeZoneID,
        capturedAt: capturedAt,
        expiresAt: capturedAt.addingTimeInterval(3_600),
        precision: .locality
    )
}

private func locationFix(
    identifier: String,
    latitude: Double,
    capturedAt: Date = locationContractDate,
    displayName: String = "Synthetic New York",
    timeZoneID: String = "America/New_York"
) throws -> TransientLocationFix {
    try TransientLocationFix(
        context: locationContext(
            identifier: identifier,
            capturedAt: capturedAt,
            displayName: displayName,
            timeZoneID: timeZoneID
        ),
        latitude: latitude,
        longitude: -74,
        horizontalAccuracyMeters: 5_000
    )
}
