#if canImport(HealthKit)
import Foundation
import HealthKit
import OdysseyDomain

public actor HealthKitFoodWriter: FoodHealthSampleWriting {
    public static let occurrenceMetadataKey = "com.odyssey.food.occurrence_id"
    public static let occurrenceRevisionMetadataKey = "com.odyssey.food.occurrence_revision"
    public static let presetMetadataKey = "com.odyssey.food.preset_id"
    public static let presetRevisionMetadataKey = "com.odyssey.food.preset_revision"
    public static let nutrientMetadataKey = "com.odyssey.food.nutrient_kind"

    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public func authorizationState(
        for kinds: Set<FoodHealthNutrientKind>
    ) async -> FoodHealthAuthorizationState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let types = kinds.compactMap(Self.quantityType(for:))
        guard !types.isEmpty else { return .notDetermined }
        let statuses = types.map(store.authorizationStatus(for:))
        if statuses.allSatisfy({ $0 == .sharingAuthorized }) {
            return .authorized
        }
        if statuses.contains(.notDetermined) {
            return .notDetermined
        }
        return .denied
    }

    public func requestAuthorization(
        for kinds: Set<FoodHealthNutrientKind>
    ) async throws -> FoodHealthAuthorizationState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let types = Set<HKSampleType>(
            kinds.compactMap(Self.quantityType(for:)).map { $0 as HKSampleType }
        )
        guard !types.isEmpty else { return .notDetermined }
        try await store.requestAuthorization(toShare: types, read: [])
        return await authorizationState(for: kinds)
    }

    public func replaceOwnedSamples(
        occurrenceID: UUIDv7,
        with samples: [FoodHealthSample]
    ) async throws {
        try await deleteOwnedSamples(occurrenceID: occurrenceID)
        let healthSamples = samples.compactMap(Self.healthSample(from:))
        guard !healthSamples.isEmpty else { return }
        try await store.save(healthSamples)
    }

    public func deleteOwnedSamples(occurrenceID: UUIDv7) async throws {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: Self.occurrenceMetadataKey,
            operatorType: .equalTo,
            value: occurrenceID.description
        )
        for kind in FoodHealthNutrientKind.allCases {
            guard let type = Self.quantityType(for: kind) else { continue }
            try await deleteOwnedObjects(of: type, predicate: predicate)
        }
    }

    private func deleteOwnedObjects(
        of type: HKObjectType,
        predicate: NSPredicate
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            store.deleteObjects(of: type, predicate: predicate) { success, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitFoodWriterError.deleteFailed)
                }
            }
        }
    }

    private static func quantityType(
        for kind: FoodHealthNutrientKind
    ) -> HKQuantityType? {
        switch kind {
        case .energyKilocalories:
            HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed)
        case .proteinGrams:
            HKQuantityType.quantityType(forIdentifier: .dietaryProtein)
        case .caffeineMilligrams:
            HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine)
        }
    }

    private static func healthSample(from sample: FoodHealthSample) -> HKQuantitySample? {
        guard let type = quantityType(for: sample.kind) else { return nil }
        let unit: HKUnit
        switch sample.kind {
        case .energyKilocalories:
            unit = .kilocalorie()
        case .proteinGrams:
            unit = .gram()
        case .caffeineMilligrams:
            unit = .gramUnit(with: .milli)
        }
        return HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: unit, doubleValue: sample.value),
            start: sample.occurredAt,
            end: sample.occurredAt,
            metadata: [
                occurrenceMetadataKey: sample.occurrenceID.description,
                occurrenceRevisionMetadataKey: sample.occurrenceRevision,
                presetMetadataKey: sample.presetID.description,
                presetRevisionMetadataKey: sample.presetRevision,
                nutrientMetadataKey: sample.kind.rawValue,
                HKMetadataKeySyncIdentifier: sample.occurrenceID.description
                    + "." + sample.kind.rawValue,
                HKMetadataKeySyncVersion: sample.occurrenceRevision,
                HKMetadataKeyWasUserEntered: true,
            ]
        )
    }
}

public enum HealthKitFoodWriterError: Error, Equatable, Sendable {
    case deleteFailed
}
#endif
