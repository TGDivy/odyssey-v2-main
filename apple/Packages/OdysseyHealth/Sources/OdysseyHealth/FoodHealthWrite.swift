import Foundation
import OdysseyDomain

public enum FoodHealthNutrientKind: String, Codable, CaseIterable, Hashable, Sendable {
    case energyKilocalories = "energy_kilocalories"
    case proteinGrams = "protein_grams"
    case caffeineMilligrams = "caffeine_milligrams"
}

public enum FoodHealthAuthorizationState: String, Codable, Equatable, Sendable {
    case unavailable
    case notDetermined = "not_determined"
    case denied
    case authorized
}

public struct FoodHealthSample: Hashable, Sendable {
    public let occurrenceID: UUIDv7
    public let occurrenceRevision: Int
    public let presetID: UUIDv7
    public let presetRevision: Int
    public let kind: FoodHealthNutrientKind
    public let value: Double
    public let occurredAt: Date

    fileprivate init(
        occurrenceID: UUIDv7,
        occurrenceRevision: Int,
        presetID: UUIDv7,
        presetRevision: Int,
        kind: FoodHealthNutrientKind,
        value: Double,
        occurredAt: Date
    ) {
        self.occurrenceID = occurrenceID
        self.occurrenceRevision = occurrenceRevision
        self.presetID = presetID
        self.presetRevision = presetRevision
        self.kind = kind
        self.value = value
        self.occurredAt = occurredAt
    }
}

public struct FoodHealthWritePlan: Equatable, Sendable {
    public let occurrenceID: UUIDv7
    public let samples: [FoodHealthSample]
    public let omittedAlcoholGrams: Double?

    public init(occurrence: FoodOccurrence) {
        occurrenceID = occurrence.metadata.id
        var samples = [FoodHealthSample]()
        if let value = occurrence.nutrientTotals?.energyKilocalories {
            samples.append(Self.sample(
                occurrence: occurrence,
                kind: .energyKilocalories,
                value: value
            ))
        }
        if let value = occurrence.nutrientTotals?.proteinGrams {
            samples.append(Self.sample(
                occurrence: occurrence,
                kind: .proteinGrams,
                value: value
            ))
        }
        if let value = occurrence.nutrientTotals?.caffeineMilligrams {
            samples.append(Self.sample(
                occurrence: occurrence,
                kind: .caffeineMilligrams,
                value: value
            ))
        }
        omittedAlcoholGrams = occurrence.nutrientTotals?.alcoholGrams
        self.samples = samples
    }

    public var nutrientKinds: Set<FoodHealthNutrientKind> {
        Set(samples.map(\.kind))
    }

    private static func sample(
        occurrence: FoodOccurrence,
        kind: FoodHealthNutrientKind,
        value: Double
    ) -> FoodHealthSample {
        FoodHealthSample(
            occurrenceID: occurrence.metadata.id,
            occurrenceRevision: occurrence.metadata.revision,
            presetID: occurrence.presetID,
            presetRevision: occurrence.presetRevision,
            kind: kind,
            value: value,
            occurredAt: occurrence.occurredAt
        )
    }
}

public protocol FoodHealthSampleWriting: Sendable {
    func authorizationState(
        for kinds: Set<FoodHealthNutrientKind>
    ) async -> FoodHealthAuthorizationState
    func requestAuthorization(
        for kinds: Set<FoodHealthNutrientKind>
    ) async throws -> FoodHealthAuthorizationState
    func replaceOwnedSamples(
        occurrenceID: UUIDv7,
        with samples: [FoodHealthSample]
    ) async throws
    func deleteOwnedSamples(occurrenceID: UUIDv7) async throws
}

public enum FoodHealthWriteResult: Equatable, Sendable {
    case unavailable
    case authorizationRequired
    case denied
    case noSupportedNutrients(omittedAlcoholGrams: Double?)
    case written(sampleCount: Int, omittedAlcoholGrams: Double?)
    case deleted
}

public actor FoodHealthWriteCoordinator {
    private let writer: any FoodHealthSampleWriting

    public init(writer: any FoodHealthSampleWriting) {
        self.writer = writer
    }

    public func authorizationState(
        for kinds: Set<FoodHealthNutrientKind>
    ) async -> FoodHealthAuthorizationState {
        await writer.authorizationState(for: kinds)
    }

    public func requestAuthorization(
        for kinds: Set<FoodHealthNutrientKind>
    ) async throws -> FoodHealthAuthorizationState {
        guard !kinds.isEmpty else { return .notDetermined }
        return try await writer.requestAuthorization(for: kinds)
    }

    public func writeIfAuthorized(
        _ occurrence: FoodOccurrence,
        replacingExisting: Bool = false
    ) async throws -> FoodHealthWriteResult {
        if occurrence.metadata.tombstonedAt != nil {
            return try await deleteOwnedSamples(
                occurrenceID: occurrence.metadata.id
            )
        }
        let plan = FoodHealthWritePlan(occurrence: occurrence)
        guard !plan.samples.isEmpty else {
            if replacingExisting {
                try await writer.deleteOwnedSamples(occurrenceID: plan.occurrenceID)
                return .written(
                    sampleCount: 0,
                    omittedAlcoholGrams: plan.omittedAlcoholGrams
                )
            }
            return .noSupportedNutrients(
                omittedAlcoholGrams: plan.omittedAlcoholGrams
            )
        }
        let authorization = await writer.authorizationState(for: plan.nutrientKinds)
        if replacingExisting, authorization != .authorized {
            try await writer.deleteOwnedSamples(occurrenceID: plan.occurrenceID)
        }
        switch authorization {
        case .unavailable:
            return .unavailable
        case .notDetermined:
            return .authorizationRequired
        case .denied:
            return .denied
        case .authorized:
            try await writer.replaceOwnedSamples(
                occurrenceID: plan.occurrenceID,
                with: plan.samples
            )
            return .written(
                sampleCount: plan.samples.count,
                omittedAlcoholGrams: plan.omittedAlcoholGrams
            )
        }
    }

    public func deleteOwnedSamples(
        occurrenceID: UUIDv7
    ) async throws -> FoodHealthWriteResult {
        try await writer.deleteOwnedSamples(occurrenceID: occurrenceID)
        return .deleted
    }
}
