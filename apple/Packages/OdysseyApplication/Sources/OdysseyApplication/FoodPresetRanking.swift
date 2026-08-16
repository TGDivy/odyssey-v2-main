import Foundation
import OdysseyDomain

public enum FoodPresetTimeBand: String, Codable, CaseIterable, Hashable, Sendable {
    case morning
    case midday
    case evening
    case other
}

public enum FoodPresetDayKind: String, Codable, CaseIterable, Hashable, Sendable {
    case weekday
    case weekend
}

public struct FoodPresetRankingContext: Codable, Hashable, Sendable {
    public let timeBand: FoodPresetTimeBand
    public let dayKind: FoodPresetDayKind

    public init(timeBand: FoodPresetTimeBand, dayKind: FoodPresetDayKind) {
        self.timeBand = timeBand
        self.dayKind = dayKind
    }

    public init(occurredAt: Date, timeZoneID: String) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FoodPresetRankingError.invalidClock
        }
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw FoodPresetRankingError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .weekday], from: occurredAt)
        guard let hour = components.hour, let weekday = components.weekday else {
            throw FoodPresetRankingError.invalidClock
        }
        switch hour {
        case 4 ..< 11:
            timeBand = .morning
        case 11 ..< 15:
            timeBand = .midday
        case 17 ..< 22:
            timeBand = .evening
        default:
            timeBand = .other
        }
        dayKind = weekday == 1 || weekday == 7 ? .weekend : .weekday
    }
}

public struct FoodPresetUsage: Codable, Hashable, Sendable {
    public let usageID: UUIDv7
    public let presetID: UUIDv7
    public let occurredAt: Date
    public let context: FoodPresetRankingContext

    public init(
        usageID: UUIDv7 = UUIDv7(),
        presetID: UUIDv7,
        occurredAt: Date,
        context: FoodPresetRankingContext
    ) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FoodPresetRankingError.invalidClock
        }
        self.usageID = usageID
        self.presetID = presetID
        self.occurredAt = occurredAt
        self.context = context
    }
}

public enum FoodPresetRankingStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case frequencyOnlyV1 = "frequency_only_v1"
    case contextFrequencyV1 = "context_frequency_v1"
}

public enum FoodPresetRankReason: String, Codable, CaseIterable, Hashable, Sendable {
    case oftenInSimilarContext = "often_in_similar_context"
    case frequentRecently = "frequent_recently"
    case frequentOverall = "frequent_overall"
    case notUsedYet = "not_used_yet"
}

public struct RankedFoodPreset: Hashable, Sendable {
    public let preset: FoodPreset
    public let strategy: FoodPresetRankingStrategy
    public let reason: FoodPresetRankReason
    public let exactContextUseCount: Int
    public let timeBandUseCount: Int
    public let recentUseCount: Int
    public let lookbackUseCount: Int
    public let lastUsedAt: Date?

    public init(
        preset: FoodPreset,
        strategy: FoodPresetRankingStrategy,
        reason: FoodPresetRankReason,
        exactContextUseCount: Int,
        timeBandUseCount: Int,
        recentUseCount: Int,
        lookbackUseCount: Int,
        lastUsedAt: Date?
    ) {
        self.preset = preset
        self.strategy = strategy
        self.reason = reason
        self.exactContextUseCount = exactContextUseCount
        self.timeBandUseCount = timeBandUseCount
        self.recentUseCount = recentUseCount
        self.lookbackUseCount = lookbackUseCount
        self.lastUsedAt = lastUsedAt
    }
}

public enum FoodPresetRankingError: Error, Equatable, Sendable {
    case invalidClock
    case invalidTimeZone
    case invalidLimit
    case duplicatePresetIdentity
    case conflictingUsageIdentity
}

public enum FoodPresetRanker {
    public static let defaultLimit = 4
    public static let maximumLimit = 100
    public static let recentWindow: TimeInterval = 14 * 24 * 60 * 60
    public static let lookbackWindow: TimeInterval = 90 * 24 * 60 * 60
    public static let minimumContextUseCount = 2

    public static func rank(
        presets: [FoodPreset],
        usages: [FoodPresetUsage],
        context: FoodPresetRankingContext,
        asOf: Date,
        strategy: FoodPresetRankingStrategy = .contextFrequencyV1,
        limit: Int = defaultLimit
    ) throws -> [RankedFoodPreset] {
        guard asOf.timeIntervalSinceReferenceDate.isFinite else {
            throw FoodPresetRankingError.invalidClock
        }
        guard (1 ... maximumLimit).contains(limit) else {
            throw FoodPresetRankingError.invalidLimit
        }
        var activePresets = [UUIDv7: FoodPreset]()
        for preset in presets {
            guard activePresets[preset.metadata.id] == nil else {
                throw FoodPresetRankingError.duplicatePresetIdentity
            }
            if preset.metadata.tombstonedAt == nil {
                activePresets[preset.metadata.id] = preset
            }
        }
        var uniqueUsages = [UUIDv7: FoodPresetUsage]()
        for usage in usages {
            if let existing = uniqueUsages[usage.usageID] {
                guard existing == usage else {
                    throw FoodPresetRankingError.conflictingUsageIdentity
                }
            } else {
                uniqueUsages[usage.usageID] = usage
            }
        }
        let recentCutoff = asOf.addingTimeInterval(-recentWindow)
        let lookbackCutoff = asOf.addingTimeInterval(-lookbackWindow)
        var usageByPreset = [UUIDv7: [FoodPresetUsage]]()
        for usage in uniqueUsages.values where
            usage.occurredAt <= asOf
                && usage.occurredAt >= lookbackCutoff
                && activePresets[usage.presetID] != nil
        {
            usageByPreset[usage.presetID, default: []].append(usage)
        }
        let ranked = activePresets.values.map { preset in
            let matchingUsages = usageByPreset[preset.metadata.id, default: []]
            let exactContextUseCount = matchingUsages.count { $0.context == context }
            let timeBandUseCount = matchingUsages.count {
                $0.context.timeBand == context.timeBand
            }
            let recentUseCount = matchingUsages.count { $0.occurredAt >= recentCutoff }
            let lastUsedAt = matchingUsages.map(\.occurredAt).max()
            let effectiveExactCount = strategy == .contextFrequencyV1
                && exactContextUseCount >= minimumContextUseCount
                ? exactContextUseCount : 0
            let effectiveTimeBandCount = strategy == .contextFrequencyV1
                && timeBandUseCount >= minimumContextUseCount
                ? timeBandUseCount : 0
            let reason: FoodPresetRankReason
            if effectiveExactCount > 0 || effectiveTimeBandCount > 0 {
                reason = .oftenInSimilarContext
            } else if recentUseCount > 0 {
                reason = .frequentRecently
            } else if !matchingUsages.isEmpty {
                reason = .frequentOverall
            } else {
                reason = .notUsedYet
            }
            return RankingCandidate(
                rankedPreset: RankedFoodPreset(
                    preset: preset,
                    strategy: strategy,
                    reason: reason,
                    exactContextUseCount: exactContextUseCount,
                    timeBandUseCount: timeBandUseCount,
                    recentUseCount: recentUseCount,
                    lookbackUseCount: matchingUsages.count,
                    lastUsedAt: lastUsedAt
                ),
                effectiveExactCount: effectiveExactCount,
                effectiveTimeBandCount: effectiveTimeBandCount
            )
        }.sorted(by: candidatePrecedes)
        return ranked.prefix(limit).map(\.rankedPreset)
    }

    private static func candidatePrecedes(
        _ left: RankingCandidate,
        _ right: RankingCandidate
    ) -> Bool {
        let leftRanked = left.rankedPreset
        let rightRanked = right.rankedPreset
        let comparisons = [
            (left.effectiveExactCount, right.effectiveExactCount),
            (left.effectiveTimeBandCount, right.effectiveTimeBandCount),
            (leftRanked.recentUseCount, rightRanked.recentUseCount),
            (leftRanked.lookbackUseCount, rightRanked.lookbackUseCount),
        ]
        for (leftValue, rightValue) in comparisons where leftValue != rightValue {
            return leftValue > rightValue
        }
        if leftRanked.lastUsedAt != rightRanked.lastUsedAt {
            return (leftRanked.lastUsedAt ?? .distantPast)
                > (rightRanked.lastUsedAt ?? .distantPast)
        }
        let leftName = stableName(leftRanked.preset.name)
        let rightName = stableName(rightRanked.preset.name)
        if leftName != rightName {
            return leftName < rightName
        }
        return leftRanked.preset.metadata.id.description
            < rightRanked.preset.metadata.id.description
    }

    private static func stableName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private struct RankingCandidate {
        let rankedPreset: RankedFoodPreset
        let effectiveExactCount: Int
        let effectiveTimeBandCount: Int
    }
}
