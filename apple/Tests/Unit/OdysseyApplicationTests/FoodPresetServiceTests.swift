import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let foodServiceCreatedAt = Date(timeIntervalSince1970: 1_772_424_000)
private let foodServiceRevisedAt = Date(timeIntervalSince1970: 1_772_510_400)
private let foodServiceArchivedAt = Date(timeIntervalSince1970: 1_772_596_800)

@Test
func foodPresetServiceCreatesProjectionEventAndOutboxAtomically() async throws {
    let fixture = try FoodPresetServiceFixture()
    defer { fixture.remove() }
    let nutrients = try FoodNutrientProfile(
        energyKilocalories: 420,
        proteinGrams: 18,
        sourceKind: .packageLabel,
        sourceDescription: "Synthetic package label"
    )
    let service = try fixture.service(at: foodServiceCreatedAt)

    let receipt = try await service.create(FoodPresetDraft(
        name: "Porridge",
        servingDescription: "1 bowl",
        aliases: ["Oats"],
        nutrients: nutrients
    ))

    #expect(receipt.preset.metadata.revision == 1)
    #expect(receipt.preset.metadata.createdAt == foodServiceCreatedAt)
    #expect(receipt.preset.metadata.createdBy.actorID == "owner")
    #expect(receipt.mutationType == .create)
    #expect(receipt.deviceSequence == 1)
    let stored = try fixture.store.storedEntries()
    #expect(stored.count == 1)
    #expect(stored[0].entry.eventID == receipt.eventID)
    #expect(stored[0].entry.eventType == FoodPresetService.createdEventType)
    let eventPayload = try SyncJSONCoding.makeDecoder().decode(
        [String: JSONValue].self,
        from: stored[0].entry.payload
    )
    #expect(eventPayload["food_preset_id"] == .string(receipt.preset.metadata.id.description))
    let storedProjection = try fixture.store.projectedEntity(
        entityType: FoodPresetService.entityType,
        entityID: receipt.preset.metadata.id
    )
    let projection = try #require(storedProjection)
    #expect(projection.revision == 1)
    #expect(!projection.tombstone)
    #expect(try SyncJSONCoding.makeDecoder().decode(
        FoodPreset.self,
        from: projection.document
    ) == receipt.preset)
    let operations = try await fixture.store.pendingSyncOperations()
    #expect(operations.count == 1)
    #expect(operations[0].operationID == receipt.operationID)
    #expect(operations[0].mutationType == .create)
    #expect(operations[0].baseRevision == nil)
    #expect(try SyncJSONCoding.makeDecoder().decode(
        FoodPreset.self,
        from: operations[0].payload
    ) == receipt.preset)
    #expect(try await service.activePresets() == [receipt.preset])
}

@Test
func foodPresetServiceRevisesWithPartialSyncPayloadThenArchives() async throws {
    let fixture = try FoodPresetServiceFixture()
    defer { fixture.remove() }
    let nutrients = try FoodNutrientProfile(
        caffeineMilligrams: 120,
        sourceKind: .ownerEstimate
    )
    let created = try await fixture.service(at: foodServiceCreatedAt).create(
        FoodPresetDraft(
            name: "Coffee",
            servingDescription: "1 mug",
            aliases: ["Morning coffee"],
            nutrients: nutrients
        ),
        sensitivity: .sensitive
    )
    let revisingService = try fixture.service(at: foodServiceRevisedAt)
    let revised = try await revisingService.revise(
        presetID: created.preset.metadata.id,
        expectedRevision: 1,
        draft: FoodPresetDraft(
            name: "Filter coffee",
            servingDescription: "1 mug",
            aliases: ["Morning coffee"]
        )
    )

    #expect(revised.preset.metadata.revision == 2)
    #expect(revised.preset.metadata.id == created.preset.metadata.id)
    #expect(revised.preset.metadata.createdAt == created.preset.metadata.createdAt)
    #expect(revised.preset.metadata.provenanceID == created.preset.metadata.provenanceID)
    #expect(revised.preset.metadata.sensitivity == .sensitive)
    let afterRevision = try await fixture.store.pendingSyncOperations()
    #expect(afterRevision.count == 2)
    let update = afterRevision[1]
    #expect(update.mutationType == .update)
    #expect(update.baseRevision == 1)
    let updatePayload = try SyncJSONCoding.makeDecoder().decode(
        [String: JSONValue].self,
        from: update.payload
    )
    #expect(Set(updatePayload.keys) == ["metadata", "name", "nutrients"])
    #expect(updatePayload["serving_description"] == nil)
    #expect(updatePayload["nutrients"] == .null)

    await #expect(
        throws: FoodPresetServiceError.staleRevision(expected: 1, actual: 2)
    ) {
        try await revisingService.revise(
            presetID: created.preset.metadata.id,
            expectedRevision: 1,
            draft: FoodPresetDraft(
                name: "Stale edit",
                servingDescription: "1 mug"
            )
        )
    }
    #expect(try fixture.store.storedEntries().count == 2)

    let archiveService = try fixture.service(at: foodServiceArchivedAt)
    let archived = try await archiveService.archive(
        presetID: created.preset.metadata.id,
        expectedRevision: 2
    )
    #expect(archived.mutationType == .delete)
    #expect(archived.preset.metadata.revision == 3)
    #expect(archived.preset.metadata.tombstonedAt == foodServiceArchivedAt)
    #expect(try await archiveService.activePresets().isEmpty)
    #expect(try await archiveService.preset(id: created.preset.metadata.id) == archived.preset)
    let operations = try await fixture.store.pendingSyncOperations()
    #expect(operations.count == 3)
    #expect(operations[2].mutationType == .delete)
    #expect(operations[2].baseRevision == 2)
    #expect(operations[2].payload == Data("{}".utf8))
    let storedProjection = try fixture.store.projectedEntity(
        entityType: FoodPresetService.entityType,
        entityID: created.preset.metadata.id
    )
    let projection = try #require(storedProjection)
    #expect(projection.revision == 3)
    #expect(projection.tombstone)
    #expect(try fixture.store.storedEntries().map(\.entry.eventType) == [
        FoodPresetService.createdEventType,
        FoodPresetService.revisedEventType,
        FoodPresetService.revisedEventType,
    ])
}

@Test
func foodPresetServiceRejectsNoopInvalidClockAndInvalidDraftWithoutMutation() async throws {
    let fixture = try FoodPresetServiceFixture()
    defer { fixture.remove() }
    let draft = FoodPresetDraft(name: "Tea", servingDescription: "1 cup")
    let created = try await fixture.service(at: foodServiceCreatedAt).create(draft)
    let service = try fixture.service(at: foodServiceCreatedAt.addingTimeInterval(-1))

    await #expect(throws: FoodPresetServiceError.noChanges) {
        try await service.revise(
            presetID: created.preset.metadata.id,
            expectedRevision: 1,
            draft: draft
        )
    }
    await #expect(throws: FoodPresetServiceError.invalidClock) {
        try await service.revise(
            presetID: created.preset.metadata.id,
            expectedRevision: 1,
            draft: FoodPresetDraft(name: "Green tea", servingDescription: "1 cup")
        )
    }
    await #expect(throws: FoodPresetValidationError.invalidName) {
        try await fixture.service(at: foodServiceRevisedAt).create(
            FoodPresetDraft(name: " ", servingDescription: "1 cup")
        )
    }

    #expect(try fixture.store.storedEntries().count == 1)
    #expect(try await fixture.store.pendingSyncOperations().count == 1)
    #expect(try await service.preset(id: created.preset.metadata.id) == created.preset)
}

private struct FoodPresetServiceFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-food-preset-service-\(UUID().uuidString)",
            isDirectory: true
        )
        store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: try foodServiceIdentifier(900),
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { foodServiceCreatedAt }
        ))
    }

    func service(at date: Date) throws -> FoodPresetService {
        try FoodPresetService(
            store: store,
            clock: { date },
            provenanceIdentifier: {
                UUID(uuidString: "00000000-0000-4000-8000-000000000900")!
            }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func foodServiceIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
