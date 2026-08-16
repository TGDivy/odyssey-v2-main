import Foundation
import OdysseyTelemetry

public enum WeeklyProductReviewServiceError: Error, Equatable, Sendable {
    case invalidClock
    case featureConfigurationUnavailable
    case telemetryStorageUnavailable
    case artifactGenerationFailed
}

public enum WeeklyProductReviewAvailability: Hashable, Sendable {
    case available(WeeklyProductReviewArtifact)
    case disabledByFeatureFlag
}

public struct WeeklyProductReviewService: Sendable {
    private let store: any ProductTelemetryStoring
    private let featureAssignments: @Sendable () throws -> [FeatureFlagKey: String]
    private let clock: @Sendable () -> Date

    public init(
        store: any ProductTelemetryStoring,
        featureAssignments: @escaping @Sendable () throws -> [FeatureFlagKey: String],
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.featureAssignments = featureAssignments
        self.clock = clock
    }

    public func generate() throws -> WeeklyProductReviewAvailability {
        let generatedAt = clock()
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WeeklyProductReviewServiceError.invalidClock
        }
        let assignments: [FeatureFlagKey: String]
        do {
            assignments = try featureAssignments()
        } catch {
            throw WeeklyProductReviewServiceError.featureConfigurationUnavailable
        }
        guard assignments[.weeklyProductReview] == "enabled" else {
            return .disabledByFeatureFlag
        }

        let periodStart = generatedAt.addingTimeInterval(
            -WeeklyProductReviewGenerator.reviewDuration
        )
        let preferences: ProductTelemetryPreferences
        let events: [ProductTelemetryEvent]
        do {
            preferences = try store.productTelemetryPreferences()
            events = try store.productTelemetryEvents(
                from: periodStart,
                to: generatedAt,
                limit: WeeklyProductReviewGenerator.maximumEventCount
            )
        } catch {
            throw WeeklyProductReviewServiceError.telemetryStorageUnavailable
        }
        do {
            return .available(try WeeklyProductReviewGenerator().generate(
                events: events,
                preferences: preferences,
                periodStart: periodStart,
                periodEnd: generatedAt,
                generatedAt: generatedAt,
                sourceTruncated: events.count == WeeklyProductReviewGenerator.maximumEventCount
            ))
        } catch {
            throw WeeklyProductReviewServiceError.artifactGenerationFailed
        }
    }
}
