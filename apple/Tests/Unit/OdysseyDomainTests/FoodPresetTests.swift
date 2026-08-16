import Foundation
import OdysseyDomain
import Testing

@Test
func foodPresetPreservesExplicitServingNutrientsAndAliases() throws {
    let preset = try FoodPreset(
        metadata: foodPresetMetadata(1),
        name: "Synthetic porridge",
        servingDescription: "1 bowl",
        aliases: ["Morning oats", "Oat bowl"],
        nutrients: FoodNutrientProfile(
            energyKilocalories: 420,
            proteinGrams: 24,
            caffeineMilligrams: 0,
            sourceKind: .ownerEstimate,
            sourceDescription: "Synthetic test estimate"
        )
    )

    let encoded = try JSONEncoder().encode(preset)
    let decoded = try JSONDecoder().decode(FoodPreset.self, from: encoded)

    #expect(decoded == preset)
    #expect(decoded.metadata.schemaVersion == FoodPreset.currentSchemaVersion)
    #expect(decoded.nutrients?.energyKilocalories == 420)
    #expect(decoded.nutrients?.proteinGrams == 24)
    #expect(decoded.aliases == ["Morning oats", "Oat bowl"])
}

@Test
func foodPresetRejectsAmbiguousNamesMetadataAndNutrientValues() throws {
    #expect(throws: FoodPresetValidationError.emptyNutrientProfile) {
        try FoodNutrientProfile(sourceKind: .ownerEstimate)
    }
    #expect(
        throws: FoodPresetValidationError.invalidNutrientValue("caffeine milligrams")
    ) {
        try FoodNutrientProfile(
            caffeineMilligrams: .infinity,
            sourceKind: .packageLabel
        )
    }
    #expect(throws: FoodPresetValidationError.invalidNutrientSource) {
        try FoodNutrientProfile(
            energyKilocalories: 100,
            sourceKind: .packageLabel
        )
    }
    #expect(throws: FoodPresetValidationError.invalidAliases) {
        try FoodPreset(
            metadata: foodPresetMetadata(2),
            name: "Café bowl",
            servingDescription: "1 bowl",
            aliases: ["Cafe bowl"]
        )
    }
    #expect(throws: FoodPresetValidationError.invalidAliases) {
        try FoodPreset(
            metadata: foodPresetMetadata(3),
            name: "Lunch",
            servingDescription: "1 serving",
            aliases: ["Meal", "meal"]
        )
    }
    #expect(throws: FoodPresetValidationError.invalidMetadata) {
        try FoodPreset(
            metadata: foodPresetMetadata(4, revision: 0),
            name: "Invalid revision",
            servingDescription: "1 serving"
        )
    }
}

private func foodPresetMetadata(
    _ value: Int,
    revision: Int = 1
) throws -> EntityMetadata {
    let date = Date(timeIntervalSince1970: 1_735_689_600)
    return try EntityMetadata(
        id: foodPresetIdentifier(value),
        createdAt: date,
        createdBy: ActorRef(actorType: .user, actorID: "owner"),
        lastRevisedAt: date,
        revision: revision,
        sensitivity: .private,
        provenanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    )
}

private func foodPresetIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
