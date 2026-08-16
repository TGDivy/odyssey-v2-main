import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseyExtensionBridge
import Testing

private let extensionProcessingCreatedAt = Date(timeIntervalSince1970: 1_786_752_000)
private let extensionProcessingRecordedAt = Date(timeIntervalSince1970: 1_786_752_120)

@Test
func extensionProcessorReplaysTextCommandWithoutDuplicateMutation() async throws {
    let fixture = try ExtensionCommandProcessorFixture()
    defer { fixture.remove() }
    let command = try ExtensionCommand.captureText(
        "Queued extension capture",
        commandID: extensionProcessingIdentifier(10),
        createdAt: extensionProcessingCreatedAt,
        invokingSurface: .widget
    )

    let first = try await fixture.processor.process(
        command,
        captureTimeZoneID: "UTC",
        captureLocationPermissionState: .unavailable
    )
    let replay = try await fixture.processor.process(
        command,
        captureTimeZoneID: "America/Los_Angeles",
        captureLocationPermissionState: .denied
    )

    guard case let .captureCommitted(receipt) = first,
          case let .captureAlreadyCommitted(replayedCapture) = replay
    else {
        Issue.record("Expected one committed capture followed by an idempotent replay.")
        return
    }
    #expect(receipt.capture.metadata.id == command.commandID)
    #expect(receipt.operationID == command.commandID)
    #expect(receipt.capture.capturedAt == extensionProcessingCreatedAt)
    #expect(receipt.capture.initialContext.invokingSurface == .widget)
    #expect(replayedCapture == receipt.capture)
    #expect(try fixture.store.storedEntries().count == 1)
    #expect(try await fixture.store.pendingSyncOperations().count == 1)
}

@Test
func extensionProcessorReplaysFoodCommandWithoutDuplicateMutation() async throws {
    let fixture = try ExtensionCommandProcessorFixture()
    defer { fixture.remove() }
    let preset = try await fixture.presetService.create(
        FoodPresetDraft(
            name: "Synthetic snack",
            servingDescription: "1 portion",
            nutrients: FoodNutrientProfile(
                energyKilocalories: 150,
                proteinGrams: 5,
                sourceKind: .ownerEstimate
            )
        )
    ).preset
    let command = try ExtensionCommand.logFood(
        presetID: preset.metadata.id,
        expectedPresetRevision: preset.metadata.revision,
        quantity: 1.5,
        occurredAt: extensionProcessingCreatedAt,
        timeZoneID: "UTC",
        commandID: extensionProcessingIdentifier(20),
        createdAt: extensionProcessingRecordedAt,
        invokingSurface: .control
    )

    let first = try await fixture.processor.process(
        command,
        captureTimeZoneID: "UTC",
        captureLocationPermissionState: .unavailable
    )
    let replay = try await fixture.processor.process(
        command,
        captureTimeZoneID: "UTC",
        captureLocationPermissionState: .unavailable
    )

    guard case let .foodCommitted(receipt) = first,
          case let .foodAlreadyCommitted(replayedOccurrence) = replay
    else {
        Issue.record("Expected one committed food log followed by an idempotent replay.")
        return
    }
    #expect(receipt.occurrence.metadata.id == command.commandID)
    #expect(receipt.operationID == command.commandID)
    #expect(replayedOccurrence == receipt.occurrence)
    #expect(try fixture.store.storedEntries().count == 2)
    #expect(try await fixture.store.pendingSyncOperations().count == 2)
}

private struct ExtensionCommandProcessorFixture {
    let directory: URL
    let store: SQLiteLedgerStore
    let presetService: FoodPresetService
    let processor: ExtensionCommandProcessor

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-extension-processor-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: try extensionProcessingIdentifier(900),
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { extensionProcessingRecordedAt }
        ))
        self.store = store
        let captureService = try ManualCaptureService(
            store: store,
            deviceID: try extensionProcessingIdentifier(900),
            clock: { extensionProcessingRecordedAt }
        )
        presetService = try FoodPresetService(
            store: store,
            clock: { extensionProcessingCreatedAt }
        )
        let occurrenceService = try FoodOccurrenceService(
            store: store,
            clock: { extensionProcessingRecordedAt }
        )
        processor = ExtensionCommandProcessor(
            store: store,
            captureService: captureService,
            foodOccurrenceService: occurrenceService
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func extensionProcessingIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
