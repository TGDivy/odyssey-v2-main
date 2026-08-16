import Foundation
import OdysseyDomain
import Testing

private let foodOccurrenceRecordedAt = Date(timeIntervalSince1970: 1_776_000_000)
private let foodOccurrenceOccurredAt = Date(timeIntervalSince1970: 1_775_970_000)

@Test
func foodOccurrencePreservesPresetRevisionNutrientTotalsAndLocalTime() throws {
    let nutrients = try FoodNutrientProfile(
        energyKilocalories: 840,
        proteinGrams: 36,
        caffeineMilligrams: 120,
        sourceKind: .packageLabel,
        sourceDescription: "Synthetic package label"
    )
    let occurrence = try FoodOccurrence(
        metadata: foodOccurrenceMetadata(1),
        presetID: foodOccurrenceIdentifier(2),
        presetRevision: 4,
        presetNameSnapshot: "Porridge and coffee",
        servingDescriptionSnapshot: "1 breakfast",
        quantity: 2,
        nutrientTotals: nutrients,
        occurredAt: foodOccurrenceOccurredAt,
        timeZoneID: "America/Los_Angeles",
        originalUTCOffsetSeconds: -25_200
    )

    #expect(occurrence.presetRevision == 4)
    #expect(occurrence.quantity == 2)
    #expect(occurrence.nutrientTotals?.energyKilocalories == 840)
    #expect(occurrence.nutrientTotals?.proteinGrams == 36)
    #expect(occurrence.nutrientTotals?.caffeineMilligrams == 120)
    #expect(occurrence.timeZoneID == "America/Los_Angeles")
    #expect(occurrence.originalUTCOffsetSeconds == -25_200)
}

@Test
func foodOccurrenceRejectsInvalidQuantityTemporalContextAndDecodedNutrients() throws {
    let metadata = try foodOccurrenceMetadata(10)
    #expect(throws: FoodOccurrenceValidationError.invalidQuantity) {
        try FoodOccurrence(
            metadata: metadata,
            presetID: foodOccurrenceIdentifier(11),
            presetRevision: 1,
            presetNameSnapshot: "Tea",
            servingDescriptionSnapshot: "1 cup",
            quantity: 0,
            nutrientTotals: nil,
            occurredAt: foodOccurrenceOccurredAt,
            timeZoneID: "UTC",
            originalUTCOffsetSeconds: 0
        )
    }
    #expect(throws: FoodOccurrenceValidationError.invalidTemporalContext) {
        try FoodOccurrence(
            metadata: metadata,
            presetID: foodOccurrenceIdentifier(12),
            presetRevision: 1,
            presetNameSnapshot: "Tea",
            servingDescriptionSnapshot: "1 cup",
            quantity: 1,
            nutrientTotals: nil,
            occurredAt: foodOccurrenceOccurredAt,
            timeZoneID: "America/Los_Angeles",
            originalUTCOffsetSeconds: 0
        )
    }
    let invalidNutrients = try JSONDecoder().decode(
        FoodNutrientProfile.self,
        from: Data(
            """
            {
              "energyKilocalories": -1,
              "proteinGrams": null,
              "caffeineMilligrams": null,
              "alcoholGrams": null,
              "sourceKind": "owner_estimate",
              "sourceDescription": null
            }
            """.utf8
        )
    )
    #expect(throws: FoodOccurrenceValidationError.invalidNutrients) {
        try FoodOccurrence(
            metadata: metadata,
            presetID: foodOccurrenceIdentifier(13),
            presetRevision: 1,
            presetNameSnapshot: "Tea",
            servingDescriptionSnapshot: "1 cup",
            quantity: 1,
            nutrientTotals: invalidNutrients,
            occurredAt: foodOccurrenceOccurredAt,
            timeZoneID: "UTC",
            originalUTCOffsetSeconds: 0
        )
    }
}

private func foodOccurrenceMetadata(_ value: Int) throws -> EntityMetadata {
    try EntityMetadata(
        id: foodOccurrenceIdentifier(value),
        createdAt: foodOccurrenceRecordedAt,
        createdBy: ActorRef(actorType: .user, actorID: "owner"),
        lastRevisedAt: foodOccurrenceRecordedAt,
        revision: 1,
        sensitivity: .sensitive,
        provenanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
    )
}

private func foodOccurrenceIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
