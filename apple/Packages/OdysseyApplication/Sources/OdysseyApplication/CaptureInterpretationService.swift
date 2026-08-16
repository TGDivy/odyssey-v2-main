import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public protocol CaptureInterpretationStore: LedgerStore {
    func projectedEntity(
        entityType: String,
        entityID: UUIDv7
    ) throws -> ProjectedEntity?
    func projectedEntities(
        entityType: String,
        limit: Int
    ) throws -> [ProjectedEntity]
}

extension SQLiteLedgerStore: CaptureInterpretationStore {}

public enum CaptureInterpretationServiceError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case captureNotFound(UUIDv7)
    case invalidCaptureProjection(String)
    case invalidClock
    case foreignSourceReference(String)
}

extension CaptureInterpretationServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case .captureNotFound:
            "The original capture is no longer available for interpretation."
        case let .invalidCaptureProjection(message):
            message
        case .invalidClock:
            "The interpretation clock is invalid."
        case .foreignSourceReference:
            "An interpreted field does not point to this capture's immutable source."
        }
    }
}

public struct CaptureInterpretationCommitReceipt: Hashable, Sendable {
    public let capture: CaptureRecord
    public let interpretation: CaptureInterpretationVersion
    public let ledgerLocalSequence: Int64
    public let operationID: UUIDv7
    public let deviceSequence: Int64?

    public init(
        capture: CaptureRecord,
        interpretation: CaptureInterpretationVersion,
        ledgerLocalSequence: Int64,
        operationID: UUIDv7,
        deviceSequence: Int64?
    ) {
        self.capture = capture
        self.interpretation = interpretation
        self.ledgerLocalSequence = ledgerLocalSequence
        self.operationID = operationID
        self.deviceSequence = deviceSequence
    }
}

public enum CaptureInterpretationExecution: Hashable, Sendable {
    case recorded(CaptureInterpretationCommitReceipt)
    case alreadyRecorded(CaptureInterpretationVersion)
    case deferred(CaptureInterpretationDeferralReason)
}

private struct CaptureInterpretationLedgerPayload: Codable {
    let captureID: UUIDv7
    let interpretationVersionID: UUIDv7
    let interpreter: String
    let interpreterVersion: String
    let status: CaptureInterpretationStatus
}

private struct CaptureInterpretationExecutionKey: Hashable {
    let captureID: UUIDv7
    let interpreter: String
    let interpreterVersion: String
}

private struct InFlightCaptureInterpretation {
    let id: Int
    let task: Task<CaptureInterpretationExecution, Error>
}

public actor CaptureInterpretationService {
    public static let eventType = "capture.interpreted.v1"

    private let store: any CaptureInterpretationStore
    private let clock: @Sendable () -> Date
    private let identifier: @Sendable () -> UUIDv7
    private let provenanceIdentifier: @Sendable () -> UUID
    private var inFlight: [CaptureInterpretationExecutionKey: InFlightCaptureInterpretation] = [:]
    private var nextExecutionID = 0

    public init(
        store: any CaptureInterpretationStore,
        clock: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> UUIDv7 = UUIDv7.init,
        provenanceIdentifier: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.store = store
        self.clock = clock
        self.identifier = identifier
        self.provenanceIdentifier = provenanceIdentifier
    }

    public func interpret(
        captureID: UUIDv7,
        using interpreter: any CaptureInterpreting
    ) async throws -> CaptureInterpretationExecution {
        let key = CaptureInterpretationExecutionKey(
            captureID: captureID,
            interpreter: interpreter.interpreterID,
            interpreterVersion: interpreter.interpreterVersion
        )
        if let execution = inFlight[key] {
            return try await execution.task.value
        }
        nextExecutionID += 1
        let execution = InFlightCaptureInterpretation(
            id: nextExecutionID,
            task: Task {
                try await self.performInterpretation(
                    captureID: captureID,
                    using: interpreter
                )
            }
        )
        inFlight[key] = execution
        do {
            let result = try await execution.task.value
            if inFlight[key]?.id == execution.id {
                inFlight[key] = nil
            }
            return result
        } catch {
            if inFlight[key]?.id == execution.id {
                inFlight[key] = nil
            }
            throw error
        }
    }

    private func performInterpretation(
        captureID: UUIDv7,
        using interpreter: any CaptureInterpreting
    ) async throws -> CaptureInterpretationExecution {
        let initial = try capture(id: captureID)
        if let existing = existingVersion(in: initial, using: interpreter) {
            return .alreadyRecorded(existing)
        }
        let attempt = try await interpreter.interpret(
            CaptureInterpretationInput(capture: initial)
        )
        guard case let .proposed(proposal) = attempt else {
            guard case let .deferred(reason) = attempt else {
                preconditionFailure("Capture interpretation attempts are exhaustive.")
            }
            return .deferred(reason)
        }

        let current = try capture(id: captureID)
        if let existing = existingVersion(in: current, using: interpreter) {
            return .alreadyRecorded(existing)
        }
        let createdAt = clock()
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt >= current.capturedAt
        else {
            throw CaptureInterpretationServiceError.invalidClock
        }
        let version = try CaptureInterpretationVersion(
            id: identifier(),
            interpreter: interpreter.interpreterID,
            interpreterVersion: interpreter.interpreterVersion,
            createdAt: createdAt,
            status: proposal.status,
            proposedFields: proposal.proposedFields
        )
        try validateSourceReferences(version.sourceSpanRefs, capture: current)
        let revisedMetadata = try EntityMetadata(
            id: current.metadata.id,
            schemaVersion: current.metadata.schemaVersion,
            createdAt: current.metadata.createdAt,
            createdBy: current.metadata.createdBy,
            lastRevisedAt: createdAt,
            revision: current.metadata.revision + 1,
            tombstonedAt: current.metadata.tombstonedAt,
            sensitivity: current.metadata.sensitivity,
            provenanceID: current.metadata.provenanceID
        )
        let updated = CaptureRecord(
            metadata: revisedMetadata,
            capturedAt: current.capturedAt,
            originalPayload: current.originalPayload,
            initialContext: current.initialContext,
            attachments: current.attachments,
            interpretationStatus: version.status,
            interpretationVersions: current.interpretationVersions + [version]
        )
        let document = try SyncJSONCoding.makeEncoder().encode(updated)
        guard document.count <= SQLiteLedgerStore.maximumSyncPayloadBytes else {
            throw CaptureContractError.payloadTooLarge(
                maximumBytes: SQLiteLedgerStore.maximumSyncPayloadBytes
            )
        }
        let eventPayload = try SyncJSONCoding.makeEncoder().encode(
            CaptureInterpretationLedgerPayload(
                captureID: captureID,
                interpretationVersionID: version.id,
                interpreter: version.interpreter,
                interpreterVersion: version.interpreterVersion,
                status: version.status
            )
        )
        let eventID = identifier()
        let operationID = identifier()
        let commit = try await store.commit(
            LedgerCommit(
                entry: LedgerEntry(
                    eventID: eventID,
                    eventType: Self.eventType,
                    aggregateType: ManualCaptureService.entityType,
                    aggregateID: captureID,
                    occurredAt: createdAt,
                    recordedAt: createdAt,
                    payload: eventPayload,
                    provenanceID: provenanceIdentifier()
                ),
                projection: ProjectionMutation(
                    entityType: ManualCaptureService.entityType,
                    entityID: captureID,
                    revision: revisedMetadata.revision,
                    mutationType: .update,
                    document: document
                ),
                syncMutation: SyncMutationDraft(
                    operationID: operationID,
                    entityType: ManualCaptureService.entityType,
                    entityID: captureID,
                    mutationType: .update,
                    baseRevision: current.metadata.revision,
                    payload: document,
                    createdAt: createdAt,
                    idempotencyKey: operationID.description,
                    sensitivityClass: current.metadata.sensitivity
                )
            )
        )
        return .recorded(CaptureInterpretationCommitReceipt(
            capture: updated,
            interpretation: version,
            ledgerLocalSequence: commit.localSequence,
            operationID: operationID,
            deviceSequence: commit.queuedOperation?.deviceSequence
        ))
    }

    public func pendingCaptureIDs(limit: Int = 100) throws -> [UUIDv7] {
        guard (1 ... 500).contains(limit) else {
            throw CaptureInterpretationServiceError.invalidConfiguration(
                "Pending interpretation pages require 1 through 500 captures."
            )
        }
        let projections = try store.projectedEntities(
            entityType: ManualCaptureService.entityType,
            limit: 500
        )
        let captures = try projections.map(decode)
        let pending = captures.filter {
            $0.interpretationStatus == .pending || $0.interpretationStatus == .processing
        }.sorted { $0.capturedAt < $1.capturedAt }
        return Array(pending.prefix(limit).map(\.metadata.id))
    }

    private func capture(id: UUIDv7) throws -> CaptureRecord {
        guard let projection = try store.projectedEntity(
            entityType: ManualCaptureService.entityType,
            entityID: id
        ) else {
            throw CaptureInterpretationServiceError.captureNotFound(id)
        }
        return try decode(projection)
    }

    private func decode(_ projection: ProjectedEntity) throws -> CaptureRecord {
        guard projection.entityType == ManualCaptureService.entityType else {
            throw CaptureInterpretationServiceError.invalidCaptureProjection(
                "The interpretation source has the wrong entity type."
            )
        }
        let capture: CaptureRecord
        do {
            capture = try SyncJSONCoding.makeDecoder().decode(
                CaptureRecord.self,
                from: projection.document
            )
        } catch {
            throw CaptureInterpretationServiceError.invalidCaptureProjection(
                "The interpretation source cannot be decoded safely."
            )
        }
        guard capture.metadata.id == projection.entityID,
              capture.metadata.revision == projection.revision,
              capture.metadata.tombstonedAt == nil
        else {
            throw CaptureInterpretationServiceError.invalidCaptureProjection(
                "The interpretation source identity or revision is inconsistent."
            )
        }
        return capture
    }

    private func existingVersion(
        in capture: CaptureRecord,
        using interpreter: any CaptureInterpreting
    ) -> CaptureInterpretationVersion? {
        capture.interpretationVersions.last {
            $0.interpreter == interpreter.interpreterID
                && $0.interpreterVersion == interpreter.interpreterVersion
        }
    }

    private func validateSourceReferences(
        _ sourceReferences: [String],
        capture: CaptureRecord
    ) throws {
        let original = "capture:\(capture.metadata.id)#original_payload"
        let attachments = capture.attachments.map {
            "capture:\(capture.metadata.id)#attachment:\($0.attachmentID)"
        }
        for sourceReference in sourceReferences {
            let refersToOriginal = sourceReference == original
                || sourceReference.hasPrefix(original + ":")
            let refersToAttachment = attachments.contains {
                sourceReference == $0 || sourceReference.hasPrefix($0 + ":")
            }
            guard refersToOriginal || refersToAttachment else {
                throw CaptureInterpretationServiceError.foreignSourceReference(
                    sourceReference
                )
            }
        }
    }
}
