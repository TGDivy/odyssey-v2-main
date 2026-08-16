import Foundation
import OdysseyIntegrations

public enum LocationContextError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidText
    case invalidClock
    case invalidTimeZone
    case invalidLocation
    case invalidResult
    case unexpectedSyntheticRequest
}

public enum BroadPlacePrecision: String, Codable, Hashable, Sendable {
    case locality
    case administrativeArea = "administrative_area"
    case timeZone = "time_zone"
}

public struct BroadLocationContext: Codable, Hashable, Sendable {
    public let placeIdentifier: String
    public let displayName: String?
    public let timeZoneID: String
    public let capturedAt: Date
    public let expiresAt: Date
    public let precision: BroadPlacePrecision

    public init(
        placeIdentifier: String,
        displayName: String?,
        timeZoneID: String,
        capturedAt: Date,
        expiresAt: Date,
        precision: BroadPlacePrecision
    ) throws {
        guard LocationValidation.validToken(placeIdentifier, maximum: 100) else {
            throw LocationContextError.invalidIdentifier
        }
        guard LocationValidation.validOptionalText(displayName, maximum: 200) else {
            throw LocationContextError.invalidText
        }
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw LocationContextError.invalidTimeZone
        }
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt > capturedAt,
              expiresAt <= capturedAt.addingTimeInterval(24 * 60 * 60)
        else {
            throw LocationContextError.invalidClock
        }
        self.placeIdentifier = placeIdentifier
        self.displayName = displayName
        self.timeZoneID = timeZoneID
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.precision = precision
    }

    private enum CodingKeys: String, CodingKey {
        case placeIdentifier
        case displayName
        case timeZoneID
        case capturedAt
        case expiresAt
        case precision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            placeIdentifier: values.decode(String.self, forKey: .placeIdentifier),
            displayName: values.decodeIfPresent(String.self, forKey: .displayName),
            timeZoneID: values.decode(String.self, forKey: .timeZoneID),
            capturedAt: values.decode(Date.self, forKey: .capturedAt),
            expiresAt: values.decode(Date.self, forKey: .expiresAt),
            precision: values.decode(BroadPlacePrecision.self, forKey: .precision)
        )
    }
}

public struct TransientLocationFix: Hashable, Sendable {
    public let context: BroadLocationContext
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double

    public init(
        context: BroadLocationContext,
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
            throw LocationContextError.invalidLocation
        }
        self.context = context
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
    }
}

public enum BroadLocationOutcome: String, Codable, Hashable, Sendable {
    case acquired
    case permissionDenied = "permission_denied"
    case restricted
    case unavailable
    case insufficientAccuracy = "insufficient_accuracy"
    case noFix = "no_fix"
}

public struct BroadLocationResult: Hashable, Sendable {
    public let outcome: BroadLocationOutcome
    public let fix: TransientLocationFix?
    public let rejectedRecordCount: Int

    public init(
        outcome: BroadLocationOutcome,
        fix: TransientLocationFix?,
        rejectedRecordCount: Int = 0
    ) throws {
        guard (0 ... 1_000_000).contains(rejectedRecordCount) else {
            throw LocationContextError.invalidResult
        }
        switch outcome {
        case .acquired:
            guard fix != nil else {
                throw LocationContextError.invalidResult
            }
        case .permissionDenied, .restricted, .unavailable,
             .insufficientAccuracy, .noFix:
            guard fix == nil else {
                throw LocationContextError.invalidResult
            }
        }
        self.outcome = outcome
        self.fix = fix
        self.rejectedRecordCount = rejectedRecordCount
    }
}

public struct LocationContextCapability: Hashable, Sendable {
    public let availability: IntegrationCapabilityAvailability
    public let supportsForegroundBroadPlace: Bool
    public let supportsSignificantChanges: Bool

    public init(
        availability: IntegrationCapabilityAvailability,
        supportsForegroundBroadPlace: Bool,
        supportsSignificantChanges: Bool
    ) {
        self.availability = availability
        self.supportsForegroundBroadPlace = supportsForegroundBroadPlace
        self.supportsSignificantChanges = supportsSignificantChanges
    }
}

public protocol LocationContextProviding: Sendable {
    func capability() async -> LocationContextCapability
    func authorizationState() async -> IntegrationPermissionState
    func requestWhenInUseAuthorization() async -> IntegrationPermissionState
    func currentBroadLocation() async throws -> BroadLocationResult
    func stopMonitoring() async
}

enum LocationValidation {
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
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        value.map { validText($0, maximum: maximum) } ?? true
    }
}
