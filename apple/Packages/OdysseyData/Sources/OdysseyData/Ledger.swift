import Foundation
import OdysseyDomain

public struct LedgerEntry: Codable, Hashable, Sendable {
    public let eventID: UUIDv7
    public let eventType: String
    public let aggregateType: String
    public let aggregateID: UUIDv7
    public let occurredAt: Date
    public let recordedAt: Date
    public let payload: Data
    public let provenanceID: UUID

    public init(
        eventID: UUIDv7 = UUIDv7(),
        eventType: String,
        aggregateType: String,
        aggregateID: UUIDv7,
        occurredAt: Date,
        recordedAt: Date,
        payload: Data,
        provenanceID: UUID
    ) {
        self.eventID = eventID
        self.eventType = eventType
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.payload = payload
        self.provenanceID = provenanceID
    }
}

public struct StoredLedgerEntry: Codable, Hashable, Sendable {
    public let localSequence: Int64
    public let entry: LedgerEntry
    public let payloadSHA256: String

    public init(localSequence: Int64, entry: LedgerEntry, payloadSHA256: String) {
        self.localSequence = localSequence
        self.entry = entry
        self.payloadSHA256 = payloadSHA256
    }
}

public enum LedgerMutationType: String, Codable, Hashable, Sendable {
    case create
    case update
    case delete
}

public struct ProjectionMutation: Codable, Hashable, Sendable {
    public let entityType: String
    public let entityID: UUIDv7
    public let revision: Int
    public let mutationType: LedgerMutationType
    public let document: Data

    public init(
        entityType: String,
        entityID: UUIDv7,
        revision: Int,
        mutationType: LedgerMutationType,
        document: Data
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.revision = revision
        self.mutationType = mutationType
        self.document = document
    }
}

public struct ProjectedEntity: Codable, Hashable, Sendable {
    public let entityType: String
    public let entityID: UUIDv7
    public let revision: Int
    public let document: Data
    public let tombstone: Bool
    public let sourceEventID: UUIDv7
    public let updatedAt: Date

    public init(
        entityType: String,
        entityID: UUIDv7,
        revision: Int,
        document: Data,
        tombstone: Bool,
        sourceEventID: UUIDv7,
        updatedAt: Date
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.revision = revision
        self.document = document
        self.tombstone = tombstone
        self.sourceEventID = sourceEventID
        self.updatedAt = updatedAt
    }
}

public struct ProjectionSearchResult: Codable, Hashable, Sendable {
    public let entity: ProjectedEntity
    public let snippet: String
    public let rank: Double

    public init(entity: ProjectedEntity, snippet: String, rank: Double) {
        self.entity = entity
        self.snippet = snippet
        self.rank = rank
    }
}

public struct SyncMutationDraft: Codable, Hashable, Sendable {
    public let operationID: UUIDv7
    public let entityType: String
    public let entityID: UUIDv7
    public let mutationType: LedgerMutationType
    public let baseRevision: Int?
    public let payload: Data
    public let createdAt: Date
    public let idempotencyKey: String
    public let sensitivityClass: DataClass

    public init(
        operationID: UUIDv7 = UUIDv7(),
        entityType: String,
        entityID: UUIDv7,
        mutationType: LedgerMutationType,
        baseRevision: Int? = nil,
        payload: Data,
        createdAt: Date,
        idempotencyKey: String? = nil,
        sensitivityClass: DataClass = .private
    ) {
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.mutationType = mutationType
        self.baseRevision = baseRevision
        self.payload = payload
        self.createdAt = createdAt
        self.idempotencyKey = idempotencyKey ?? operationID.description
        self.sensitivityClass = sensitivityClass
    }
}

public enum SyncOperationStatus: String, Codable, Hashable, Sendable {
    case pending
    case retry
    case accepted
    case rejected
    case conflict
}

public struct PendingSyncOperation: Codable, Hashable, Sendable {
    public let operationID: UUIDv7
    public let deviceSequence: Int64
    public let entityType: String
    public let entityID: UUIDv7
    public let mutationType: LedgerMutationType
    public let baseRevision: Int?
    public let payload: Data
    public let payloadSHA256: String
    public let createdAt: Date
    public let idempotencyKey: String
    public let sensitivityClass: DataClass
    public let sourceEventID: UUIDv7
    public let status: SyncOperationStatus
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let lastError: String?

    public init(
        operationID: UUIDv7,
        deviceSequence: Int64,
        entityType: String,
        entityID: UUIDv7,
        mutationType: LedgerMutationType,
        baseRevision: Int?,
        payload: Data,
        payloadSHA256: String,
        createdAt: Date,
        idempotencyKey: String,
        sensitivityClass: DataClass,
        sourceEventID: UUIDv7,
        status: SyncOperationStatus,
        attemptCount: Int,
        nextAttemptAt: Date?,
        lastError: String?
    ) {
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.entityType = entityType
        self.entityID = entityID
        self.mutationType = mutationType
        self.baseRevision = baseRevision
        self.payload = payload
        self.payloadSHA256 = payloadSHA256
        self.createdAt = createdAt
        self.idempotencyKey = idempotencyKey
        self.sensitivityClass = sensitivityClass
        self.sourceEventID = sourceEventID
        self.status = status
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
    }
}

public struct LedgerCommit: Codable, Hashable, Sendable {
    public let entry: LedgerEntry
    public let projection: ProjectionMutation?
    public let syncMutation: SyncMutationDraft?

    public init(
        entry: LedgerEntry,
        projection: ProjectionMutation? = nil,
        syncMutation: SyncMutationDraft? = nil
    ) {
        self.entry = entry
        self.projection = projection
        self.syncMutation = syncMutation
    }
}

public struct LedgerCommitReceipt: Codable, Hashable, Sendable {
    public let localSequence: Int64
    public let queuedOperation: PendingSyncOperation?

    public init(localSequence: Int64, queuedOperation: PendingSyncOperation?) {
        self.localSequence = localSequence
        self.queuedOperation = queuedOperation
    }
}

public struct LocalSyncState: Codable, Hashable, Sendable {
    public let deviceID: UUIDv7
    public let cursor: String
    public let serverCursor: String
    public let receiptFloor: Int64
    public let nextDeviceSequence: Int64
    public let lastSuccessfulPushAt: Date?
    public let lastSuccessfulPullAt: Date?
    public let serverSchemaVersion: Int?

    public init(
        deviceID: UUIDv7,
        cursor: String,
        serverCursor: String,
        receiptFloor: Int64,
        nextDeviceSequence: Int64,
        lastSuccessfulPushAt: Date?,
        lastSuccessfulPullAt: Date?,
        serverSchemaVersion: Int?
    ) {
        self.deviceID = deviceID
        self.cursor = cursor
        self.serverCursor = serverCursor
        self.receiptFloor = receiptFloor
        self.nextDeviceSequence = nextDeviceSequence
        self.lastSuccessfulPushAt = lastSuccessfulPushAt
        self.lastSuccessfulPullAt = lastSuccessfulPullAt
        self.serverSchemaVersion = serverSchemaVersion
    }
}

public struct LocalSyncDiagnostics: Codable, Hashable, Sendable {
    public let syncState: LocalSyncState
    public let operationsQueued: Int
    public let oldestUnsyncedOperationAt: Date?
    public let conflictCount: Int

    public init(
        syncState: LocalSyncState,
        operationsQueued: Int,
        oldestUnsyncedOperationAt: Date?,
        conflictCount: Int
    ) {
        self.syncState = syncState
        self.operationsQueued = operationsQueued
        self.oldestUnsyncedOperationAt = oldestUnsyncedOperationAt
        self.conflictCount = conflictCount
    }
}

public struct LedgerIntegrityReport: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let ledgerEntryCount: Int
    public let projectionEventCount: Int
    public let projectedEntityCount: Int
    public let syncOperationCount: Int
    public let remoteChangeReceiptCount: Int
    public let checkedAt: Date

    public init(
        schemaVersion: Int,
        ledgerEntryCount: Int,
        projectionEventCount: Int,
        projectedEntityCount: Int,
        syncOperationCount: Int,
        remoteChangeReceiptCount: Int,
        checkedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.ledgerEntryCount = ledgerEntryCount
        self.projectionEventCount = projectionEventCount
        self.projectedEntityCount = projectedEntityCount
        self.syncOperationCount = syncOperationCount
        self.remoteChangeReceiptCount = remoteChangeReceiptCount
        self.checkedAt = checkedAt
    }
}

public protocol LedgerStore: Sendable {
    func append(_ entry: LedgerEntry) async throws
    func commit(_ commit: LedgerCommit) async throws -> LedgerCommitReceipt
    func entries(after eventID: UUIDv7?, limit: Int) async throws -> [LedgerEntry]
}

public protocol SyncOutboxStore: Sendable {
    func pendingSyncOperations(limit: Int, readyAt: Date) async throws -> [PendingSyncOperation]
    func syncState() async throws -> LocalSyncState
    func localSyncDiagnostics() async throws -> LocalSyncDiagnostics
}

public protocol ProjectionRebuilder: Sendable {
    func rebuildAll() async throws
    func verifyIntegrity() async throws
}

public protocol OwnerExporter: Sendable {
    func exportAll(to destination: URL) async throws -> URL
}

public protocol LocalBackupProvider: Sendable {
    func createBackup(at destination: URL) async throws -> URL
}
