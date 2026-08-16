import OdysseyData
import OdysseyTelemetry

public actor FeatureConfigurationRefreshCoordinator {
    private let cache: any FeatureConfigurationCaching
    private let transport: any FeatureConfigurationTransport
    private let audience: String
    private let assignmentSubject: String
    private var activeRefresh: Task<FeatureConfigurationResolution, Error>?

    public init(
        cache: any FeatureConfigurationCaching,
        transport: any FeatureConfigurationTransport,
        audience: String,
        assignmentSubject: String
    ) {
        self.cache = cache
        self.transport = transport
        self.audience = audience
        self.assignmentSubject = assignmentSubject
    }

    public func current() throws -> FeatureConfigurationResolution {
        try cache.resolveFeatureConfiguration(assignmentSubject: assignmentSubject)
    }

    public func refresh() async throws -> FeatureConfigurationResolution {
        if let activeRefresh {
            return try await activeRefresh.value
        }
        let task = Task { try await performRefresh() }
        activeRefresh = task
        defer { activeRefresh = nil }
        return try await task.value
    }

    public func cancelRefresh() {
        activeRefresh?.cancel()
    }

    private func performRefresh() async throws -> FeatureConfigurationResolution {
        let envelope = try await transport.currentConfiguration(audience: audience)
        _ = try cache.cacheFeatureConfiguration(envelope)
        return try cache.resolveFeatureConfiguration(assignmentSubject: assignmentSubject)
    }
}
