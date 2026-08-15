import Foundation
import OdysseyDomain

public enum ProjectionSourceKind: String, Codable, Hashable, Sendable {
    case local
    case remote
}

public enum RemoteChangeApplicationKind: String, Codable, Hashable, Sendable {
    case localReconciliation = "local_reconciliation"
    case remoteCommit = "remote_commit"
}

public struct SyncPushAcceptance: Codable, Hashable, Sendable {
    public let operationID: UUIDv7
    public let canonicalRevision: Int
    public let serverChangeID: Int64
    public let mergeResult: String

    public init(
        operationID: UUIDv7,
        canonicalRevision: Int,
        serverChangeID: Int64,
        mergeResult: String
    ) {
        self.operationID = operationID
        self.canonicalRevision = canonicalRevision
        self.serverChangeID = serverChangeID
        self.mergeResult = mergeResult
    }
}

public struct SyncPushRejection: Codable, Hashable, Sendable {
    public let operationID: UUIDv7
    public let code: String
    public let message: String
    public let retryable: Bool
    public let nextAttemptAt: Date?

    public init(
        operationID: UUIDv7,
        code: String,
        message: String,
        retryable: Bool,
        nextAttemptAt: Date? = nil
    ) {
        self.operationID = operationID
        self.code = code
        self.message = message
        self.retryable = retryable
        self.nextAttemptAt = nextAttemptAt
    }
}

public struct SyncPushConflict: Codable, Hashable, Sendable {
    public let conflictID: UUIDv7
    public let operationID: UUIDv7
    public let code: String
    public let message: String
    public let currentRevision: Int?

    public init(
        conflictID: UUIDv7,
        operationID: UUIDv7,
        code: String,
        message: String,
        currentRevision: Int?
    ) {
        self.conflictID = conflictID
        self.operationID = operationID
        self.code = code
        self.message = message
        self.currentRevision = currentRevision
    }
}

public struct SyncPushResultBatch: Codable, Hashable, Sendable {
    public let accepted: [SyncPushAcceptance]
    public let rejected: [SyncPushRejection]
    public let conflicts: [SyncPushConflict]
    public let nextServerCursor: String
    public let serverSchemaVersion: Int
    public let completedAt: Date

    public init(
        accepted: [SyncPushAcceptance] = [],
        rejected: [SyncPushRejection] = [],
        conflicts: [SyncPushConflict] = [],
        nextServerCursor: String,
        serverSchemaVersion: Int,
        completedAt: Date
    ) {
        self.accepted = accepted
        self.rejected = rejected
        self.conflicts = conflicts
        self.nextServerCursor = nextServerCursor
        self.serverSchemaVersion = serverSchemaVersion
        self.completedAt = completedAt
    }
}

public struct RemoteSyncChange: Codable, Hashable, Sendable {
    public let changeID: Int64
    public let canonicalRevision: Int
    public let entityType: String
    public let entityID: UUIDv7
    public let mutationType: LedgerMutationType
    public let payload: Data
    public let tombstone: Bool
    public let deletionEpoch: Int64?
    public let mergeResult: String
    public let originDeviceID: UUIDv7
    public let originOperationID: UUIDv7
    public let serverReceivedAt: Date

    public init(
        changeID: Int64,
        canonicalRevision: Int,
        entityType: String,
        entityID: UUIDv7,
        mutationType: LedgerMutationType,
        payload: Data,
        tombstone: Bool,
        deletionEpoch: Int64?,
        mergeResult: String,
        originDeviceID: UUIDv7,
        originOperationID: UUIDv7,
        serverReceivedAt: Date
    ) {
        self.changeID = changeID
        self.canonicalRevision = canonicalRevision
        self.entityType = entityType
        self.entityID = entityID
        self.mutationType = mutationType
        self.payload = payload
        self.tombstone = tombstone
        self.deletionEpoch = deletionEpoch
        self.mergeResult = mergeResult
        self.originDeviceID = originDeviceID
        self.originOperationID = originOperationID
        self.serverReceivedAt = serverReceivedAt
    }
}

public struct RemoteSyncPage: Codable, Hashable, Sendable {
    public let changes: [RemoteSyncChange]
    public let nextCursor: String
    public let hasMore: Bool
    public let serverSchemaVersion: Int
    public let completedAt: Date

    public init(
        changes: [RemoteSyncChange],
        nextCursor: String,
        hasMore: Bool,
        serverSchemaVersion: Int,
        completedAt: Date
    ) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.serverSchemaVersion = serverSchemaVersion
        self.completedAt = completedAt
    }
}

public struct RemoteChangeReceipt: Codable, Hashable, Sendable {
    public let change: RemoteSyncChange
    public let projectionEventSequence: Int64
    public let ledgerEventID: UUIDv7
    public let payloadSHA256: String
    public let appliedAt: Date
    public let applicationKind: RemoteChangeApplicationKind

    public init(
        change: RemoteSyncChange,
        projectionEventSequence: Int64,
        ledgerEventID: UUIDv7,
        payloadSHA256: String,
        appliedAt: Date,
        applicationKind: RemoteChangeApplicationKind
    ) {
        self.change = change
        self.projectionEventSequence = projectionEventSequence
        self.ledgerEventID = ledgerEventID
        self.payloadSHA256 = payloadSHA256
        self.appliedAt = appliedAt
        self.applicationKind = applicationKind
    }
}

public struct RemoteChangeApplicationReport: Codable, Hashable, Sendable {
    public let appliedCount: Int
    public let duplicateCount: Int
    public let localReconciliationCount: Int
    public let remoteCommitCount: Int
    public let finalCursor: String
    public let hasMore: Bool

    public init(
        appliedCount: Int,
        duplicateCount: Int,
        localReconciliationCount: Int,
        remoteCommitCount: Int,
        finalCursor: String,
        hasMore: Bool
    ) {
        self.appliedCount = appliedCount
        self.duplicateCount = duplicateCount
        self.localReconciliationCount = localReconciliationCount
        self.remoteCommitCount = remoteCommitCount
        self.finalCursor = finalCursor
        self.hasMore = hasMore
    }
}

public protocol SyncPersistenceStore: Sendable {
    func applyPushResult(_ batch: SyncPushResultBatch) async throws
    func applyPullPage(_ page: RemoteSyncPage) async throws -> RemoteChangeApplicationReport
    func remoteChangeReceipts(after changeID: Int64?, limit: Int) async throws -> [RemoteChangeReceipt]
}
