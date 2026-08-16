import Foundation
import OdysseyDomain
import OdysseyIntegrations
import OdysseyWeather
import Testing

private let weatherCoordinatorDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func weatherCoordinatorAtomicallyInsertsAndUpdatesOneCoordinateFreeSnapshot() async throws {
    let first = try coordinatorWeatherSnapshot(temperature: 21)
    let second = try coordinatorWeatherSnapshot(
        sourceAsOf: weatherCoordinatorDate.addingTimeInterval(60),
        temperature: 24
    )
    let adapter = SyntheticWeatherAdapter(
        capability: coordinatorWeatherCapability,
        responses: [
            SyntheticWeatherResponse(
                expectedPlaceIdentifier: first.place.identifier,
                result: try WeatherMirrorResult(
                    outcome: .fetched,
                    snapshot: first,
                    rateLimitState: .ready
                )
            ),
            SyntheticWeatherResponse(
                expectedPlaceIdentifier: second.place.identifier,
                result: try WeatherMirrorResult(
                    outcome: .fetched,
                    snapshot: second,
                    rateLimitState: .ready,
                    rejectedRecordCount: 1
                )
            ),
        ]
    )
    let store = SyntheticIntegrationLocalStore()
    let coordinator = WeatherMirrorCoordinator(
        adapter: adapter,
        store: store,
        clock: { weatherCoordinatorDate.addingTimeInterval(120) }
    )
    let query = try coordinatorWeatherQuery(place: first.place)

    let inserted = try await coordinator.refresh(for: query)
    let updated = try await coordinator.refresh(for: query)
    let snapshot = try await coordinator.localSnapshot()
    let overview = try await coordinator.overview(
        observedAt: weatherCoordinatorDate.addingTimeInterval(180)
    )
    let stored = try await store.integrationSnapshot(
        connector: .weather,
        stream: WeatherMirrorCoordinator.stream
    )
    let encoded = String(decoding: stored.records[0].document, as: UTF8.self)

    #expect(inserted.insertedCount == 1)
    #expect(updated.updatedCount == 1)
    #expect(updated.rejectedCount == 1)
    #expect(snapshot.context == second)
    #expect(snapshot.lastOutcome == .fetched)
    #expect(snapshot.lastSuccessfulRefreshAt == weatherCoordinatorDate.addingTimeInterval(120))
    #expect(stored.records.count == 1)
    #expect(stored.records[0].externalIdentifier == "current")
    #expect(!encoded.contains("latitude"))
    #expect(!encoded.contains("longitude"))
    #expect(!encoded.contains("horizontalAccuracyMeters"))
    #expect(overview.cachedPlace == second.place)
    #expect(overview.cacheIsFresh)
    #expect(overview.newestSourceTimestamp == second.sourceAsOf)
    #expect(overview.attribution == second.attribution)
}

@Test
func rateLimitedWeatherRefreshPreservesCachedContextAndRecordsDiagnostics() async throws {
    let context = try coordinatorWeatherSnapshot(temperature: 21)
    let store = SyntheticIntegrationLocalStore()
    let authorized = WeatherMirrorCoordinator(
        adapter: SyntheticWeatherAdapter(
            capability: coordinatorWeatherCapability,
            responses: [SyntheticWeatherResponse(
                expectedPlaceIdentifier: context.place.identifier,
                result: try WeatherMirrorResult(
                    outcome: .fetched,
                    snapshot: context,
                    rateLimitState: .ready
                )
            )]
        ),
        store: store,
        clock: { weatherCoordinatorDate.addingTimeInterval(60) }
    )
    let query = try coordinatorWeatherQuery(place: context.place)
    _ = try await authorized.refresh(for: query)
    let limited = WeatherMirrorCoordinator(
        adapter: SyntheticWeatherAdapter(
            capability: coordinatorWeatherCapability,
            responses: [SyntheticWeatherResponse(
                expectedPlaceIdentifier: context.place.identifier,
                result: try WeatherMirrorResult(
                    outcome: .rateLimited,
                    snapshot: nil,
                    rateLimitState: .limited,
                    rejectedRecordCount: 2
                )
            )]
        ),
        store: store,
        clock: { weatherCoordinatorDate.addingTimeInterval(120) }
    )

    let receipt = try await limited.refresh(for: query)
    let snapshot = try await limited.localSnapshot()

    #expect(receipt.outcome == .rateLimited)
    #expect(receipt.cursorAdvanced)
    #expect(receipt.updatedCount == 0)
    #expect(snapshot.context == context)
    #expect(snapshot.lastAttemptAt == weatherCoordinatorDate.addingTimeInterval(120))
    #expect(snapshot.lastSuccessfulRefreshAt == weatherCoordinatorDate.addingTimeInterval(60))
    #expect(snapshot.lastOutcome == .rateLimited)
    #expect(snapshot.rateLimitState == .limited)
    #expect(snapshot.rejectedRecordCount == 2)
    #expect(try await limited.revokeLocalWeatherData() == 1)
    #expect(try await limited.localSnapshot().context == nil)
}

@Test
func weatherCoordinatorRejectsMismatchedPlacesAndTamperedDocuments() async throws {
    let requestedPlace = try coordinatorWeatherPlace(identifier: "requested")
    let returned = try coordinatorWeatherSnapshot(
        place: coordinatorWeatherPlace(identifier: "returned"),
        temperature: 21
    )
    let store = SyntheticIntegrationLocalStore()
    let coordinator = WeatherMirrorCoordinator(
        adapter: SyntheticWeatherAdapter(
            capability: coordinatorWeatherCapability,
            responses: [SyntheticWeatherResponse(
                expectedPlaceIdentifier: requestedPlace.identifier,
                result: try WeatherMirrorResult(
                    outcome: .fetched,
                    snapshot: returned,
                    rateLimitState: .ready
                )
            )]
        ),
        store: store,
        clock: { weatherCoordinatorDate }
    )

    await #expect(throws: WeatherMirrorCoordinatorError.unexpectedSnapshotPlace) {
        try await coordinator.refresh(
            for: coordinatorWeatherQuery(place: requestedPlace)
        )
    }
    #expect(try await coordinator.localSnapshot().context == nil)

    _ = try await store.applyIntegrationPage(IntegrationLocalPage(
        connector: .weather,
        stream: WeatherMirrorCoordinator.stream,
        records: [IntegrationLocalRecord(
            connector: .weather,
            stream: WeatherMirrorCoordinator.stream,
            externalIdentifier: "current",
            sourceTimestamp: weatherCoordinatorDate,
            document: Data("tampered".utf8)
        )],
        deletedExternalIdentifiers: [],
        nextCursor: nil,
        appliedAt: weatherCoordinatorDate,
        allowsUpdates: true
    ))
    await #expect(throws: WeatherMirrorCoordinatorError.invalidStoredDocument) {
        try await coordinator.localSnapshot()
    }
}

private let coordinatorWeatherCapability = WeatherMirrorCapability(
    availability: .available,
    supportsCurrentConditions: true,
    supportsHourlyForecast: true,
    supportsDailyForecast: true
)

private func coordinatorWeatherQuery(
    place: WeatherPlaceContext
) throws -> WeatherQueryLocation {
    try WeatherQueryLocation(
        place: place,
        latitude: 40.7,
        longitude: -74,
        horizontalAccuracyMeters: 5_000
    )
}

private func coordinatorWeatherSnapshot(
    place: WeatherPlaceContext? = nil,
    sourceAsOf: Date = weatherCoordinatorDate,
    temperature: Double
) throws -> WeatherContextSnapshot {
    let resolvedPlace = try place ?? coordinatorWeatherPlace(identifier: "broad_place_1")
    return try WeatherContextSnapshot(
        place: resolvedPlace,
        sourceAsOf: sourceAsOf,
        fetchedAt: sourceAsOf,
        expiresAt: sourceAsOf.addingTimeInterval(3_600),
        current: WeatherInstantConditions(
            forecastAt: sourceAsOf,
            conditionCode: "partly_cloudy",
            temperatureCelsius: temperature,
            apparentTemperatureCelsius: temperature,
            precipitationProbability: 0.2
        ),
        hourlyForecast: [],
        dailyForecast: [],
        attribution: WeatherProviderAttribution(
            providerName: "Synthetic Weather",
            attributionText: "Synthetic forecast for coordinator testing.",
            legalPageURL: URL(string: "https://weather.example.test/legal")!
        )
    )
}

private func coordinatorWeatherPlace(
    identifier: String
) throws -> WeatherPlaceContext {
    try WeatherPlaceContext(
        identifier: identifier,
        displayName: "Synthetic Metro",
        timeZoneID: "America/New_York"
    )
}
