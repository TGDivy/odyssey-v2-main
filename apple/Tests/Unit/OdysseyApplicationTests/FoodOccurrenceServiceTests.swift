import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let foodLogPresetAt = Date(timeIntervalSince1970: 1_775_952_000)
private let foodLogOccurredAt = Date(timeIntervalSince1970: 1_775_970_000)
private let foodLogRecordedAt = Date(timeIntervalSince1970: 1_775_973_600)
private let foodLogRevisedAt = Date(timeIntervalSince1970: 1_776_060_000)
private let foodLogCorrectedAt = Date(timeIntervalSince1970: 1_776_063_600)
private let foodLogVoidedAt = Date(timeIntervalSince1970: 1_776_150_000)

@Test
func foodOccurrenceServiceRecordsSnapshotAtomicallyAndFeedsRanking() async throws {
    let fixture = try FoodOccurrenceServiceFixture()
    defer { fixture.remove() }
    let preset = try await fixture.presetService(at: foodLogPresetAt).create(
        FoodPresetDraft(
            name: "Porridge and coffee",
            servingDescription: "1 breakfast",
            aliases: ["Breakfast"],
            nutrients: FoodNutrientProfile(
                energyKilocalories: 420,
                proteinGrams: 18,
                caffeineMilligrams: 60,
                sourceKind: .packageLabel,
                sourceDescription: "Synthetic package label"
            )
        )
    )
    let service = try fixture.occurrenceService(at: foodLogRecordedAt)

    let receipt = try await service.record(FoodOccurrenceDraft(
        presetID: preset.preset.metadata.id,
        expectedPresetRevision: 1,
        quantity: 2,
        occurredAt: foodLogOccurredAt,
        timeZoneID: "America/Los_Angeles"
    ))

    #expect(receipt.occurrence.metadata.revision == 1)
    #expect(receipt.occurrence.metadata.sensitivity == .sensitive)
    #expect(receipt.occurrence.presetRevision == 1)
    #expect(receipt.occurrence.presetNameSnapshot == "Porridge and coffee")
    #expect(receipt.occurrence.quantity == 2)
    #expect(receipt.occurrence.nutrientTotals?.energyKilocalories == 840)
    #expect(receipt.occurrence.nutrientTotals?.proteinGrams == 36)
    #expect(receipt.occurrence.nutrientTotals?.caffeineMilligrams == 120)
    #expect(receipt.occurrence.originalUTCOffsetSeconds == -25_200)
    #expect(receipt.deviceSequence == 2)
    let entries = try fixture.store.storedEntries()
    #expect(entries.count == 2)
    #expect(entries[1].entry.eventType == FoodOccurrenceService.consumedEventType)
    #expect(entries[1].entry.occurredAt == foodLogOccurredAt)
    #expect(entries[1].entry.recordedAt == foodLogRecordedAt)
    let eventPayload = try SyncJSONCoding.makeDecoder().decode(
        [String: JSONValue].self,
        from: entries[1].entry.payload
    )
    #expect(
        eventPayload["food_occurrence_id"]
            == .string(receipt.occurrence.metadata.id.description)
    )
    #expect(
        eventPayload["food_preset_id"]
            == .string(preset.preset.metadata.id.description)
    )
    let operations = try await fixture.store.pendingSyncOperations()
    #expect(operations.count == 2)
    #expect(operations[1].mutationType == .create)
    #expect(operations[1].baseRevision == nil)
    #expect(operations[1].sensitivityClass == .sensitive)
    let usages = try await service.rankingUsages()
    #expect(usages.count == 1)
    #expect(usages[0].usageID == receipt.occurrence.metadata.id)
    #expect(usages[0].presetID == preset.preset.metadata.id)
    #expect(usages[0].context.timeBand == .other)
    #expect(usages[0].context.dayKind == .weekend)
}

@Test
func foodOccurrenceServicePreservesSnapshotUntilExplicitCorrection() async throws {
    let fixture = try FoodOccurrenceServiceFixture()
    defer { fixture.remove() }
    let originalNutrients = try FoodNutrientProfile(
        energyKilocalories: 100,
        sourceKind: .ownerEstimate
    )
    let initialPreset = try await fixture.presetService(at: foodLogPresetAt).create(
        FoodPresetDraft(
            name: "Snack",
            servingDescription: "1 portion",
            nutrients: originalNutrients
        )
    )
    let occurrenceService = try fixture.occurrenceService(at: foodLogRecordedAt)
    let recorded = try await occurrenceService.record(FoodOccurrenceDraft(
        presetID: initialPreset.preset.metadata.id,
        expectedPresetRevision: 1,
        occurredAt: foodLogOccurredAt,
        timeZoneID: "UTC"
    ))
    let revisedPreset = try await fixture.presetService(at: foodLogRevisedAt).revise(
        presetID: initialPreset.preset.metadata.id,
        expectedRevision: 1,
        draft: FoodPresetDraft(
            name: "Snack",
            servingDescription: "1 portion",
            nutrients: FoodNutrientProfile(
                energyKilocalories: 150,
                sourceKind: .ownerEstimate
            )
        )
    )

    let unchangedHistory = try await occurrenceService.occurrence(
        id: recorded.occurrence.metadata.id
    )
    #expect(unchangedHistory.presetRevision == 1)
    #expect(unchangedHistory.nutrientTotals?.energyKilocalories == 100)

    let correctionService = try fixture.occurrenceService(at: foodLogCorrectedAt)
    let corrected = try await correctionService.correct(
        occurrenceID: recorded.occurrence.metadata.id,
        draft: FoodOccurrenceCorrectionDraft(
            expectedOccurrenceRevision: 1,
            presetID: revisedPreset.preset.metadata.id,
            expectedPresetRevision: 2,
            quantity: 2,
            occurredAt: foodLogOccurredAt,
            timeZoneID: "UTC"
        )
    )
    #expect(corrected.occurrence.metadata.revision == 2)
    #expect(corrected.occurrence.metadata.id == recorded.occurrence.metadata.id)
    #expect(
        corrected.occurrence.metadata.provenanceID
            == recorded.occurrence.metadata.provenanceID
    )
    #expect(corrected.occurrence.presetRevision == 2)
    #expect(corrected.occurrence.quantity == 2)
    #expect(corrected.occurrence.nutrientTotals?.energyKilocalories == 300)
    let operations = try await fixture.store.pendingSyncOperations()
    #expect(operations.count == 4)
    let update = operations[3]
    #expect(update.mutationType == .update)
    #expect(update.baseRevision == 1)
    let updatePayload = try SyncJSONCoding.makeDecoder().decode(
        [String: JSONValue].self,
        from: update.payload
    )
    #expect(updatePayload["metadata"] != nil)
    #expect(updatePayload["preset_revision"] == .number(2))
    #expect(updatePayload["quantity"] == .number(2))
    #expect(updatePayload["nutrient_totals"] != nil)

    await #expect(
        throws: FoodOccurrenceServiceError.staleOccurrenceRevision(
            expected: 1,
            actual: 2
        )
    ) {
        try await correctionService.correct(
            occurrenceID: recorded.occurrence.metadata.id,
            draft: FoodOccurrenceCorrectionDraft(
                expectedOccurrenceRevision: 1,
                presetID: revisedPreset.preset.metadata.id,
                expectedPresetRevision: 2,
                quantity: 1,
                occurredAt: foodLogOccurredAt,
                timeZoneID: "UTC"
            )
        )
    }
    #expect(try fixture.store.storedEntries().count == 4)
}

@Test
func foodOccurrenceServiceVoidsAndRejectsFutureOrStaleLogsWithoutMutation() async throws {
    let fixture = try FoodOccurrenceServiceFixture()
    defer { fixture.remove() }
    let preset = try await fixture.presetService(at: foodLogPresetAt).create(
        FoodPresetDraft(name: "Tea", servingDescription: "1 cup")
    )
    let service = try fixture.occurrenceService(at: foodLogRecordedAt)

    await #expect(
        throws: FoodOccurrenceServiceError.stalePresetRevision(expected: 2, actual: 1)
    ) {
        try await service.record(FoodOccurrenceDraft(
            presetID: preset.preset.metadata.id,
            expectedPresetRevision: 2,
            occurredAt: foodLogOccurredAt,
            timeZoneID: "UTC"
        ))
    }
    await #expect(throws: FoodOccurrenceValidationError.invalidTemporalContext) {
        try await service.record(FoodOccurrenceDraft(
            presetID: preset.preset.metadata.id,
            expectedPresetRevision: 1,
            occurredAt: foodLogRecordedAt.addingTimeInterval(1),
            timeZoneID: "UTC"
        ))
    }
    let recorded = try await service.record(FoodOccurrenceDraft(
        presetID: preset.preset.metadata.id,
        expectedPresetRevision: 1,
        occurredAt: foodLogOccurredAt,
        timeZoneID: "UTC"
    ))
    let voidService = try fixture.occurrenceService(at: foodLogVoidedAt)
    let voided = try await voidService.void(
        occurrenceID: recorded.occurrence.metadata.id,
        expectedRevision: 1
    )

    #expect(voided.occurrence.metadata.revision == 2)
    #expect(voided.occurrence.metadata.tombstonedAt == foodLogVoidedAt)
    #expect(try await voidService.recentOccurrences().isEmpty)
    #expect(try await voidService.rankingUsages().isEmpty)
    #expect(try await voidService.voidedOccurrenceIDs() == [recorded.occurrence.metadata.id])
    await #expect(throws: FoodOccurrenceServiceError.occurrenceVoided) {
        try await voidService.occurrence(id: recorded.occurrence.metadata.id)
    }
    let operations = try await fixture.store.pendingSyncOperations()
    #expect(operations.count == 3)
    #expect(operations[2].mutationType == .delete)
    #expect(operations[2].baseRevision == 1)
    #expect(operations[2].payload == Data("{}".utf8))
    let projection = try fixture.store.projectedEntity(
        entityType: FoodOccurrenceService.entityType,
        entityID: recorded.occurrence.metadata.id
    )
    #expect(projection?.tombstone == true)
    #expect(try fixture.store.storedEntries().count == 3)
}

private struct FoodOccurrenceServiceFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-food-occurrence-service-\(UUID().uuidString)",
            isDirectory: true
        )
        store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: try foodLogIdentifier(900),
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { foodLogPresetAt }
        ))
    }

    func presetService(at date: Date) throws -> FoodPresetService {
        try FoodPresetService(
            store: store,
            clock: { date },
            provenanceIdentifier: {
                UUID(uuidString: "00000000-0000-4000-8000-000000000900")!
            }
        )
    }

    func occurrenceService(at date: Date) throws -> FoodOccurrenceService {
        try FoodOccurrenceService(
            store: store,
            clock: { date },
            provenanceIdentifier: {
                UUID(uuidString: "00000000-0000-4000-8000-000000000901")!
            }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func foodLogIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
