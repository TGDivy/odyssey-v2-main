import Foundation
import OdysseyData
import OdysseyTelemetry

public enum ProductTelemetryPrivacyServiceError: Error, Equatable, Sendable {
    case invalidClock
    case telemetryStorageUnavailable
}

public struct ProductTelemetryPrivacySnapshot: Hashable, Sendable {
    public let summary: ProductTelemetrySummary
    public let recorderDiagnostics: ProductTelemetryRecorderDiagnostics
    public let featureConfiguration: FeatureConfigurationResolution?

    public init(
        summary: ProductTelemetrySummary,
        recorderDiagnostics: ProductTelemetryRecorderDiagnostics,
        featureConfiguration: FeatureConfigurationResolution?
    ) {
        self.summary = summary
        self.recorderDiagnostics = recorderDiagnostics
        self.featureConfiguration = featureConfiguration
    }
}

public actor ProductTelemetryPrivacyService {
    private let store: any ProductTelemetryStoring
    private let recorder: ProductTelemetryRecorder
    private let featureConfiguration: @Sendable () throws -> FeatureConfigurationResolution
    private let clock: @Sendable () -> Date

    public init(
        store: any ProductTelemetryStoring,
        recorder: ProductTelemetryRecorder,
        featureConfiguration: @escaping @Sendable () throws -> FeatureConfigurationResolution,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.recorder = recorder
        self.featureConfiguration = featureConfiguration
        self.clock = clock
    }

    public func snapshot() async throws -> ProductTelemetryPrivacySnapshot {
        let generatedAt = try currentDate()
        let summary: ProductTelemetrySummary
        do {
            summary = try store.productTelemetrySummary(at: generatedAt)
        } catch {
            throw ProductTelemetryPrivacyServiceError.telemetryStorageUnavailable
        }
        return ProductTelemetryPrivacySnapshot(
            summary: summary,
            recorderDiagnostics: await recorder.diagnostics(),
            featureConfiguration: try? featureConfiguration()
        )
    }

    public func updatePreferences(
        _ preferences: ProductTelemetryPreferences
    ) throws {
        do {
            try store.putProductTelemetryPreferences(
                preferences,
                updatedAt: try currentDate()
            )
        } catch let error as ProductTelemetryPrivacyServiceError {
            throw error
        } catch {
            throw ProductTelemetryPrivacyServiceError.telemetryStorageUnavailable
        }
    }

    @discardableResult
    public func deleteAllEvents() throws -> Int {
        do {
            return try store.deleteAllProductTelemetry()
        } catch {
            throw ProductTelemetryPrivacyServiceError.telemetryStorageUnavailable
        }
    }

    private func currentDate() throws -> Date {
        let date = clock()
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ProductTelemetryPrivacyServiceError.invalidClock
        }
        return date
    }
}
