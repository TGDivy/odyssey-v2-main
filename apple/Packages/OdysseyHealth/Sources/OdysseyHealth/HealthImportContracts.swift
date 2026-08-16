import Foundation
import OdysseyIntegrations

public enum HealthImportError: Error, Equatable, Sendable {
    case invalidCursor
    case invalidIdentifier
    case invalidSource
    case invalidPayload
    case invalidClock
    case invalidBatch
    case duplicateProjectionIdentity
    case unexpectedSyntheticCursor
    case invalidObservation
}

public enum HealthSampleKind: String, Codable, CaseIterable, Hashable, Sendable {
    case workout
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case sleepAnalysis = "sleep_analysis"
    case bodyMass = "body_mass"
    case activeEnergy = "active_energy"
}

public struct HealthImportCursor: Codable, Hashable, Sendable {
    public static let maximumByteCount = 64 * 1_024

    public let data: Data

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumByteCount else {
            throw HealthImportError.invalidCursor
        }
        self.data = data
    }
}

public struct HealthSampleIdentity: Codable, Hashable, Sendable {
    public let kind: HealthSampleKind
    public let externalIdentifier: String

    public init(
        kind: HealthSampleKind,
        externalIdentifier: String
    ) throws {
        guard HealthImportValidation.validIdentifier(externalIdentifier) else {
            throw HealthImportError.invalidIdentifier
        }
        self.kind = kind
        self.externalIdentifier = externalIdentifier
    }
}

public struct HealthSourceMetadata: Codable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let version: String?
    public let productType: String?
    public let operatingSystemVersion: String?

    public init(
        bundleIdentifier: String,
        displayName: String,
        version: String? = nil,
        productType: String? = nil,
        operatingSystemVersion: String? = nil
    ) throws {
        guard HealthImportValidation.validSource(bundleIdentifier, maximum: 255),
              HealthImportValidation.validSource(displayName, maximum: 255),
              HealthImportValidation.validOptionalSource(version, maximum: 100),
              HealthImportValidation.validOptionalSource(productType, maximum: 255),
              HealthImportValidation.validOptionalSource(
                  operatingSystemVersion,
                  maximum: 100
              )
        else {
            throw HealthImportError.invalidSource
        }
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.productType = productType
        self.operatingSystemVersion = operatingSystemVersion
    }
}

public enum HealthSamplePayload: Codable, Hashable, Sendable {
    case quantity(value: Double, unit: String)
    case category(value: String)
    case workout(
        activityIdentifier: String,
        energyKilocalories: Double?,
        distanceMeters: Double?
    )

    fileprivate func isValid(for kind: HealthSampleKind) -> Bool {
        switch (kind, self) {
        case let (.workout, .workout(activityIdentifier, energy, distance)):
            HealthImportValidation.validValue(activityIdentifier, maximum: 100)
                && HealthImportValidation.validOptionalNonnegative(energy)
                && HealthImportValidation.validOptionalNonnegative(distance)
        case let (.sleepAnalysis, .category(value)):
            HealthImportValidation.validValue(value, maximum: 100)
        case let (
            .heartRate,
            .quantity(value, unit)
        ), let (
            .restingHeartRate,
            .quantity(value, unit)
        ), let (
            .bodyMass,
            .quantity(value, unit)
        ), let (
            .activeEnergy,
            .quantity(value, unit)
        ):
            value.isFinite
                && value >= 0
                && HealthImportValidation.validValue(unit, maximum: 50)
        default:
            false
        }
    }
}

public struct HealthImportedSample: Codable, Hashable, Sendable {
    public let identity: HealthSampleIdentity
    public let startDate: Date
    public let endDate: Date
    public let source: HealthSourceMetadata
    public let payload: HealthSamplePayload

    public init(
        identity: HealthSampleIdentity,
        startDate: Date,
        endDate: Date,
        source: HealthSourceMetadata,
        payload: HealthSamplePayload
    ) throws {
        guard startDate.timeIntervalSinceReferenceDate.isFinite,
              endDate.timeIntervalSinceReferenceDate.isFinite,
              endDate >= startDate
        else {
            throw HealthImportError.invalidClock
        }
        guard payload.isValid(for: identity.kind) else {
            throw HealthImportError.invalidPayload
        }
        self.identity = identity
        self.startDate = startDate
        self.endDate = endDate
        self.source = source
        self.payload = payload
    }
}

public enum HealthImportOutcome: String, Codable, Hashable, Sendable {
    case imported
    case noChanges = "no_changes"
    case permissionDenied = "permission_denied"
    case restricted
    case unavailable
}

public struct HealthImportBatch: Codable, Hashable, Sendable {
    public let kind: HealthSampleKind
    public let queriedAt: Date
    public let samples: [HealthImportedSample]
    public let deletedIdentities: [HealthSampleIdentity]
    public let nextCursor: HealthImportCursor?
    public let outcome: HealthImportOutcome
    public let rejectedRecordCount: Int

    public init(
        kind: HealthSampleKind,
        queriedAt: Date,
        samples: [HealthImportedSample],
        deletedIdentities: [HealthSampleIdentity],
        nextCursor: HealthImportCursor?,
        outcome: HealthImportOutcome,
        rejectedRecordCount: Int = 0
    ) throws {
        guard queriedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HealthImportError.invalidClock
        }
        guard samples.allSatisfy({ $0.identity.kind == kind }),
              deletedIdentities.allSatisfy({ $0.kind == kind }),
              (0 ... 1_000_000).contains(rejectedRecordCount)
        else {
            throw HealthImportError.invalidBatch
        }
        if outcome == .noChanges {
            guard samples.isEmpty, deletedIdentities.isEmpty else {
                throw HealthImportError.invalidBatch
            }
        }
        if outcome == .permissionDenied || outcome == .restricted || outcome == .unavailable {
            guard samples.isEmpty,
                  deletedIdentities.isEmpty,
                  nextCursor == nil
            else {
                throw HealthImportError.invalidBatch
            }
        }
        self.kind = kind
        self.queriedAt = queriedAt
        self.samples = samples
        self.deletedIdentities = deletedIdentities
        self.nextCursor = nextCursor
        self.outcome = outcome
        self.rejectedRecordCount = rejectedRecordCount
    }
}

public struct HealthImportCapability: Hashable, Sendable {
    public let availability: IntegrationCapabilityAvailability
    public let supportedKinds: Set<HealthSampleKind>

    public init(
        availability: IntegrationCapabilityAvailability,
        supportedKinds: Set<HealthSampleKind>
    ) {
        self.availability = availability
        self.supportedKinds = supportedKinds
    }
}

public protocol IncrementalHealthImporting: Sendable {
    func capability() async -> HealthImportCapability
    func authorizationState(
        for kinds: Set<HealthSampleKind>
    ) async -> IntegrationPermissionState
    func requestAuthorization(
        for kinds: Set<HealthSampleKind>
    ) async throws -> IntegrationPermissionState
    func changes(
        for kind: HealthSampleKind,
        after cursor: HealthImportCursor?,
        limit: Int
    ) async throws -> HealthImportBatch
}

public enum HealthChangeObservationState: String, Codable, Hashable, Sendable {
    case unsupported
    case inactive
    case active
    case failed
}

public typealias HealthChangeHandler = @Sendable (HealthSampleKind) async -> Void

public protocol HealthChangeObserving: Sendable {
    func changeObservationState() async -> HealthChangeObservationState
    func startObservingChanges(
        for kinds: Set<HealthSampleKind>,
        handler: @escaping HealthChangeHandler
    ) async throws -> HealthChangeObservationState
    func stopObservingChanges() async
}

public struct HealthImportProjection: Sendable {
    public let samples: [HealthImportedSample]
    public let cursors: [HealthSampleKind: HealthImportCursor]

    public init(
        samples: [HealthImportedSample] = [],
        cursors: [HealthSampleKind: HealthImportCursor] = [:]
    ) throws {
        guard Set(samples.map(\.identity)).count == samples.count else {
            throw HealthImportError.duplicateProjectionIdentity
        }
        self.samples = Self.sorted(samples)
        self.cursors = cursors
    }

    private init(
        validatedSamples: [HealthImportedSample],
        cursors: [HealthSampleKind: HealthImportCursor]
    ) {
        samples = Self.sorted(validatedSamples)
        self.cursors = cursors
    }

    public func applying(
        _ batch: HealthImportBatch
    ) -> HealthImportApplicationResult {
        var projected = Dictionary(uniqueKeysWithValues: samples.map {
            ($0.identity, $0)
        })
        let deleted = Set(batch.deletedIdentities)
        var incoming = [HealthSampleIdentity: HealthImportedSample]()
        var conflictedIdentities = Set<HealthSampleIdentity>()
        var duplicateCount = 0
        var rejectedCount = batch.rejectedRecordCount

        for sample in batch.samples {
            guard !deleted.contains(sample.identity) else {
                rejectedCount += 1
                continue
            }
            guard !conflictedIdentities.contains(sample.identity) else {
                rejectedCount += 1
                continue
            }
            if let prior = incoming[sample.identity] {
                if prior == sample {
                    duplicateCount += 1
                } else {
                    incoming.removeValue(forKey: sample.identity)
                    conflictedIdentities.insert(sample.identity)
                    rejectedCount += 1
                }
                continue
            }
            incoming[sample.identity] = sample
        }

        var deletedCount = 0
        for identity in deleted where projected.removeValue(forKey: identity) != nil {
            deletedCount += 1
        }

        var insertedCount = 0
        for (identity, sample) in incoming {
            if let existing = projected[identity] {
                if existing == sample {
                    duplicateCount += 1
                } else {
                    rejectedCount += 1
                }
            } else {
                projected[identity] = sample
                insertedCount += 1
            }
        }

        var nextCursors = cursors
        if let nextCursor = batch.nextCursor,
           batch.outcome == .imported || batch.outcome == .noChanges
        {
            nextCursors[batch.kind] = nextCursor
        }
        let projection = HealthImportProjection(
            validatedSamples: Array(projected.values),
            cursors: nextCursors
        )
        return HealthImportApplicationResult(
            projection: projection,
            insertedCount: insertedCount,
            deletedCount: deletedCount,
            duplicateCount: duplicateCount,
            rejectedCount: rejectedCount
        )
    }

    private static func sorted(
        _ samples: [HealthImportedSample]
    ) -> [HealthImportedSample] {
        samples.sorted {
            if $0.startDate != $1.startDate {
                return $0.startDate < $1.startDate
            }
            if $0.identity.kind != $1.identity.kind {
                return $0.identity.kind.rawValue < $1.identity.kind.rawValue
            }
            return $0.identity.externalIdentifier < $1.identity.externalIdentifier
        }
    }
}

public struct HealthImportApplicationResult: Sendable {
    public let projection: HealthImportProjection
    public let insertedCount: Int
    public let deletedCount: Int
    public let duplicateCount: Int
    public let rejectedCount: Int
}

public struct SyntheticHealthImportPage: Hashable, Sendable {
    public let expectedCursor: HealthImportCursor?
    public let batch: HealthImportBatch

    public init(
        expectedCursor: HealthImportCursor?,
        batch: HealthImportBatch
    ) {
        self.expectedCursor = expectedCursor
        self.batch = batch
    }
}

public actor SyntheticHealthImportAdapter: IncrementalHealthImporting,
    HealthChangeObserving
{
    private let importCapability: HealthImportCapability
    private let authorizationAfterRequest: IntegrationPermissionState
    private let pages: [HealthSampleKind: [SyntheticHealthImportPage]]
    private let clock: @Sendable () -> Date
    private var permission: IntegrationPermissionState
    private var observedKinds = Set<HealthSampleKind>()
    private var changeHandler: HealthChangeHandler?

    public init(
        capability: HealthImportCapability,
        initialPermission: IntegrationPermissionState,
        authorizationAfterRequest: IntegrationPermissionState,
        pages: [HealthSampleKind: [SyntheticHealthImportPage]] = [:],
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        importCapability = capability
        permission = initialPermission
        self.authorizationAfterRequest = authorizationAfterRequest
        self.pages = pages
        self.clock = clock
    }

    public func capability() async -> HealthImportCapability {
        importCapability
    }

    public func authorizationState(
        for _: Set<HealthSampleKind>
    ) async -> IntegrationPermissionState {
        permission
    }

    public func requestAuthorization(
        for _: Set<HealthSampleKind>
    ) async throws -> IntegrationPermissionState {
        if permission == .notDetermined {
            permission = authorizationAfterRequest
        }
        return permission
    }

    public func changes(
        for kind: HealthSampleKind,
        after cursor: HealthImportCursor?,
        limit: Int
    ) async throws -> HealthImportBatch {
        guard (1 ... 500).contains(limit) else {
            throw HealthImportError.invalidBatch
        }
        switch permission {
        case .denied:
            return try unavailableBatch(kind: kind, outcome: .permissionDenied)
        case .restricted:
            return try unavailableBatch(kind: kind, outcome: .restricted)
        case .unavailable:
            return try unavailableBatch(kind: kind, outcome: .unavailable)
        default:
            break
        }
        guard importCapability.availability == .available,
              importCapability.supportedKinds.contains(kind)
        else {
            return try unavailableBatch(kind: kind, outcome: .unavailable)
        }
        guard let page = pages[kind]?.first(where: { $0.expectedCursor == cursor }) else {
            throw HealthImportError.unexpectedSyntheticCursor
        }
        return page.batch
    }

    public func changeObservationState() async -> HealthChangeObservationState {
        changeHandler == nil ? .inactive : .active
    }

    public func startObservingChanges(
        for kinds: Set<HealthSampleKind>,
        handler: @escaping HealthChangeHandler
    ) async throws -> HealthChangeObservationState {
        guard !kinds.isEmpty,
              importCapability.availability == .available,
              kinds.isSubset(of: importCapability.supportedKinds)
        else {
            throw HealthImportError.invalidObservation
        }
        observedKinds = kinds
        changeHandler = handler
        return .active
    }

    public func stopObservingChanges() async {
        observedKinds.removeAll()
        changeHandler = nil
    }

    @discardableResult
    public func emitObservedChange(
        for kind: HealthSampleKind
    ) async -> Bool {
        guard observedKinds.contains(kind), let changeHandler else {
            return false
        }
        await changeHandler(kind)
        return true
    }

    private func unavailableBatch(
        kind: HealthSampleKind,
        outcome: HealthImportOutcome
    ) throws -> HealthImportBatch {
        try HealthImportBatch(
            kind: kind,
            queriedAt: clock(),
            samples: [],
            deletedIdentities: [],
            nextCursor: nil,
            outcome: outcome
        )
    }
}

private enum HealthImportValidation {
    static func validIdentifier(_ value: String) -> Bool {
        validValue(value, maximum: 200)
            && value.utf8.allSatisfy {
                (48 ... 57).contains($0)
                    || (65 ... 90).contains($0)
                    || (97 ... 122).contains($0)
                    || [45, 46, 58, 95].contains($0)
            }
    }

    static func validSource(_ value: String, maximum: Int) -> Bool {
        validValue(value, maximum: maximum)
    }

    static func validOptionalSource(_ value: String?, maximum: Int) -> Bool {
        value.map { validSource($0, maximum: maximum) } ?? true
    }

    static func validValue(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    static func validOptionalNonnegative(_ value: Double?) -> Bool {
        value.map { $0.isFinite && $0 >= 0 } ?? true
    }
}
