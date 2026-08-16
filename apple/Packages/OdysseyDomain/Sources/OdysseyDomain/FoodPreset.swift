import Foundation

public enum FoodPresetValidationError: Error, Equatable, Sendable {
    case invalidMetadata
    case invalidName
    case invalidServingDescription
    case invalidAliases
    case emptyNutrientProfile
    case invalidNutrientValue(String)
    case invalidNutrientSource
}

extension FoodPresetValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            "The food preset metadata is invalid."
        case .invalidName:
            "The food preset name is invalid."
        case .invalidServingDescription:
            "The food preset serving description is invalid."
        case .invalidAliases:
            "The food preset aliases are invalid or duplicated."
        case .emptyNutrientProfile:
            "A nutrient profile must contain at least one value."
        case let .invalidNutrientValue(field):
            "The food preset has an invalid \(field) value."
        case .invalidNutrientSource:
            "The food preset nutrient source is invalid."
        }
    }
}

public enum FoodNutrientSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case ownerEstimate = "owner_estimate"
    case packageLabel = "package_label"
}

public struct FoodNutrientProfile: Codable, Hashable, Sendable {
    public let energyKilocalories: Double?
    public let proteinGrams: Double?
    public let caffeineMilligrams: Double?
    public let alcoholGrams: Double?
    public let sourceKind: FoodNutrientSourceKind
    public let sourceDescription: String?

    public init(
        energyKilocalories: Double? = nil,
        proteinGrams: Double? = nil,
        caffeineMilligrams: Double? = nil,
        alcoholGrams: Double? = nil,
        sourceKind: FoodNutrientSourceKind,
        sourceDescription: String? = nil
    ) throws {
        let values = [
            ("energy kilocalories", energyKilocalories, 20_000.0),
            ("protein grams", proteinGrams, 2_000.0),
            ("caffeine milligrams", caffeineMilligrams, 10_000.0),
            ("alcohol grams", alcoholGrams, 1_000.0),
        ]
        guard values.contains(where: { $0.1 != nil }) else {
            throw FoodPresetValidationError.emptyNutrientProfile
        }
        for (field, value, maximum) in values {
            if let value, !value.isFinite || value < 0 || value > maximum {
                throw FoodPresetValidationError.invalidNutrientValue(field)
            }
        }
        if let sourceDescription,
           !Self.validText(sourceDescription, maximum: 200)
        {
            throw FoodPresetValidationError.invalidNutrientSource
        }
        if sourceKind == .packageLabel, sourceDescription == nil {
            throw FoodPresetValidationError.invalidNutrientSource
        }
        self.energyKilocalories = energyKilocalories
        self.proteinGrams = proteinGrams
        self.caffeineMilligrams = caffeineMilligrams
        self.alcoholGrams = alcoholGrams
        self.sourceKind = sourceKind
        self.sourceDescription = sourceDescription
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct FoodPreset: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumAliasCount = 20

    public let metadata: EntityMetadata
    public let name: String
    public let servingDescription: String
    public let aliases: [String]
    public let nutrients: FoodNutrientProfile?

    public init(
        metadata: EntityMetadata,
        name: String,
        servingDescription: String,
        aliases: [String] = [],
        nutrients: FoodNutrientProfile? = nil
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
            throw FoodPresetValidationError.invalidMetadata
        }
        if let tombstonedAt = metadata.tombstonedAt {
            guard tombstonedAt.timeIntervalSinceReferenceDate.isFinite,
                  tombstonedAt >= metadata.createdAt,
                  tombstonedAt <= metadata.lastRevisedAt
            else {
                throw FoodPresetValidationError.invalidMetadata
            }
        }
        guard Self.validText(name, maximum: 100) else {
            throw FoodPresetValidationError.invalidName
        }
        guard Self.validText(servingDescription, maximum: 100) else {
            throw FoodPresetValidationError.invalidServingDescription
        }
        let normalizedName = Self.normalized(name)
        let normalizedAliases = aliases.map(Self.normalized)
        guard aliases.count <= Self.maximumAliasCount,
              aliases.allSatisfy({ Self.validText($0, maximum: 100) }),
              Set(normalizedAliases).count == aliases.count,
              !normalizedAliases.contains(normalizedName)
        else {
            throw FoodPresetValidationError.invalidAliases
        }
        self.metadata = metadata
        self.name = name
        self.servingDescription = servingDescription
        self.aliases = aliases
        self.nutrients = nutrients
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
