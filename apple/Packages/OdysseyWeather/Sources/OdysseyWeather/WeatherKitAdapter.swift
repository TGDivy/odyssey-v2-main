#if canImport(WeatherKit) && canImport(CoreLocation)
@preconcurrency import CoreLocation
import Foundation
import OdysseyDomain
import OdysseyIntegrations
@preconcurrency import WeatherKit

public enum WeatherKitAdapterError: Error, Equatable, Sendable {
    case serviceFailure
    case invalidProviderData
}

public actor WeatherKitAdapter: WeatherContextProviding {
    private let service: WeatherService

    public init(service: WeatherService = .shared) {
        self.service = service
    }

    public func capability() async -> WeatherMirrorCapability {
        WeatherMirrorCapability(
            availability: .available,
            supportsCurrentConditions: true,
            supportsHourlyForecast: true,
            supportsDailyForecast: true
        )
    }

    public func permissionState() async -> IntegrationPermissionState {
        .notRequired
    }

    public func weather(
        for query: WeatherQueryLocation
    ) async throws -> WeatherMirrorResult {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: query.latitude,
                longitude: query.longitude
            ),
            altitude: 0,
            horizontalAccuracy: query.horizontalAccuracyMeters,
            verticalAccuracy: -1,
            timestamp: Date()
        )
        do {
            let weather = try await service.weather(for: location)
            let providerAttribution = try await service.attribution
            return try Self.result(
                weather: weather,
                providerAttribution: providerAttribution,
                place: query.place
            )
        } catch let error as WeatherError where error == .permissionDenied {
            return try WeatherMirrorResult(
                outcome: .unavailable,
                snapshot: nil,
                rateLimitState: .notApplicable
            )
        } catch is WeatherContextError {
            throw WeatherKitAdapterError.invalidProviderData
        } catch {
            throw WeatherKitAdapterError.serviceFailure
        }
    }

    private static func result(
        weather: Weather,
        providerAttribution: WeatherAttribution,
        place: WeatherPlaceContext
    ) throws -> WeatherMirrorResult {
        var rejectedRecordCount = 0
        let current = try instantConditions(weather.currentWeather)
        let hourlySource = weather.hourlyForecast.forecast.sorted {
            $0.date < $1.date
        }.prefix(72)
        let hourly = normalizedHourly(
            hourlySource,
            rejectedRecordCount: &rejectedRecordCount
        )
        let dailySource = weather.dailyForecast.forecast.sorted {
            $0.date < $1.date
        }.prefix(14)
        let daily = normalizedDaily(
            dailySource,
            timeZoneID: place.timeZoneID,
            rejectedRecordCount: &rejectedRecordCount
        )
        let fetchedAt = weather.currentWeather.metadata.date
        let expiresAt = [
            weather.currentWeather.metadata.expirationDate,
            weather.hourlyForecast.metadata.expirationDate,
            weather.dailyForecast.metadata.expirationDate,
        ].min() ?? weather.currentWeather.metadata.expirationDate
        let attribution = try WeatherProviderAttribution(
            providerName: "Apple Weather",
            attributionText: "Weather data provided by Apple Weather.",
            legalPageURL: providerAttribution.legalPageURL,
            combinedMarkLightURL: providerAttribution.combinedMarkLightURL,
            combinedMarkDarkURL: providerAttribution.combinedMarkDarkURL
        )
        let snapshot = try WeatherContextSnapshot(
            place: place,
            sourceAsOf: weather.currentWeather.date,
            fetchedAt: fetchedAt,
            expiresAt: expiresAt,
            current: current,
            hourlyForecast: hourly,
            dailyForecast: daily,
            attribution: attribution
        )
        return try WeatherMirrorResult(
            outcome: .fetched,
            snapshot: snapshot,
            rateLimitState: .ready,
            rejectedRecordCount: rejectedRecordCount
        )
    }

    private static func normalizedHourly<C: Collection>(
        _ forecast: C,
        rejectedRecordCount: inout Int
    ) -> [WeatherInstantConditions] where C.Element == HourWeather {
        var accepted = [Date: WeatherInstantConditions]()
        for hour in forecast {
            do {
                let conditions = try instantConditions(hour)
                if accepted.updateValue(
                    conditions,
                    forKey: conditions.forecastAt
                ) != nil {
                    rejectedRecordCount += 1
                }
            } catch {
                rejectedRecordCount += 1
            }
        }
        return accepted.values.sorted { $0.forecastAt < $1.forecastAt }
    }

    private static func normalizedDaily<C: Collection>(
        _ forecast: C,
        timeZoneID: String,
        rejectedRecordCount: inout Int
    ) -> [WeatherDailyForecast] where C.Element == DayWeather {
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            rejectedRecordCount += forecast.count
            return []
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var accepted = [LocalDate: WeatherDailyForecast]()
        for day in forecast {
            do {
                let components = calendar.dateComponents(
                    [.year, .month, .day],
                    from: day.date
                )
                guard let year = components.year,
                      let month = components.month,
                      let dayOfMonth = components.day
                else {
                    throw WeatherKitAdapterError.invalidProviderData
                }
                let localDate = LocalDate(
                    year: year,
                    month: month,
                    day: dayOfMonth
                )
                let daily = try WeatherDailyForecast(
                    localDate: localDate,
                    conditionCode: conditionCode(day.condition),
                    lowTemperatureCelsius: celsius(day.lowTemperature),
                    highTemperatureCelsius: celsius(day.highTemperature),
                    precipitationProbability: day.precipitationChance
                )
                if accepted.updateValue(daily, forKey: localDate) != nil {
                    rejectedRecordCount += 1
                }
            } catch {
                rejectedRecordCount += 1
            }
        }
        return accepted.values.sorted { $0.localDate < $1.localDate }
    }

    private static func instantConditions(
        _ current: CurrentWeather
    ) throws -> WeatherInstantConditions {
        try WeatherInstantConditions(
            forecastAt: current.date,
            conditionCode: conditionCode(current.condition),
            temperatureCelsius: celsius(current.temperature),
            apparentTemperatureCelsius: celsius(current.apparentTemperature),
            precipitationProbability: nil,
            precipitationMillimetersPerHour: millimetersPerHour(
                current.precipitationIntensity
            ),
            windMetersPerSecond: metersPerSecond(current.wind.speed),
            relativeHumidity: current.humidity,
            uvIndex: current.uvIndex.value
        )
    }

    private static func instantConditions(
        _ hour: HourWeather
    ) throws -> WeatherInstantConditions {
        try WeatherInstantConditions(
            forecastAt: hour.date,
            conditionCode: conditionCode(hour.condition),
            temperatureCelsius: celsius(hour.temperature),
            apparentTemperatureCelsius: celsius(hour.apparentTemperature),
            precipitationProbability: hour.precipitationChance,
            precipitationMillimetersPerHour: millimeters(
                hour.precipitationAmount
            ),
            windMetersPerSecond: metersPerSecond(hour.wind.speed),
            relativeHumidity: hour.humidity,
            uvIndex: hour.uvIndex.value
        )
    }

    private static func celsius(
        _ measurement: Measurement<UnitTemperature>
    ) -> Double {
        measurement.converted(to: .celsius).value
    }

    private static func metersPerSecond(
        _ measurement: Measurement<UnitSpeed>
    ) -> Double {
        measurement.converted(to: .metersPerSecond).value
    }

    private static func millimeters(
        _ measurement: Measurement<UnitLength>
    ) -> Double {
        measurement.converted(to: .millimeters).value
    }

    private static func millimetersPerHour(
        _ measurement: Measurement<UnitSpeed>
    ) -> Double {
        measurement.converted(to: .kilometersPerHour).value * 1_000_000
    }

    private static func conditionCode(
        _ condition: WeatherCondition
    ) -> String {
        switch condition {
        case .blowingDust: "blowing_dust"
        case .clear: "clear"
        case .cloudy: "cloudy"
        case .foggy: "foggy"
        case .haze: "haze"
        case .mostlyClear: "mostly_clear"
        case .mostlyCloudy: "mostly_cloudy"
        case .partlyCloudy: "partly_cloudy"
        case .smoky: "smoky"
        case .breezy: "breezy"
        case .windy: "windy"
        case .drizzle: "drizzle"
        case .heavyRain: "heavy_rain"
        case .isolatedThunderstorms: "isolated_thunderstorms"
        case .rain: "rain"
        case .sunShowers: "sun_showers"
        case .scatteredThunderstorms: "scattered_thunderstorms"
        case .strongStorms: "strong_storms"
        case .thunderstorms: "thunderstorms"
        case .frigid: "frigid"
        case .hail: "hail"
        case .hot: "hot"
        case .flurries: "flurries"
        case .sleet: "sleet"
        case .snow: "snow"
        case .sunFlurries: "sun_flurries"
        case .wintryMix: "wintry_mix"
        case .blizzard: "blizzard"
        case .blowingSnow: "blowing_snow"
        case .freezingDrizzle: "freezing_drizzle"
        case .freezingRain: "freezing_rain"
        case .heavySnow: "heavy_snow"
        case .hurricane: "hurricane"
        case .tropicalStorm: "tropical_storm"
        @unknown default: "unknown"
        }
    }
}
#endif
