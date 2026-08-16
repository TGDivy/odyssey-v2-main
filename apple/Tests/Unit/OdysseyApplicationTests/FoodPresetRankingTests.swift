import Foundation
import OdysseyApplication
import OdysseyDomain
import Testing

private let foodRankingNow = Date(timeIntervalSince1970: 1_735_689_600)
private let foodRankingMorning = FoodPresetRankingContext(
    timeBand: .morning,
    dayKind: .weekday
)
private let foodRankingEvening = FoodPresetRankingContext(
    timeBand: .evening,
    dayKind: .weekday
)

@Test
func foodPresetContextUsesStableLocalTimeBandsAndDayKinds() throws {
    let mondayMorning = Date(timeIntervalSince1970: 1_736_150_400)
    let sundayEvening = Date(timeIntervalSince1970: 1_736_100_000)

    #expect(
        try FoodPresetRankingContext(occurredAt: mondayMorning, timeZoneID: "UTC")
            == FoodPresetRankingContext(timeBand: .morning, dayKind: .weekday)
    )
    #expect(
        try FoodPresetRankingContext(occurredAt: sundayEvening, timeZoneID: "UTC")
            == FoodPresetRankingContext(timeBand: .evening, dayKind: .weekend)
    )
    #expect(throws: FoodPresetRankingError.invalidTimeZone) {
        try FoodPresetRankingContext(
            occurredAt: foodRankingNow,
            timeZoneID: "Not/A-TimeZone"
        )
    }
}

@Test
func foodPresetRankingRequiresRepeatedContextBeforeContextCanLead() throws {
    let frequent = try foodRankingPreset(1, name: "Frequent bowl")
    let contextual = try foodRankingPreset(2, name: "Morning bowl")
    let frequentUsages = try (1 ... 5).map {
        try foodRankingUsage(
            100 + $0,
            presetID: frequent.metadata.id,
            daysAgo: $0,
            context: foodRankingEvening
        )
    }
    let oneContextUse = try foodRankingUsage(
        200,
        presetID: contextual.metadata.id,
        daysAgo: 2,
        context: foodRankingMorning
    )

    let sparse = try FoodPresetRanker.rank(
        presets: [contextual, frequent],
        usages: frequentUsages + [oneContextUse],
        context: foodRankingMorning,
        asOf: foodRankingNow
    )
    let repeated = try FoodPresetRanker.rank(
        presets: [contextual, frequent],
        usages: frequentUsages + [
            oneContextUse,
            foodRankingUsage(
                201,
                presetID: contextual.metadata.id,
                daysAgo: 4,
                context: foodRankingMorning
            ),
        ],
        context: foodRankingMorning,
        asOf: foodRankingNow
    )

    #expect(sparse.map(\.preset.metadata.id) == [frequent.metadata.id, contextual.metadata.id])
    #expect(repeated.first?.preset.metadata.id == contextual.metadata.id)
    #expect(repeated.first?.reason == .oftenInSimilarContext)
    #expect(repeated.first?.exactContextUseCount == 2)
}

@Test
func frequencyOnlyStrategyIgnoresContextAndKeepsItsVersionVisible() throws {
    let frequent = try foodRankingPreset(10, name: "Frequent")
    let contextual = try foodRankingPreset(11, name: "Contextual")
    let usages = try (1 ... 4).map {
        try foodRankingUsage(
            300 + $0,
            presetID: frequent.metadata.id,
            daysAgo: $0,
            context: foodRankingEvening
        )
    } + (1 ... 2).map {
        try foodRankingUsage(
            400 + $0,
            presetID: contextual.metadata.id,
            daysAgo: $0,
            context: foodRankingMorning
        )
    }

    let ranked = try FoodPresetRanker.rank(
        presets: [contextual, frequent],
        usages: usages,
        context: foodRankingMorning,
        asOf: foodRankingNow,
        strategy: .frequencyOnlyV1
    )

    #expect(ranked.first?.preset.metadata.id == frequent.metadata.id)
    #expect(ranked.allSatisfy { $0.strategy == .frequencyOnlyV1 })
    #expect(ranked.first?.reason == .frequentRecently)
}

@Test
func foodPresetRankingIgnoresOldFutureUnknownAndTombstonedHistory() throws {
    let alpha = try foodRankingPreset(20, name: "Álpha")
    let beta = try foodRankingPreset(21, name: "Beta")
    let archived = try foodRankingPreset(22, name: "Archived", tombstoned: true)
    let charlie = try foodRankingPreset(23, name: "Charlie")
    let duplicate = try foodRankingUsage(
        500,
        presetID: beta.metadata.id,
        daysAgo: 10,
        context: foodRankingEvening
    )
    let ranked = try FoodPresetRanker.rank(
        presets: [charlie, beta, archived, alpha],
        usages: [
            duplicate,
            duplicate,
            try foodRankingUsage(
                501,
                presetID: beta.metadata.id,
                daysAgo: 91,
                context: foodRankingEvening
            ),
            try foodRankingUsage(
                502,
                presetID: beta.metadata.id,
                daysAgo: -1,
                context: foodRankingMorning
            ),
            try foodRankingUsage(
                503,
                presetID: archived.metadata.id,
                daysAgo: 1,
                context: foodRankingMorning
            ),
            try foodRankingUsage(
                504,
                presetID: foodRankingIdentifier(99),
                daysAgo: 1,
                context: foodRankingMorning
            ),
        ],
        context: foodRankingMorning,
        asOf: foodRankingNow,
        limit: 3
    )

    #expect(
        ranked.map(\.preset.metadata.id)
            == [beta.metadata.id, alpha.metadata.id, charlie.metadata.id]
    )
    #expect(ranked.first?.lookbackUseCount == 1)
    #expect(!ranked.contains { $0.preset.metadata.id == archived.metadata.id })
}

@Test
func foodPresetRankingRejectsConflictingIdentitiesAndInvalidRequests() throws {
    let first = try foodRankingPreset(30, name: "First")
    let second = try foodRankingPreset(31, name: "Second")
    let usageID = try foodRankingIdentifier(600)
    let firstUsage = try FoodPresetUsage(
        usageID: usageID,
        presetID: first.metadata.id,
        occurredAt: foodRankingNow,
        context: foodRankingMorning
    )
    let conflictingUsage = try FoodPresetUsage(
        usageID: usageID,
        presetID: second.metadata.id,
        occurredAt: foodRankingNow,
        context: foodRankingMorning
    )

    #expect(throws: FoodPresetRankingError.duplicatePresetIdentity) {
        try FoodPresetRanker.rank(
            presets: [first, first],
            usages: [],
            context: foodRankingMorning,
            asOf: foodRankingNow
        )
    }
    #expect(throws: FoodPresetRankingError.conflictingUsageIdentity) {
        try FoodPresetRanker.rank(
            presets: [first, second],
            usages: [firstUsage, conflictingUsage],
            context: foodRankingMorning,
            asOf: foodRankingNow
        )
    }
    #expect(throws: FoodPresetRankingError.invalidLimit) {
        try FoodPresetRanker.rank(
            presets: [first],
            usages: [],
            context: foodRankingMorning,
            asOf: foodRankingNow,
            limit: 0
        )
    }
}

private func foodRankingPreset(
    _ value: Int,
    name: String,
    tombstoned: Bool = false
) throws -> FoodPreset {
    let tombstonedAt = tombstoned ? foodRankingNow : nil
    return try FoodPreset(
        metadata: EntityMetadata(
            id: foodRankingIdentifier(value),
            createdAt: foodRankingNow.addingTimeInterval(-120 * 24 * 60 * 60),
            createdBy: ActorRef(actorType: .user, actorID: "owner"),
            lastRevisedAt: foodRankingNow,
            revision: 1,
            tombstonedAt: tombstonedAt,
            sensitivity: .private,
            provenanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        ),
        name: name,
        servingDescription: "1 serving"
    )
}

private func foodRankingUsage(
    _ value: Int,
    presetID: UUIDv7,
    daysAgo: Int,
    context: FoodPresetRankingContext
) throws -> FoodPresetUsage {
    try FoodPresetUsage(
        usageID: foodRankingIdentifier(value),
        presetID: presetID,
        occurredAt: foodRankingNow.addingTimeInterval(
            -Double(daysAgo) * 24 * 60 * 60
        ),
        context: context
    )
}

private func foodRankingIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
