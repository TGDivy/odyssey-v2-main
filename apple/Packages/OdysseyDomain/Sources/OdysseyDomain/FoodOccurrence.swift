import Foundation

public enum FoodOccurrenceValidationError: Error, Equatable, Sendable {
    case invalidMetadata
    case invalidPresetReference
    case invalidSnapshot
    case invalidQuantity
    case invalidNutrients
    case invalidTemporalContext
}

extension FoodOccurrenceValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            "The food occurrence metadata is invalid."
        case .invalidPresetReference:
            "The food occurrence preset reference is invalid."
        case .invalidSnapshot:
            "The food occurrence serving snapshot is invalid."
        case .invalidQuantity:
            "The food occurrence serving quantity is invalid."
        case .invalidNutrients:
            "The food occurrence nutrient totals are invalid."
        case .invalidTemporalContext:
            "The food occurrence time, time zone, or UTC offset is invalid."
        }
    }
}

public struct FoodOccurrence: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumQuantity = 100.0

    public let metadata: EntityMetadata
    public let presetID: UUIDv7
    public let presetRevision: Int
    public let presetNameSnapshot: String
    public let servingDescriptionSnapshot: String
    public let quantity: Double
    public let nutrientTotals: FoodNutrientProfile?
    public let occurredAt: Date
    public let timeZoneID: String
    public let originalUTCOffsetSeconds: Int

    public init(
        metadata: EntityMetadata,
        presetID: UUIDv7,
        presetRevision: Int,
        presetNameSnapshot: String,
        servingDescriptionSnapshot: String,
        quantity: Double,
        nutrientTotals: FoodNutrientProfile?,
        occurredAt: Date,
        timeZoneID: String,
        originalUTCOffsetSeconds: Int
    ) throws {
        guard metadata.schemaVersion == Self.currentSchemaVersion,
              metadata.revision >= 1,
              metadata.sensitivity != .operationalSecret,
              metadata.createdAt.timeIntervalSinceReferenceDate.isFinite,
              metadata.lastRevisedAt.timeIntervalSinceReferenceDate.isFinite,
              metadata.lastRevisedAt >= metadata.createdAt,
              (1 ... 100).contains(metadata.createdBy.actorID.count),
              metadata.createdBy.actorID
                  == metadata.createdBy.actorID.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw FoodOccurrenceValidationError.invalidMetadata
        }
        if let tombstonedAt = metadata.tombstonedAt {
            guard tombstonedAt.timeIntervalSinceReferenceDate.isFinite,
                  tombstonedAt >= metadata.createdAt,
                  tombstonedAt <= metadata.lastRevisedAt
            else {
                throw FoodOccurrenceValidationError.invalidMetadata
            }
        }
        guard presetRevision >= 1 else {
            throw FoodOccurrenceValidationError.invalidPresetReference
        }
        guard Self.validText(presetNameSnapshot),
              Self.validText(servingDescriptionSnapshot)
        else {
            throw FoodOccurrenceValidationError.invalidSnapshot
        }
        guard quantity.isFinite,
              quantity > 0,
              quantity <= Self.maximumQuantity
        else {
            throw FoodOccurrenceValidationError.invalidQuantity
        }
        let validatedNutrients: FoodNutrientProfile?
        if let nutrientTotals {
            do {
                validatedNutrients = try FoodNutrientProfile(
                    energyKilocalories: nutrientTotals.energyKilocalories,
                    proteinGrams: nutrientTotals.proteinGrams,
                    caffeineMilligrams: nutrientTotals.caffeineMilligrams,
                    alcoholGrams: nutrientTotals.alcoholGrams,
                    sourceKind: nutrientTotals.sourceKind,
                    sourceDescription: nutrientTotals.sourceDescription
                )
            } catch {
                throw FoodOccurrenceValidationError.invalidNutrients
            }
        } else {
            validatedNutrients = nil
        }
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite,
              occurredAt <= metadata.lastRevisedAt,
              let timeZone = TimeZone(identifier: timeZoneID),
              (1 ... 100).contains(timeZoneID.count),
              timeZoneID == timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines),
              timeZone.secondsFromGMT(for: occurredAt) == originalUTCOffsetSeconds
        else {
            throw FoodOccurrenceValidationError.invalidTemporalContext
        }
        self.metadata = metadata
        self.presetID = presetID
        self.presetRevision = presetRevision
        self.presetNameSnapshot = presetNameSnapshot
        self.servingDescriptionSnapshot = servingDescriptionSnapshot
        self.quantity = quantity
        self.nutrientTotals = validatedNutrients
        self.occurredAt = occurredAt
        self.timeZoneID = timeZoneID
        self.originalUTCOffsetSeconds = originalUTCOffsetSeconds
    }

    private static func validText(_ value: String) -> Bool {
        (1 ... 100).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
