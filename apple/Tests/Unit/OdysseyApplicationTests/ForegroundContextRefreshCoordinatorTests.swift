import Foundation
import OdysseyApplication
import OdysseyDomain
import OdysseyIntegrations
import OdysseyLocation
import OdysseyWeather
import Testing

private let foregroundFixtureInstant = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func foregroundRefreshHandsOffTransientLocationAndReassignsTravelLocalDay() async throws {
    let westFix = try foregroundLocationFix(
        identifier: "synthetic_west",
        displayName: "Synthetic West",
        timeZoneID: "America/New_York",
        latitude: 10,
        longitude: 20
    )
    let eastFix = try foregroundLocationFix(
        identifier: "synthetic_east",
        displayName: "Synthetic East",
        timeZoneID: "Asia/Tokyo",
        latitude: -10,
        longitude: -20
    )
    let store = SyntheticIntegrationLocalStore()
    let location = LocationContextCoordinator(
        adapter: SyntheticLocationAdapter(
            capability: foregroundLocationCapability,
            initialPermission: .authorized,
            authorizationAfterRequest: .authorized,
            responses: [
                try BroadLocationResult(outcome: .acquired, fix: westFix),
                try BroadLocationResult(outcome: .acquired, fix: eastFix),
            ]
        ),
        store: store,
        clock: { foregroundFixtureInstant }
    )
    let weather = WeatherMirrorCoordinator(
        adapter: SyntheticWeatherAdapter(
            capability: foregroundWeatherCapability,
            responses: [
                try foregroundWeatherResponse(for: westFix.context, temperature: 18),
                try foregroundWeatherResponse(for: eastFix.context, temperature: 27),
            ]
        ),
        store: store,
        clock: { foregroundFixtureInstant }
    )
    let coordinator = ForegroundContextRefreshCoordinator(
        locationCoordinator: location,
        weatherCoordinator: weather
    )

    let westRefresh = try await coordinator.refresh()
    let westContext = try #require(await location.localSnapshot().context)
    let westLocalDay = try LocalDate(
        containing: foregroundFixtureInstant,
        in: westContext.timeZoneID
    )
    let eastRefresh = try await coordinator.refresh()
    let eastContext = try #require(await location.localSnapshot().context)
    let eastWeather = try #require(await weather.localSnapshot().context)
    let eastLocalDay = try LocalDate(
        containing: foregroundFixtureInstant,
        in: eastContext.timeZoneID
    )
    let locationStorage = try await store.integrationSnapshot(
        connector: .location,
        stream: LocationContextCoordinator.stream
    )
    let weatherStorage = try await store.integrationSnapshot(
        connector: .weather,
        stream: WeatherMirrorCoordinator.stream
    )
    let encodedStorage = (locationStorage.records + weatherStorage.records)
        .map { String(decoding: $0.document, as: UTF8.self) }
        .joined(separator: "\n")

    guard case let .completed(westWeatherReceipt) = westRefresh.weatherRefresh,
          case let .completed(eastWeatherReceipt) = eastRefresh.weatherRefresh
    else {
        Issue.record("Expected both foreground location fixes to refresh weather.")
        return
    }
    #expect(westRefresh.locationOutcome == .acquired)
    #expect(eastRefresh.locationOutcome == .acquired)
    #expect(westWeatherReceipt.placeIdentifier == westFix.context.placeIdentifier)
    #expect(eastWeatherReceipt.placeIdentifier == eastFix.context.placeIdentifier)
    #expect(westLocalDay == LocalDate(year: 2026, month: 8, day: 15))
    #expect(eastLocalDay == LocalDate(year: 2026, month: 8, day: 16))
    #expect(eastWeather.place.timeZoneID == "Asia/Tokyo")
    #expect(locationStorage.records.count == 1)
    #expect(weatherStorage.records.count == 1)
    #expect(!encodedStorage.contains("latitude"))
    #expect(!encodedStorage.contains("longitude"))
    #expect(!encodedStorage.contains("horizontalAccuracyMeters"))
}

@Test
func deniedForegroundLocationDoesNotAttemptWeather() async throws {
    let store = SyntheticIntegrationLocalStore()
    let location = LocationContextCoordinator(
        adapter: SyntheticLocationAdapter(
            capability: foregroundLocationCapability,
            initialPermission: .denied,
            authorizationAfterRequest: .denied
        ),
        store: store,
        clock: { foregroundFixtureInstant }
    )
    let weather = WeatherMirrorCoordinator(
        adapter: SyntheticWeatherAdapter(
            capability: foregroundWeatherCapability
        ),
        store: store,
        clock: { foregroundFixtureInstant }
    )
    let coordinator = ForegroundContextRefreshCoordinator(
        locationCoordinator: location,
        weatherCoordinator: weather
    )

    let receipt = try await coordinator.refresh()
    let weatherStorage = try await store.integrationSnapshot(
        connector: .weather,
        stream: WeatherMirrorCoordinator.stream
    )

    #expect(receipt.locationOutcome == .permissionDenied)
    #expect(receipt.weatherRefresh == .notAttempted)
    #expect(weatherStorage.records.isEmpty)
    #expect(weatherStorage.cursor == nil)
}

@Test
func weatherProviderFailurePreservesAcquiredBroadPlace() async throws {
    let fix = try foregroundLocationFix(
        identifier: "synthetic_provider_failure",
        displayName: "Synthetic Provider Failure",
        timeZoneID: "UTC",
        latitude: 5,
        longitude: 6
    )
    let store = SyntheticIntegrationLocalStore()
    let location = LocationContextCoordinator(
        adapter: SyntheticLocationAdapter(
            capability: foregroundLocationCapability,
            initialPermission: .authorized,
            authorizationAfterRequest: .authorized,
            responses: [try BroadLocationResult(outcome: .acquired, fix: fix)]
        ),
        store: store,
        clock: { foregroundFixtureInstant }
    )
    let weather = WeatherMirrorCoordinator(
        adapter: SyntheticWeatherAdapter(
            capability: foregroundWeatherCapability
        ),
        store: store,
        clock: { foregroundFixtureInstant }
    )
    let coordinator = ForegroundContextRefreshCoordinator(
        locationCoordinator: location,
        weatherCoordinator: weather
    )

    let receipt = try await coordinator.refresh()
    let locationSnapshot = try await location.localSnapshot()
    let weatherSnapshot = try await weather.localSnapshot()

    #expect(receipt.locationOutcome == .acquired)
    #expect(receipt.weatherRefresh == .failed)
    #expect(locationSnapshot.context == fix.context)
    #expect(weatherSnapshot.context == nil)
}

private let foregroundLocationCapability = LocationContextCapability(
    availability: .available,
    supportsForegroundBroadPlace: true,
    supportsSignificantChanges: false
)

private let foregroundWeatherCapability = WeatherMirrorCapability(
    availability: .available,
    supportsCurrentConditions: true,
    supportsHourlyForecast: true,
    supportsDailyForecast: true
)

private func foregroundLocationFix(
    identifier: String,
    displayName: String,
    timeZoneID: String,
    latitude: Double,
    longitude: Double
) throws -> TransientLocationFix {
    let context = try BroadLocationContext(
        placeIdentifier: identifier,
        displayName: displayName,
        timeZoneID: timeZoneID,
        capturedAt: foregroundFixtureInstant.addingTimeInterval(-60),
        expiresAt: foregroundFixtureInstant.addingTimeInterval(7_200),
        precision: .locality
    )
    return try TransientLocationFix(
        context: context,
        latitude: latitude,
        longitude: longitude,
        horizontalAccuracyMeters: 5_000
    )
}

private func foregroundWeatherResponse(
    for context: BroadLocationContext,
    temperature: Double
) throws -> SyntheticWeatherResponse {
    let place = try WeatherPlaceContext(
        identifier: context.placeIdentifier,
        displayName: context.displayName,
        timeZoneID: context.timeZoneID
    )
    let snapshot = try WeatherContextSnapshot(
        place: place,
        sourceAsOf: foregroundFixtureInstant,
        fetchedAt: foregroundFixtureInstant,
        expiresAt: foregroundFixtureInstant.addingTimeInterval(3_600),
        current: WeatherInstantConditions(
            forecastAt: foregroundFixtureInstant,
            conditionCode: "synthetic_clear",
            temperatureCelsius: temperature,
            apparentTemperatureCelsius: temperature
        ),
        hourlyForecast: [],
        dailyForecast: [],
        attribution: WeatherProviderAttribution(
            providerName: "Synthetic Weather",
            attributionText: "Synthetic weather for foreground handoff testing.",
            legalPageURL: URL(string: "https://weather.example.test/legal")!
        )
    )
    return SyntheticWeatherResponse(
        expectedPlaceIdentifier: context.placeIdentifier,
        result: try WeatherMirrorResult(
            outcome: .fetched,
            snapshot: snapshot,
            rateLimitState: .ready
        )
    )
}
