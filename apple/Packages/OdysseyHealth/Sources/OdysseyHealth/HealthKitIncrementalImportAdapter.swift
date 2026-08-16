#if canImport(HealthKit)
import Foundation
import HealthKit
import OdysseyIntegrations

public actor HealthKitIncrementalImportAdapter: IncrementalHealthImporting {
    private let store: HKHealthStore
    private let clock: @Sendable () -> Date

    public init(
        store: HKHealthStore = HKHealthStore(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.clock = clock
    }

    public func capability() async -> HealthImportCapability {
        guard HKHealthStore.isHealthDataAvailable() else {
            return HealthImportCapability(
                availability: .unavailable,
                supportedKinds: []
            )
        }
        let supported = Set(HealthSampleKind.allCases.filter {
            Self.sampleType(for: $0) != nil
        })
        return HealthImportCapability(
            availability: supported.isEmpty ? .unsupported : .available,
            supportedKinds: supported
        )
    }

    public func authorizationState(
        for kinds: Set<HealthSampleKind>
    ) async -> IntegrationPermissionState {
        guard !kinds.isEmpty else { return .notRequired }
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let readTypes = Set<HKObjectType>(kinds.compactMap {
            Self.sampleType(for: $0) as HKObjectType?
        })
        guard readTypes.count == kinds.count else { return .unavailable }
        do {
            let requestStatus = try await authorizationRequestStatus(for: readTypes)
            switch requestStatus {
            case .shouldRequest:
                return .notDetermined
            case .unnecessary:
                return .partial
            case .unknown:
                return .unavailable
            @unknown default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    public func requestAuthorization(
        for kinds: Set<HealthSampleKind>
    ) async throws -> IntegrationPermissionState {
        guard !kinds.isEmpty else { return .notRequired }
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let readTypes = Set<HKObjectType>(kinds.compactMap {
            Self.sampleType(for: $0) as HKObjectType?
        })
        guard readTypes.count == kinds.count else { return .unavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
        return await authorizationState(for: kinds)
    }

    public func changes(
        for kind: HealthSampleKind,
        after cursor: HealthImportCursor?,
        limit: Int
    ) async throws -> HealthImportBatch {
        guard (1 ... 500).contains(limit) else {
            throw HealthImportError.invalidBatch
        }
        guard HKHealthStore.isHealthDataAvailable(),
              let sampleType = Self.sampleType(for: kind)
        else {
            return try unavailableBatch(kind: kind, outcome: .unavailable)
        }
        let anchor = try cursor.map(Self.decodeAnchor)
        do {
            let result = try await executeAnchoredQuery(
                type: sampleType,
                anchor: anchor,
                limit: limit
            )
            var rejectedCount = 0
            var imported = [HealthImportedSample]()
            for sample in result.samples {
                do {
                    imported.append(try Self.importedSample(sample, kind: kind))
                } catch {
                    rejectedCount += 1
                }
            }
            var deleted = [HealthSampleIdentity]()
            for object in result.deletedObjects {
                do {
                    deleted.append(try HealthSampleIdentity(
                        kind: kind,
                        externalIdentifier: object.uuid.uuidString.lowercased()
                    ))
                } catch {
                    rejectedCount += 1
                }
            }
            let nextCursor = try result.anchor.map(Self.encodeAnchor)
            return try HealthImportBatch(
                kind: kind,
                queriedAt: clock(),
                samples: imported,
                deletedIdentities: deleted,
                nextCursor: nextCursor,
                outcome: imported.isEmpty && deleted.isEmpty ? .noChanges : .imported,
                rejectedRecordCount: rejectedCount
            )
        } catch let error as NSError
            where error.domain == HKErrorDomain
                && error.code == HKError.Code.errorAuthorizationDenied.rawValue
        {
            return try unavailableBatch(kind: kind, outcome: .permissionDenied)
        }
    }

    private func authorizationRequestStatus(
        for readTypes: Set<HKObjectType>
    ) async throws -> HKAuthorizationRequestStatus {
        try await withCheckedThrowingContinuation { continuation in
            store.getRequestStatusForAuthorization(
                toShare: [],
                read: readTypes
            ) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func executeAnchoredQuery(
        type: HKSampleType,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> AnchoredQueryResult {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: AnchoredQueryResult(
                        samples: samples ?? [],
                        deletedObjects: deletedObjects ?? [],
                        anchor: newAnchor
                    ))
                }
            }
            store.execute(query)
        }
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

    private static func sampleType(
        for kind: HealthSampleKind
    ) -> HKSampleType? {
        switch kind {
        case .workout:
            HKObjectType.workoutType()
        case .heartRate:
            HKObjectType.quantityType(forIdentifier: .heartRate)
        case .restingHeartRate:
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        case .sleepAnalysis:
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .bodyMass:
            HKObjectType.quantityType(forIdentifier: .bodyMass)
        case .activeEnergy:
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        }
    }

    private static func importedSample(
        _ sample: HKSample,
        kind: HealthSampleKind
    ) throws -> HealthImportedSample {
        try HealthImportedSample(
            identity: HealthSampleIdentity(
                kind: kind,
                externalIdentifier: sample.uuid.uuidString.lowercased()
            ),
            startDate: sample.startDate,
            endDate: sample.endDate,
            source: sourceMetadata(sample.sourceRevision),
            payload: try payload(sample, kind: kind)
        )
    }

    private static func sourceMetadata(
        _ revision: HKSourceRevision
    ) throws -> HealthSourceMetadata {
        let os = revision.operatingSystemVersion
        let operatingSystemVersion = os.majorVersion == 0
            && os.minorVersion == 0
            && os.patchVersion == 0
            ? nil
            : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return try HealthSourceMetadata(
            bundleIdentifier: revision.source.bundleIdentifier,
            displayName: revision.source.name,
            version: revision.version,
            productType: revision.productType,
            operatingSystemVersion: operatingSystemVersion
        )
    }

    private static func payload(
        _ sample: HKSample,
        kind: HealthSampleKind
    ) throws -> HealthSamplePayload {
        switch kind {
        case .workout:
            guard let workout = sample as? HKWorkout else {
                throw HealthImportError.invalidPayload
            }
            return .workout(
                activityIdentifier: "healthkit_\(workout.workoutActivityType.rawValue)",
                energyKilocalories: workout.totalEnergyBurned?.doubleValue(
                    for: .kilocalorie()
                ),
                distanceMeters: workout.totalDistance?.doubleValue(for: .meter())
            )
        case .sleepAnalysis:
            guard let category = sample as? HKCategorySample else {
                throw HealthImportError.invalidPayload
            }
            return .category(value: sleepStage(category.value))
        case .heartRate, .restingHeartRate:
            guard let quantity = sample as? HKQuantitySample else {
                throw HealthImportError.invalidPayload
            }
            let unit = HKUnit.count().unitDivided(by: .minute())
            return .quantity(
                value: quantity.quantity.doubleValue(for: unit),
                unit: "count/min"
            )
        case .bodyMass:
            guard let quantity = sample as? HKQuantitySample else {
                throw HealthImportError.invalidPayload
            }
            return .quantity(
                value: quantity.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                unit: "kg"
            )
        case .activeEnergy:
            guard let quantity = sample as? HKQuantitySample else {
                throw HealthImportError.invalidPayload
            }
            return .quantity(
                value: quantity.quantity.doubleValue(for: .kilocalorie()),
                unit: "kcal"
            )
        }
    }

    private static func sleepStage(_ value: Int) -> String {
        switch value {
        case HKCategoryValueSleepAnalysis.inBed.rawValue:
            "in_bed"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            "asleep_unspecified"
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            "awake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            "asleep_core"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            "asleep_deep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            "asleep_rem"
        default:
            "other"
        }
    }

    private static func encodeAnchor(
        _ anchor: HKQueryAnchor
    ) throws -> HealthImportCursor {
        try HealthImportCursor(data: NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        ))
    }

    private static func decodeAnchor(
        _ cursor: HealthImportCursor
    ) throws -> HKQueryAnchor {
        guard let anchor = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: HKQueryAnchor.self,
            from: cursor.data
        ) else {
            throw HealthImportError.invalidCursor
        }
        return anchor
    }
}

private struct AnchoredQueryResult: @unchecked Sendable {
    let samples: [HKSample]
    let deletedObjects: [HKDeletedObject]
    let anchor: HKQueryAnchor?
}
#endif
