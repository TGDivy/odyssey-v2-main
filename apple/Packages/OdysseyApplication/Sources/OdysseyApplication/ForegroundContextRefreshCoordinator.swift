import Foundation
import OdysseyLocation
import OdysseyWeather

public enum ForegroundWeatherRefreshState: Hashable, Sendable {
    case notAttempted
    case completed(WeatherMirrorRunReceipt)
    case failed
}

public struct ForegroundContextRefreshReceipt: Hashable, Sendable {
    public let locationOutcome: BroadLocationOutcome
    public let locationAttemptedAt: Date
    public let weatherRefresh: ForegroundWeatherRefreshState

    init(
        locationOutcome: BroadLocationOutcome,
        locationAttemptedAt: Date,
        weatherRefresh: ForegroundWeatherRefreshState
    ) {
        self.locationOutcome = locationOutcome
        self.locationAttemptedAt = locationAttemptedAt
        self.weatherRefresh = weatherRefresh
    }
}

public struct ForegroundContextRefreshCoordinator: Sendable {
    private let locationCoordinator: LocationContextCoordinator
    private let weatherCoordinator: WeatherMirrorCoordinator

    public init(
        locationCoordinator: LocationContextCoordinator,
        weatherCoordinator: WeatherMirrorCoordinator
    ) {
        self.locationCoordinator = locationCoordinator
        self.weatherCoordinator = weatherCoordinator
    }

    public func refresh() async throws -> ForegroundContextRefreshReceipt {
        let location = try await locationCoordinator.refresh()
        guard let fix = location.transientFix else {
            return ForegroundContextRefreshReceipt(
                locationOutcome: location.outcome,
                locationAttemptedAt: location.attemptedAt,
                weatherRefresh: .notAttempted
            )
        }
        let place = try WeatherPlaceContext(
            identifier: fix.context.placeIdentifier,
            displayName: fix.context.displayName,
            timeZoneID: fix.context.timeZoneID
        )
        let query = try WeatherQueryLocation(
            place: place,
            latitude: fix.latitude,
            longitude: fix.longitude,
            horizontalAccuracyMeters: fix.horizontalAccuracyMeters
        )
        let weatherRefresh: ForegroundWeatherRefreshState
        do {
            weatherRefresh = .completed(
                try await weatherCoordinator.refresh(for: query)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            weatherRefresh = .failed
        }
        return ForegroundContextRefreshReceipt(
            locationOutcome: location.outcome,
            locationAttemptedAt: location.attemptedAt,
            weatherRefresh: weatherRefresh
        )
    }
}
