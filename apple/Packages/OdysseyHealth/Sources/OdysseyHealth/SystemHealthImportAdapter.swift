import Foundation
import OdysseyIntegrations

public struct UnavailableHealthImportAdapter: IncrementalHealthImporting {
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    public func capability() async -> HealthImportCapability {
        HealthImportCapability(
            availability: .unavailable,
            supportedKinds: []
        )
    }

    public func authorizationState(
        for _: Set<HealthSampleKind>
    ) async -> IntegrationPermissionState {
        .unavailable
    }

    public func requestAuthorization(
        for _: Set<HealthSampleKind>
    ) async throws -> IntegrationPermissionState {
        .unavailable
    }

    public func changes(
        for kind: HealthSampleKind,
        after _: HealthImportCursor?,
        limit: Int
    ) async throws -> HealthImportBatch {
        guard (1 ... 500).contains(limit) else {
            throw HealthImportError.invalidBatch
        }
        return try HealthImportBatch(
            kind: kind,
            queriedAt: clock(),
            samples: [],
            deletedIdentities: [],
            nextCursor: nil,
            outcome: .unavailable
        )
    }
}

public enum SystemHealthImportAdapter {
    public static func make() -> any IncrementalHealthImporting {
        #if canImport(HealthKit)
        HealthKitIncrementalImportAdapter()
        #else
        UnavailableHealthImportAdapter()
        #endif
    }
}
