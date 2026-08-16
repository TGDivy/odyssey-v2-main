import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public enum ManualCaptureError: Error, Equatable, Sendable {
    case invalidClock
}

public struct ManualCaptureReceipt: Codable, Hashable, Sendable {
    public let capture: CaptureRecord
    public let ledgerLocalSequence: Int64
    public let operationID: UUIDv7
    public let deviceSequence: Int64?

    public init(
        capture: CaptureRecord,
        ledgerLocalSequence: Int64,
        operationID: UUIDv7,
        deviceSequence: Int64?
    ) {
        self.capture = capture
        self.ledgerLocalSequence = ledgerLocalSequence
        self.operationID = operationID
        self.deviceSequence = deviceSequence
    }
}

public actor ManualCaptureService {
    public static let eventType = "capture.recorded.v1"
    public static let entityType = "capture"

    private let store: any LedgerStore
    private let deviceID: UUIDv7
    private let ownerActorID: String
    private let clock: @Sendable () -> Date
    private let identifier: @Sendable () -> UUIDv7
    private let provenanceIdentifier: @Sendable () -> UUID

    public init(
        store: any LedgerStore,
        deviceID: UUIDv7,
        ownerActorID: String = "owner",
        clock: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> UUIDv7 = UUIDv7.init,
        provenanceIdentifier: @escaping @Sendable () -> UUID = UUID.init
    ) throws {
        guard (1 ... 100).contains(ownerActorID.count),
              ownerActorID == ownerActorID.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw CaptureContractError.invalidContext("owner actor")
        }
        self.store = store
        self.deviceID = deviceID
        self.ownerActorID = ownerActorID
        self.clock = clock
        self.identifier = identifier
        self.provenanceIdentifier = provenanceIdentifier
    }

    @discardableResult
    public func record(_ draft: ManualCaptureDraft) async throws -> ManualCaptureReceipt {
        let recordedAt = clock()
        let capturedAt = draft.capturedAt ?? recordedAt
        guard recordedAt.timeIntervalSinceReferenceDate.isFinite,
              capturedAt.timeIntervalSinceReferenceDate.isFinite,
              capturedAt <= recordedAt
        else {
            throw ManualCaptureError.invalidClock
        }
        let captureID = draft.sourceCommandID ?? identifier()
        let provenanceID = provenanceIdentifier()
        let payload = CaptureOriginalPayload(
            kind: draft.kind,
            contentOrObjectRef: draft.contentOrObjectReference,
            contentHash: SHA256Digest.hexDigest(of: Data(draft.contentOrObjectReference.utf8))
        )
        let metadata = try EntityMetadata(
            id: captureID,
            createdAt: recordedAt,
            createdBy: ActorRef(actorType: .user, actorID: ownerActorID),
            lastRevisedAt: recordedAt,
            revision: 1,
            sensitivity: draft.sensitivity,
            provenanceID: provenanceID
        )
        let capture = CaptureRecord(
            metadata: metadata,
            capturedAt: capturedAt,
            originalPayload: payload,
            initialContext: CaptureInitialContext(
                deviceID: deviceID,
                timeZoneID: draft.timeZoneID,
                locationPermissionState: draft.locationPermissionState,
                broadLocation: draft.broadLocation,
                invokingSurface: draft.invokingSurface
            ),
            attachments: draft.attachments,
            interpretationStatus: .pending,
            interpretationVersions: []
        )
        let document = try SyncJSONCoding.makeEncoder().encode(capture)
        guard document.count <= SQLiteLedgerStore.maximumSyncPayloadBytes else {
            throw CaptureContractError.payloadTooLarge(
                maximumBytes: SQLiteLedgerStore.maximumSyncPayloadBytes
            )
        }
        let eventID = identifier()
        let operationID = draft.sourceCommandID ?? identifier()
        let commitReceipt = try await store.commit(
            LedgerCommit(
                entry: LedgerEntry(
                    eventID: eventID,
                    eventType: Self.eventType,
                    aggregateType: Self.entityType,
                    aggregateID: captureID,
                    occurredAt: capturedAt,
                    recordedAt: recordedAt,
                    payload: document,
                    provenanceID: provenanceID
                ),
                projection: ProjectionMutation(
                    entityType: Self.entityType,
                    entityID: captureID,
                    revision: 1,
                    mutationType: .create,
                    document: document
                ),
                syncMutation: SyncMutationDraft(
                    operationID: operationID,
                    entityType: Self.entityType,
                    entityID: captureID,
                    mutationType: .create,
                    payload: document,
                    createdAt: recordedAt,
                    idempotencyKey: operationID.description,
                    sensitivityClass: draft.sensitivity
                )
            )
        )
        return ManualCaptureReceipt(
            capture: capture,
            ledgerLocalSequence: commitReceipt.localSequence,
            operationID: operationID,
            deviceSequence: commitReceipt.queuedOperation?.deviceSequence
        )
    }
}
