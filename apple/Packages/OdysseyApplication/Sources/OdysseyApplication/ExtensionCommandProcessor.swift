import Foundation
import OdysseyData
import OdysseyDomain
import OdysseyExtensionBridge
import OdysseySync

public protocol ExtensionCommandProjectionStore: Sendable {
    func projectedEntity(
        entityType: String,
        entityID: UUIDv7
    ) throws -> ProjectedEntity?
}

extension SQLiteLedgerStore: ExtensionCommandProjectionStore {}

public enum ExtensionCommandProcessingError: Error, Equatable, Sendable {
    case invalidPayload
    case idempotencyConflict
    case expiredPresentation
}

public enum ExtensionCommandPresentation: Hashable, Sendable {
    case capture
    case food
}

public enum ExtensionCommandProcessingResult: Hashable, Sendable {
    case captureCommitted(ManualCaptureReceipt)
    case captureAlreadyCommitted(CaptureRecord)
    case foodCommitted(FoodOccurrenceCommitReceipt)
    case foodAlreadyCommitted(FoodOccurrence)
    case presentationRequested(ExtensionCommandPresentation)

    public var committedNewMutation: Bool {
        switch self {
        case .captureCommitted, .foodCommitted:
            true
        case .captureAlreadyCommitted, .foodAlreadyCommitted, .presentationRequested:
            false
        }
    }
}

public actor ExtensionCommandProcessor {
    public static let maximumPresentationAge: TimeInterval = 5 * 60
    public static let maximumFutureClockSkew: TimeInterval = 60

    private let store: any ExtensionCommandProjectionStore
    private let captureService: ManualCaptureService
    private let foodOccurrenceService: FoodOccurrenceService
    private let clock: @Sendable () -> Date

    public init(
        store: any ExtensionCommandProjectionStore,
        captureService: ManualCaptureService,
        foodOccurrenceService: FoodOccurrenceService,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.captureService = captureService
        self.foodOccurrenceService = foodOccurrenceService
        self.clock = clock
    }

    public func process(
        _ command: ExtensionCommand,
        captureTimeZoneID: String,
        captureLocationPermissionState: CaptureLocationPermissionState
    ) async throws -> ExtensionCommandProcessingResult {
        switch command.kind {
        case .captureText:
            try await processText(
                command,
                timeZoneID: captureTimeZoneID,
                locationPermissionState: captureLocationPermissionState
            )
        case .logFood:
            try await processFood(command)
        case .presentCapture:
            try presentationResult(for: command, presentation: .capture)
        case .presentFood:
            try presentationResult(for: command, presentation: .food)
        }
    }

    private func presentationResult(
        for command: ExtensionCommand,
        presentation: ExtensionCommandPresentation
    ) throws -> ExtensionCommandProcessingResult {
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite,
              command.createdAt <= now.addingTimeInterval(Self.maximumFutureClockSkew),
              now.timeIntervalSince(command.createdAt) <= Self.maximumPresentationAge
        else {
            throw ExtensionCommandProcessingError.expiredPresentation
        }
        return .presentationRequested(presentation)
    }

    private func processText(
        _ command: ExtensionCommand,
        timeZoneID: String,
        locationPermissionState: CaptureLocationPermissionState
    ) async throws -> ExtensionCommandProcessingResult {
        guard let text = command.text else {
            throw ExtensionCommandProcessingError.invalidPayload
        }
        let invokingSurface = captureSurface(for: command.invokingSurface)
        if let projection = try store.projectedEntity(
            entityType: ManualCaptureService.entityType,
            entityID: command.commandID
        ) {
            guard !projection.tombstone,
                  let capture = try? SyncJSONCoding.makeDecoder().decode(
                      CaptureRecord.self,
                      from: projection.document
                  ),
                  capture.metadata.id == command.commandID,
                  capture.capturedAt == command.createdAt,
                  capture.originalPayload.kind == .text,
                  capture.originalPayload.contentOrObjectRef == text,
                  capture.initialContext.invokingSurface == invokingSurface
            else {
                throw ExtensionCommandProcessingError.idempotencyConflict
            }
            return .captureAlreadyCommitted(capture)
        }

        let receipt = try await captureService.record(
            ManualCaptureDraft.text(
                text,
                capturedAt: command.createdAt,
                sourceCommandID: command.commandID,
                timeZoneID: timeZoneID,
                locationPermissionState: locationPermissionState,
                invokingSurface: invokingSurface
            )
        )
        return .captureCommitted(receipt)
    }

    private func processFood(
        _ command: ExtensionCommand
    ) async throws -> ExtensionCommandProcessingResult {
        guard let presetID = command.presetID,
              let expectedRevision = command.expectedPresetRevision,
              let quantity = command.quantity,
              let occurredAt = command.occurredAt,
              let timeZoneID = command.timeZoneID
        else {
            throw ExtensionCommandProcessingError.invalidPayload
        }
        if let projection = try store.projectedEntity(
            entityType: FoodOccurrenceService.entityType,
            entityID: command.commandID
        ) {
            guard let occurrence = try? SyncJSONCoding.makeDecoder().decode(
                FoodOccurrence.self,
                from: projection.document
            ),
                occurrence.metadata.id == command.commandID,
                occurrence.presetID == presetID,
                occurrence.presetRevision == expectedRevision,
                occurrence.quantity == quantity,
                occurrence.occurredAt == occurredAt,
                occurrence.timeZoneID == timeZoneID
            else {
                throw ExtensionCommandProcessingError.idempotencyConflict
            }
            return .foodAlreadyCommitted(occurrence)
        }

        let receipt = try await foodOccurrenceService.record(
            FoodOccurrenceDraft(
                presetID: presetID,
                expectedPresetRevision: expectedRevision,
                quantity: quantity,
                occurredAt: occurredAt,
                timeZoneID: timeZoneID,
                sourceCommandID: command.commandID
            )
        )
        return .foodCommitted(receipt)
    }

    private func captureSurface(
        for surface: ExtensionInvokingSurface
    ) -> CaptureInvokingSurface {
        switch surface {
        case .appIntent:
            .appIntent
        case .control:
            .control
        case .widget:
            .widget
        case .watch:
            .watchQuickAction
        }
    }
}
