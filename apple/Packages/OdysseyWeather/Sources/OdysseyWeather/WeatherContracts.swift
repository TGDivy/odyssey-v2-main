import Foundation
import OdysseyDomain
import OdysseyIntegrations

public enum WeatherContextError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidText
    case invalidLocation
    case invalidClock
    case invalidValue
    case invalidAttribution
    case invalidForecast
    case invalidResult
    case unexpectedSyntheticQuery
}

public struct WeatherPlaceContext: Codable, Hashable, Sendable {
    public let identifier: String
    public let displayName: String?
    public let timeZoneID: String

    public init(
        identifier: String,
        displayName: String?,
        timeZoneID: String
    ) throws {
        guard WeatherValidation.validToken(identifier, maximum: 100) else {
            throw WeatherContextError.invalidIdentifier
        }
        guard WeatherValidation.validOptionalText(displayName, maximum: 200) else {
            throw WeatherContextError.invalidText
        }
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw WeatherContextError.invalidLocation
        }
        self.identifier = identifier
        self.displayName = displayName
        self.timeZoneID = timeZoneID
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case displayName
        case timeZoneID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: values.decode(String.self, forKey: .identifier),
            displayName: values.decodeIfPresent(String.self, forKey: .displayName),
            timeZoneID: values.decode(String.self, forKey: .timeZoneID)
        )
    }
}

public struct WeatherQueryLocation: Hashable, Sendable {
    public let place: WeatherPlaceContext
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double

    public init(
        place: WeatherPlaceContext,
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double
    ) throws {
        guard latitude.isFinite,
              longitude.isFinite,
              horizontalAccuracyMeters.isFinite,
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude),
              (0 ... 100_000).contains(horizontalAccuracyMeters)
        else {
            throw WeatherContextError.invalidLocation
        }
        self.place = place
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
    }
}

public struct WeatherProviderAttribution: Codable, Hashable, Sendable {
    public let providerName: String
    public let attributionText: String
    public let legalPageURL: URL

    public init(
        providerName: String,
        attributionText: String,
        legalPageURL: URL
    ) throws {
        guard WeatherValidation.validText(providerName, maximum: 200),
              WeatherValidation.validText(attributionText, maximum: 1_000),
              legalPageURL.scheme?.lowercased() == "https",
              legalPageURL.host != nil,
              legalPageURL.user == nil,
              legalPageURL.password == nil
        else {
            throw WeatherContextError.invalidAttribution
        }
        self.providerName = providerName
        self.attributionText = attributionText
        self.legalPageURL = legalPageURL
    }

    private enum CodingKeys: String, CodingKey {
        case providerName
        case attributionText
        case legalPageURL
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerName: values.decode(String.self, forKey: .providerName),
            attributionText: values.decode(String.self, forKey: .attributionText),
            legalPageURL: values.decode(URL.self, forKey: .legalPageURL)
        )
    }
}

public struct WeatherInstantConditions: Codable, Hashable, Sendable {
    public let forecastAt: Date
    public let conditionCode: String
    public let temperatureCelsius: Double
    public let apparentTemperatureCelsius: Double
    public let precipitationProbability: Double?
    public let precipitationMillimetersPerHour: Double?
    public let windMetersPerSecond: Double?
    public let relativeHumidity: Double?
    public let uvIndex: Int?

    public init(
        forecastAt: Date,
        conditionCode: String,
        temperatureCelsius: Double,
        apparentTemperatureCelsius: Double,
        precipitationProbability: Double? = nil,
        precipitationMillimetersPerHour: Double? = nil,
        windMetersPerSecond: Double? = nil,
        relativeHumidity: Double? = nil,
        uvIndex: Int? = nil
    ) throws {
        guard forecastAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WeatherContextError.invalidClock
        }
        guard WeatherValidation.validToken(conditionCode, maximum: 100),
              WeatherValidation.validTemperature(temperatureCelsius),
              WeatherValidation.validTemperature(apparentTemperatureCelsius),
              WeatherValidation.validFraction(precipitationProbability),
              WeatherValidation.validOptional(
                  precipitationMillimetersPerHour,
                  range: 0 ... 10_000
              ), WeatherValidation.validOptional(
                  windMetersPerSecond,
                  range: 0 ... 250
              ), WeatherValidation.validFraction(relativeHumidity),
              uvIndex.map({ (0 ... 100).contains($0) }) ?? true
        else {
            throw WeatherContextError.invalidValue
        }
        self.forecastAt = forecastAt
        self.conditionCode = conditionCode
        self.temperatureCelsius = temperatureCelsius
        self.apparentTemperatureCelsius = apparentTemperatureCelsius
        self.precipitationProbability = precipitationProbability
        self.precipitationMillimetersPerHour = precipitationMillimetersPerHour
        self.windMetersPerSecond = windMetersPerSecond
        self.relativeHumidity = relativeHumidity
        self.uvIndex = uvIndex
    }

    private enum CodingKeys: String, CodingKey {
        case forecastAt
        case conditionCode
        case temperatureCelsius
        case apparentTemperatureCelsius
        case precipitationProbability
        case precipitationMillimetersPerHour
        case windMetersPerSecond
        case relativeHumidity
        case uvIndex
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            forecastAt: values.decode(Date.self, forKey: .forecastAt),
            conditionCode: values.decode(String.self, forKey: .conditionCode),
            temperatureCelsius: values.decode(
                Double.self,
                forKey: .temperatureCelsius
            ),
            apparentTemperatureCelsius: values.decode(
                Double.self,
                forKey: .apparentTemperatureCelsius
            ),
            precipitationProbability: values.decodeIfPresent(
                Double.self,
                forKey: .precipitationProbability
            ),
            precipitationMillimetersPerHour: values.decodeIfPresent(
                Double.self,
                forKey: .precipitationMillimetersPerHour
            ),
            windMetersPerSecond: values.decodeIfPresent(
                Double.self,
                forKey: .windMetersPerSecond
            ),
            relativeHumidity: values.decodeIfPresent(
                Double.self,
                forKey: .relativeHumidity
            ),
            uvIndex: values.decodeIfPresent(Int.self, forKey: .uvIndex)
        )
    }
}

public struct WeatherDailyForecast: Codable, Hashable, Sendable {
    public let localDate: LocalDate
    public let conditionCode: String
    public let lowTemperatureCelsius: Double
    public let highTemperatureCelsius: Double
    public let precipitationProbability: Double?

    public init(
        localDate: LocalDate,
        conditionCode: String,
        lowTemperatureCelsius: Double,
        highTemperatureCelsius: Double,
        precipitationProbability: Double? = nil
    ) throws {
        guard WeatherValidation.validLocalDate(localDate),
              WeatherValidation.validToken(conditionCode, maximum: 100),
              WeatherValidation.validTemperature(lowTemperatureCelsius),
              WeatherValidation.validTemperature(highTemperatureCelsius),
              lowTemperatureCelsius <= highTemperatureCelsius,
              WeatherValidation.validFraction(precipitationProbability)
        else {
            throw WeatherContextError.invalidForecast
        }
        self.localDate = localDate
        self.conditionCode = conditionCode
        self.lowTemperatureCelsius = lowTemperatureCelsius
        self.highTemperatureCelsius = highTemperatureCelsius
        self.precipitationProbability = precipitationProbability
    }

    private enum CodingKeys: String, CodingKey {
        case localDate
        case conditionCode
        case lowTemperatureCelsius
        case highTemperatureCelsius
        case precipitationProbability
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            localDate: values.decode(LocalDate.self, forKey: .localDate),
            conditionCode: values.decode(String.self, forKey: .conditionCode),
            lowTemperatureCelsius: values.decode(
                Double.self,
                forKey: .lowTemperatureCelsius
            ),
            highTemperatureCelsius: values.decode(
                Double.self,
                forKey: .highTemperatureCelsius
            ),
            precipitationProbability: values.decodeIfPresent(
                Double.self,
                forKey: .precipitationProbability
            )
        )
    }
}

public struct WeatherContextSnapshot: Codable, Hashable, Sendable {
    public let place: WeatherPlaceContext
    public let sourceAsOf: Date
    public let fetchedAt: Date
    public let expiresAt: Date
    public let current: WeatherInstantConditions
    public let hourlyForecast: [WeatherInstantConditions]
    public let dailyForecast: [WeatherDailyForecast]
    public let attribution: WeatherProviderAttribution

    public init(
        place: WeatherPlaceContext,
        sourceAsOf: Date,
        fetchedAt: Date,
        expiresAt: Date,
        current: WeatherInstantConditions,
        hourlyForecast: [WeatherInstantConditions],
        dailyForecast: [WeatherDailyForecast],
        attribution: WeatherProviderAttribution
    ) throws {
        guard sourceAsOf.timeIntervalSinceReferenceDate.isFinite,
              fetchedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              sourceAsOf <= fetchedAt.addingTimeInterval(5 * 60),
              expiresAt > fetchedAt,
              expiresAt <= fetchedAt.addingTimeInterval(24 * 60 * 60)
        else {
            throw WeatherContextError.invalidClock
        }
        guard hourlyForecast.count <= 72,
              dailyForecast.count <= 14,
              Self.strictlyIncreasing(hourlyForecast.map(\.forecastAt)),
              Self.strictlyIncreasing(dailyForecast.map(\.localDate))
        else {
            throw WeatherContextError.invalidForecast
        }
        self.place = place
        self.sourceAsOf = sourceAsOf
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.current = current
        self.hourlyForecast = hourlyForecast
        self.dailyForecast = dailyForecast
        self.attribution = attribution
    }

    public var isFresh: Bool {
        expiresAt > Date()
    }

    private static func strictlyIncreasing<T: Comparable>(_ values: [T]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy(<)
    }

    private enum CodingKeys: String, CodingKey {
        case place
        case sourceAsOf
        case fetchedAt
        case expiresAt
        case current
        case hourlyForecast
        case dailyForecast
        case attribution
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            place: values.decode(WeatherPlaceContext.self, forKey: .place),
            sourceAsOf: values.decode(Date.self, forKey: .sourceAsOf),
            fetchedAt: values.decode(Date.self, forKey: .fetchedAt),
            expiresAt: values.decode(Date.self, forKey: .expiresAt),
            current: values.decode(WeatherInstantConditions.self, forKey: .current),
            hourlyForecast: values.decode(
                [WeatherInstantConditions].self,
                forKey: .hourlyForecast
            ),
            dailyForecast: values.decode(
                [WeatherDailyForecast].self,
                forKey: .dailyForecast
            ),
            attribution: values.decode(
                WeatherProviderAttribution.self,
                forKey: .attribution
            )
        )
    }
}

public enum WeatherMirrorOutcome: String, Codable, Hashable, Sendable {
    case fetched
    case unavailable
    case rateLimited = "rate_limited"
}

public struct WeatherMirrorResult: Hashable, Sendable {
    public let outcome: WeatherMirrorOutcome
    public let snapshot: WeatherContextSnapshot?
    public let rateLimitState: IntegrationRateLimitState
    public let rejectedRecordCount: Int

    public init(
        outcome: WeatherMirrorOutcome,
        snapshot: WeatherContextSnapshot?,
        rateLimitState: IntegrationRateLimitState,
        rejectedRecordCount: Int = 0
    ) throws {
        guard (0 ... 1_000_000).contains(rejectedRecordCount) else {
            throw WeatherContextError.invalidResult
        }
        switch outcome {
        case .fetched:
            guard snapshot != nil, rateLimitState != .limited else {
                throw WeatherContextError.invalidResult
            }
        case .unavailable:
            guard snapshot == nil, rateLimitState != .limited else {
                throw WeatherContextError.invalidResult
            }
        case .rateLimited:
            guard snapshot == nil, rateLimitState == .limited else {
                throw WeatherContextError.invalidResult
            }
        }
        self.outcome = outcome
        self.snapshot = snapshot
        self.rateLimitState = rateLimitState
        self.rejectedRecordCount = rejectedRecordCount
    }
}

public struct WeatherMirrorCapability: Hashable, Sendable {
    public let availability: IntegrationCapabilityAvailability
    public let supportsCurrentConditions: Bool
    public let supportsHourlyForecast: Bool
    public let supportsDailyForecast: Bool

    public init(
        availability: IntegrationCapabilityAvailability,
        supportsCurrentConditions: Bool,
        supportsHourlyForecast: Bool,
        supportsDailyForecast: Bool
    ) {
        self.availability = availability
        self.supportsCurrentConditions = supportsCurrentConditions
        self.supportsHourlyForecast = supportsHourlyForecast
        self.supportsDailyForecast = supportsDailyForecast
    }
}

public protocol WeatherContextProviding: Sendable {
    func capability() async -> WeatherMirrorCapability
    func permissionState() async -> IntegrationPermissionState
    func weather(
        for query: WeatherQueryLocation
    ) async throws -> WeatherMirrorResult
}

private enum WeatherValidation {
    static func validToken(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.allSatisfy {
                (48 ... 57).contains($0)
                    || (65 ... 90).contains($0)
                    || (97 ... 122).contains($0)
                    || [45, 46, 58, 95].contains($0)
            }
    }

    static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        value.map { validText($0, maximum: maximum) } ?? true
    }

    static func validTemperature(_ value: Double) -> Bool {
        value.isFinite && (-150 ... 100).contains(value)
    }

    static func validFraction(_ value: Double?) -> Bool {
        validOptional(value, range: 0 ... 1)
    }

    static func validOptional(
        _ value: Double?,
        range: ClosedRange<Double>
    ) -> Bool {
        value.map { $0.isFinite && range.contains($0) } ?? true
    }

    static func validLocalDate(_ date: LocalDate) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            year: date.year,
            month: date.month,
            day: date.day
        )
        guard let normalized = calendar.date(from: components) else {
            return false
        }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day],
            from: normalized
        )
        return roundTrip.year == date.year
            && roundTrip.month == date.month
            && roundTrip.day == date.day
    }
}
