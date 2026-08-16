import Foundation
import OdysseyDomain

public struct FoodQuickLogSnapshot: Equatable, Sendable {
    public let activePresets: [FoodPreset]
    public let rankedPresets: [RankedFoodPreset]
    public let recentOccurrences: [FoodOccurrence]
    public let generatedAt: Date
    public let timeZoneID: String

    public init(
        activePresets: [FoodPreset],
        rankedPresets: [RankedFoodPreset],
        recentOccurrences: [FoodOccurrence],
        generatedAt: Date,
        timeZoneID: String
    ) {
        self.activePresets = activePresets
        self.rankedPresets = rankedPresets
        self.recentOccurrences = recentOccurrences
        self.generatedAt = generatedAt
        self.timeZoneID = timeZoneID
    }
}

public enum FoodQuickLogProjector {
    public static func project(
        presets: [FoodPreset],
        usages: [FoodPresetUsage],
        recentOccurrences: [FoodOccurrence],
        at date: Date,
        timeZoneID: String,
        strategy: FoodPresetRankingStrategy = .contextFrequencyV1,
        limit: Int = FoodPresetRanker.defaultLimit
    ) throws -> FoodQuickLogSnapshot {
        let context = try FoodPresetRankingContext(
            occurredAt: date,
            timeZoneID: timeZoneID
        )
        let activePresets = presets.filter { $0.metadata.tombstonedAt == nil }.sorted {
            let leftName = stableName($0.name)
            let rightName = stableName($1.name)
            if leftName != rightName {
                return leftName < rightName
            }
            return $0.metadata.id.description < $1.metadata.id.description
        }
        let rankedPresets = try FoodPresetRanker.rank(
            presets: activePresets,
            usages: usages,
            context: context,
            asOf: date,
            strategy: strategy,
            limit: limit
        )
        let occurrences = recentOccurrences.filter {
            $0.metadata.tombstonedAt == nil
        }.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.metadata.id.description > $1.metadata.id.description
        }
        return FoodQuickLogSnapshot(
            activePresets: activePresets,
            rankedPresets: rankedPresets,
            recentOccurrences: occurrences,
            generatedAt: date,
            timeZoneID: timeZoneID
        )
    }

    private static func stableName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

public enum FoodQuickLogSuccess: Equatable, Sendable {
    case presetCreated(UUIDv7)
    case occurrenceRecorded(UUIDv7, at: Date)
    case occurrenceCorrected(UUIDv7, at: Date)
    case occurrenceVoided(UUIDv7, at: Date)
}

public enum ApplicationFoodPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case saving
    case succeeded(FoodQuickLogSuccess)
    case failed(String)

    public var isBusy: Bool {
        self == .loading || self == .saving
    }
}
