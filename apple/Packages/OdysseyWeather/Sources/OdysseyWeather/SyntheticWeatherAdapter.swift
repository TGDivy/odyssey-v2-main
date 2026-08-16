import Foundation
import OdysseyIntegrations

public struct SyntheticWeatherResponse: Hashable, Sendable {
    public let expectedPlaceIdentifier: String
    public let result: WeatherMirrorResult

    public init(
        expectedPlaceIdentifier: String,
        result: WeatherMirrorResult
    ) {
        self.expectedPlaceIdentifier = expectedPlaceIdentifier
        self.result = result
    }
}

public actor SyntheticWeatherAdapter: WeatherContextProviding {
    private let mirrorCapability: WeatherMirrorCapability
    private var responses: [SyntheticWeatherResponse]

    public init(
        capability: WeatherMirrorCapability,
        responses: [SyntheticWeatherResponse] = []
    ) {
        mirrorCapability = capability
        self.responses = responses
    }

    public func capability() async -> WeatherMirrorCapability {
        mirrorCapability
    }

    public func permissionState() async -> IntegrationPermissionState {
        .notRequired
    }

    public func weather(
        for query: WeatherQueryLocation
    ) async throws -> WeatherMirrorResult {
        guard mirrorCapability.availability == .available else {
            return try WeatherMirrorResult(
                outcome: .unavailable,
                snapshot: nil,
                rateLimitState: .notApplicable
            )
        }
        guard let index = responses.firstIndex(where: {
            $0.expectedPlaceIdentifier == query.place.identifier
        }) else {
            throw WeatherContextError.unexpectedSyntheticQuery
        }
        return responses.remove(at: index).result
    }
}

public struct UnavailableWeatherAdapter: WeatherContextProviding {
    public init() {}

    public func capability() async -> WeatherMirrorCapability {
        WeatherMirrorCapability(
            availability: .unavailable,
            supportsCurrentConditions: false,
            supportsHourlyForecast: false,
            supportsDailyForecast: false
        )
    }

    public func permissionState() async -> IntegrationPermissionState {
        .notRequired
    }

    public func weather(
        for _: WeatherQueryLocation
    ) async throws -> WeatherMirrorResult {
        try WeatherMirrorResult(
            outcome: .unavailable,
            snapshot: nil,
            rateLimitState: .notApplicable
        )
    }
}
