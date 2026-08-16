import Foundation

public enum IntegrationContractError: Error, Equatable, Sendable {
    case invalidClock
    case invalidRecordCount
    case mismatchedContribution
    case duplicateCapability
    case duplicateConnector
}

public enum IntegrationConnector: String, Codable, CaseIterable, Hashable, Sendable {
    case health
    case calendar
    case weather
    case location
}

public enum IntegrationDeviceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case iPhone
    case iPad
    case mac
    case watch
}

public enum IntegrationCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case healthSampleRead = "health_sample_read"
    case healthNutrientWrite = "health_nutrient_write"
    case calendarRead = "calendar_read"
    case calendarWrite = "calendar_write"
    case currentWeather = "current_weather"
    case weatherForecast = "weather_forecast"
    case foregroundLocation = "foreground_location"
    case significantLocation = "significant_location"

    public var connector: IntegrationConnector {
        switch self {
        case .healthSampleRead, .healthNutrientWrite:
            .health
        case .calendarRead, .calendarWrite:
            .calendar
        case .currentWeather, .weatherForecast:
            .weather
        case .foregroundLocation, .significantLocation:
            .location
        }
    }
}

public enum IntegrationCapabilityAvailability: String, Codable, Hashable, Sendable {
    case available
    case unavailable
    case unsupported
    case disabledByPolicy = "disabled_by_policy"
}

public enum IntegrationPermissionState: String, Codable, Hashable, Sendable {
    case notRequired = "not_required"
    case notDetermined = "not_determined"
    case denied
    case restricted
    case authorized
    case partial
    case unavailable
}

public struct IntegrationCapabilityStatus: Codable, Hashable, Sendable {
    public let capability: IntegrationCapability
    public let availability: IntegrationCapabilityAvailability
    public let permission: IntegrationPermissionState

    public init(
        capability: IntegrationCapability,
        availability: IntegrationCapabilityAvailability,
        permission: IntegrationPermissionState
    ) {
        self.capability = capability
        self.availability = availability
        self.permission = permission
    }
}

public struct DeviceCapabilityMatrix: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let device: IntegrationDeviceKind
    public let capabilities: [IntegrationCapabilityStatus]

    public init(
        generatedAt: Date,
        device: IntegrationDeviceKind,
        capabilities: [IntegrationCapabilityStatus]
    ) throws {
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw IntegrationContractError.invalidClock
        }
        guard Set(capabilities.map(\.capability)).count == capabilities.count else {
            throw IntegrationContractError.duplicateCapability
        }
        self.generatedAt = generatedAt
        self.device = device
        self.capabilities = capabilities.sorted {
            $0.capability.rawValue < $1.capability.rawValue
        }
    }

    public func status(
        for capability: IntegrationCapability
    ) -> IntegrationCapabilityStatus? {
        capabilities.first { $0.capability == capability }
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case device
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            generatedAt: values.decode(Date.self, forKey: .generatedAt),
            device: values.decode(IntegrationDeviceKind.self, forKey: .device),
            capabilities: values.decode(
                [IntegrationCapabilityStatus].self,
                forKey: .capabilities
            )
        )
    }
}

public enum IntegrationOperationalState: String, Codable, Hashable, Sendable {
    case disabled
    case idle
    case syncing
    case healthy
    case degraded
    case failed
    case revoked
}

public enum IntegrationRateLimitState: String, Codable, Hashable, Sendable {
    case notApplicable = "not_applicable"
    case ready
    case limited
}

public enum IntegrationContribution: String, Codable, CaseIterable, Hashable, Sendable {
    case approvedHealthContext = "approved_health_context"
    case calendarConstraints = "calendar_constraints"
    case planningWeather = "planning_weather"
    case broadForegroundPlace = "broad_foreground_place"

    public var connector: IntegrationConnector {
        switch self {
        case .approvedHealthContext:
            .health
        case .calendarConstraints:
            .calendar
        case .planningWeather:
            .weather
        case .broadForegroundPlace:
            .location
        }
    }
}

public struct IntegrationHealthSnapshot: Codable, Hashable, Sendable {
    public let connector: IntegrationConnector
    public let observedAt: Date
    public let operationalState: IntegrationOperationalState
    public let permission: IntegrationPermissionState
    public let lastSuccessfulSync: Date?
    public let newestSourceTimestamp: Date?
    public let credentialExpiresAt: Date?
    public let rejectedRecordCount: Int
    public let schemaVersionMismatch: Bool
    public let rateLimitState: IntegrationRateLimitState
    public let revocationSupported: Bool
    public let contribution: IntegrationContribution

    public init(
        connector: IntegrationConnector,
        observedAt: Date,
        operationalState: IntegrationOperationalState,
        permission: IntegrationPermissionState,
        lastSuccessfulSync: Date?,
        newestSourceTimestamp: Date?,
        credentialExpiresAt: Date? = nil,
        rejectedRecordCount: Int = 0,
        schemaVersionMismatch: Bool = false,
        rateLimitState: IntegrationRateLimitState = .notApplicable,
        revocationSupported: Bool,
        contribution: IntegrationContribution
    ) throws {
        guard Self.validDate(observedAt),
              Self.validDate(lastSuccessfulSync),
              Self.validDate(newestSourceTimestamp),
              Self.validDate(credentialExpiresAt)
        else {
            throw IntegrationContractError.invalidClock
        }
        guard (0 ... 1_000_000).contains(rejectedRecordCount) else {
            throw IntegrationContractError.invalidRecordCount
        }
        guard contribution.connector == connector else {
            throw IntegrationContractError.mismatchedContribution
        }
        self.connector = connector
        self.observedAt = observedAt
        self.operationalState = operationalState
        self.permission = permission
        self.lastSuccessfulSync = lastSuccessfulSync
        self.newestSourceTimestamp = newestSourceTimestamp
        self.credentialExpiresAt = credentialExpiresAt
        self.rejectedRecordCount = rejectedRecordCount
        self.schemaVersionMismatch = schemaVersionMismatch
        self.rateLimitState = rateLimitState
        self.revocationSupported = revocationSupported
        self.contribution = contribution
    }

    public var lag: TimeInterval? {
        newestSourceTimestamp.map { max(0, observedAt.timeIntervalSince($0)) }
    }

    private static func validDate(_ date: Date?) -> Bool {
        date?.timeIntervalSinceReferenceDate.isFinite ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case connector
        case observedAt
        case operationalState
        case permission
        case lastSuccessfulSync
        case newestSourceTimestamp
        case credentialExpiresAt
        case rejectedRecordCount
        case schemaVersionMismatch
        case rateLimitState
        case revocationSupported
        case contribution
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            connector: values.decode(IntegrationConnector.self, forKey: .connector),
            observedAt: values.decode(Date.self, forKey: .observedAt),
            operationalState: values.decode(
                IntegrationOperationalState.self,
                forKey: .operationalState
            ),
            permission: values.decode(
                IntegrationPermissionState.self,
                forKey: .permission
            ),
            lastSuccessfulSync: values.decodeIfPresent(
                Date.self,
                forKey: .lastSuccessfulSync
            ),
            newestSourceTimestamp: values.decodeIfPresent(
                Date.self,
                forKey: .newestSourceTimestamp
            ),
            credentialExpiresAt: values.decodeIfPresent(
                Date.self,
                forKey: .credentialExpiresAt
            ),
            rejectedRecordCount: values.decode(
                Int.self,
                forKey: .rejectedRecordCount
            ),
            schemaVersionMismatch: values.decode(
                Bool.self,
                forKey: .schemaVersionMismatch
            ),
            rateLimitState: values.decode(
                IntegrationRateLimitState.self,
                forKey: .rateLimitState
            ),
            revocationSupported: values.decode(
                Bool.self,
                forKey: .revocationSupported
            ),
            contribution: values.decode(
                IntegrationContribution.self,
                forKey: .contribution
            )
        )
    }
}

public struct IntegrationHealthCatalog: Codable, Hashable, Sendable {
    public let snapshots: [IntegrationHealthSnapshot]

    public init(snapshots: [IntegrationHealthSnapshot]) throws {
        guard Set(snapshots.map(\.connector)).count == snapshots.count else {
            throw IntegrationContractError.duplicateConnector
        }
        self.snapshots = snapshots.sorted { $0.connector.rawValue < $1.connector.rawValue }
    }

    public func snapshot(
        for connector: IntegrationConnector
    ) -> IntegrationHealthSnapshot? {
        snapshots.first { $0.connector == connector }
    }

    private enum CodingKeys: String, CodingKey {
        case snapshots
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(snapshots: values.decode(
            [IntegrationHealthSnapshot].self,
            forKey: .snapshots
        ))
    }
}
