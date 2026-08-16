import OdysseyIntegrations

public actor SyntheticLocationAdapter: LocationContextProviding {
    private let locationCapability: LocationContextCapability
    private let authorizationAfterRequest: IntegrationPermissionState
    private var permission: IntegrationPermissionState
    private var responses: [BroadLocationResult]

    public init(
        capability: LocationContextCapability,
        initialPermission: IntegrationPermissionState,
        authorizationAfterRequest: IntegrationPermissionState,
        responses: [BroadLocationResult] = []
    ) {
        locationCapability = capability
        permission = initialPermission
        self.authorizationAfterRequest = authorizationAfterRequest
        self.responses = responses
    }

    public func capability() async -> LocationContextCapability {
        locationCapability
    }

    public func authorizationState() async -> IntegrationPermissionState {
        permission
    }

    public func requestWhenInUseAuthorization() async -> IntegrationPermissionState {
        if permission == .notDetermined {
            permission = authorizationAfterRequest
        }
        return permission
    }

    public func currentBroadLocation() async throws -> BroadLocationResult {
        guard locationCapability.availability == .available,
              locationCapability.supportsForegroundBroadPlace
        else {
            return try BroadLocationResult(outcome: .unavailable, fix: nil)
        }
        switch permission {
        case .authorized:
            break
        case .restricted:
            return try BroadLocationResult(outcome: .restricted, fix: nil)
        case .unavailable:
            return try BroadLocationResult(outcome: .unavailable, fix: nil)
        case .denied, .notDetermined, .partial, .notRequired:
            return try BroadLocationResult(outcome: .permissionDenied, fix: nil)
        }
        guard !responses.isEmpty else {
            throw LocationContextError.unexpectedSyntheticRequest
        }
        return responses.removeFirst()
    }

    public func stopMonitoring() async {}
}

public struct UnavailableLocationAdapter: LocationContextProviding {
    public init() {}

    public func capability() async -> LocationContextCapability {
        LocationContextCapability(
            availability: .unavailable,
            supportsForegroundBroadPlace: false,
            supportsSignificantChanges: false
        )
    }

    public func authorizationState() async -> IntegrationPermissionState {
        .unavailable
    }

    public func requestWhenInUseAuthorization() async -> IntegrationPermissionState {
        .unavailable
    }

    public func currentBroadLocation() async throws -> BroadLocationResult {
        try BroadLocationResult(outcome: .unavailable, fix: nil)
    }

    public func stopMonitoring() async {}
}
