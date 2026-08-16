import Foundation
import OdysseyDomain
import OdysseyIntegrations
import OdysseyWeather
import Testing

private let weatherContractDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func weatherSnapshotPreservesFreshnessForecastAndRequiredAttributionWithoutCoordinates() throws {
    let snapshot = try weatherSnapshot()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshot)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let roundTrip = try decoder.decode(WeatherContextSnapshot.self, from: data)
    let encoded = String(decoding: data, as: UTF8.self)

    #expect(roundTrip == snapshot)
    #expect(roundTrip.place.identifier == "broad_place_1")
    #expect(roundTrip.hourlyForecast.count == 2)
    #expect(roundTrip.dailyForecast.count == 2)
    #expect(roundTrip.attribution.legalPageURL.scheme == "https")
    #expect(!encoded.contains("latitude"))
    #expect(!encoded.contains("longitude"))
    #expect(!encoded.contains("horizontalAccuracyMeters"))
}

@Test
func weatherSnapshotRejectsInvalidFreshnessAndForecastOrdering() throws {
    let place = try weatherPlace()
    let attribution = try weatherAttribution()
    let current = try weatherConditions(at: weatherContractDate)

    #expect(throws: WeatherContextError.invalidClock) {
        try WeatherContextSnapshot(
            place: place,
            sourceAsOf: weatherContractDate,
            fetchedAt: weatherContractDate,
            expiresAt: weatherContractDate,
            current: current,
            hourlyForecast: [],
            dailyForecast: [],
            attribution: attribution
        )
    }
    #expect(throws: WeatherContextError.invalidForecast) {
        try WeatherContextSnapshot(
            place: place,
            sourceAsOf: weatherContractDate,
            fetchedAt: weatherContractDate,
            expiresAt: weatherContractDate.addingTimeInterval(3_600),
            current: current,
            hourlyForecast: [
                try weatherConditions(at: weatherContractDate.addingTimeInterval(7_200)),
                try weatherConditions(at: weatherContractDate.addingTimeInterval(3_600)),
            ],
            dailyForecast: [],
            attribution: attribution
        )
    }
    #expect(throws: WeatherContextError.invalidForecast) {
        try WeatherDailyForecast(
            localDate: LocalDate(year: 2026, month: 2, day: 30),
            conditionCode: "clear",
            lowTemperatureCelsius: 5,
            highTemperatureCelsius: 10
        )
    }
    #expect(throws: WeatherContextError.invalidResult) {
        try WeatherMirrorResult(
            outcome: .unavailable,
            snapshot: nil,
            rateLimitState: .limited
        )
    }
}

@Test
func syntheticWeatherAdapterUsesTransientQueryLocationAndExplicitOutcomes() async throws {
    let snapshot = try weatherSnapshot()
    let fetched = try WeatherMirrorResult(
        outcome: .fetched,
        snapshot: snapshot,
        rateLimitState: .ready
    )
    let adapter = SyntheticWeatherAdapter(
        capability: WeatherMirrorCapability(
            availability: .available,
            supportsCurrentConditions: true,
            supportsHourlyForecast: true,
            supportsDailyForecast: true
        ),
        responses: [SyntheticWeatherResponse(
            expectedPlaceIdentifier: snapshot.place.identifier,
            result: fetched
        )]
    )
    let query = try WeatherQueryLocation(
        place: snapshot.place,
        latitude: 40.7,
        longitude: -74,
        horizontalAccuracyMeters: 5_000
    )

    #expect(await adapter.permissionState() == .notRequired)
    #expect(try await adapter.weather(for: query) == fetched)
    await #expect(throws: WeatherContextError.unexpectedSyntheticQuery) {
        try await adapter.weather(for: query)
    }
}

private func weatherSnapshot() throws -> WeatherContextSnapshot {
    try WeatherContextSnapshot(
        place: weatherPlace(),
        sourceAsOf: weatherContractDate,
        fetchedAt: weatherContractDate,
        expiresAt: weatherContractDate.addingTimeInterval(3_600),
        current: weatherConditions(at: weatherContractDate),
        hourlyForecast: [
            weatherConditions(at: weatherContractDate.addingTimeInterval(3_600)),
            weatherConditions(at: weatherContractDate.addingTimeInterval(7_200)),
        ],
        dailyForecast: [
            WeatherDailyForecast(
                localDate: LocalDate(year: 2026, month: 8, day: 16),
                conditionCode: "partly_cloudy",
                lowTemperatureCelsius: 18,
                highTemperatureCelsius: 27,
                precipitationProbability: 0.2
            ),
            WeatherDailyForecast(
                localDate: LocalDate(year: 2026, month: 8, day: 17),
                conditionCode: "rain",
                lowTemperatureCelsius: 17,
                highTemperatureCelsius: 24,
                precipitationProbability: 0.7
            ),
        ],
        attribution: weatherAttribution()
    )
}

private func weatherConditions(
    at date: Date
) throws -> WeatherInstantConditions {
    try WeatherInstantConditions(
        forecastAt: date,
        conditionCode: "partly_cloudy",
        temperatureCelsius: 24,
        apparentTemperatureCelsius: 25,
        precipitationProbability: 0.2,
        precipitationMillimetersPerHour: 0,
        windMetersPerSecond: 3,
        relativeHumidity: 0.6,
        uvIndex: 5
    )
}

private func weatherPlace() throws -> WeatherPlaceContext {
    try WeatherPlaceContext(
        identifier: "broad_place_1",
        displayName: "Synthetic Metro",
        timeZoneID: "America/New_York"
    )
}

private func weatherAttribution() throws -> WeatherProviderAttribution {
    try WeatherProviderAttribution(
        providerName: "Synthetic Weather",
        attributionText: "Synthetic forecast for contract testing.",
        legalPageURL: URL(string: "https://weather.example.test/legal")!
    )
}
