import Foundation
import OdysseyDomain

public struct LedgerMigrationExport: Codable, Hashable, Sendable {
    public let version: Int
    public let name: String
    public let appliedAt: Date

    public init(version: Int, name: String, appliedAt: Date) {
        self.version = version
        self.name = name
        self.appliedAt = appliedAt
    }
}

public struct ProjectionEventExport: Codable, Hashable, Sendable {
    public let localSequence: Int64
    public let ledgerLocalSequence: Int64
    public let sourceEventID: UUIDv7
    public let mutation: ProjectionMutation
    public let documentSHA256: String
    public let recordedAt: Date
    public let sourceKind: ProjectionSourceKind
    public let serverChangeID: Int64?
    public let originOperationID: UUIDv7?

    public init(
        localSequence: Int64,
        ledgerLocalSequence: Int64,
        sourceEventID: UUIDv7,
        mutation: ProjectionMutation,
        documentSHA256: String,
        recordedAt: Date,
        sourceKind: ProjectionSourceKind = .local,
        serverChangeID: Int64? = nil,
        originOperationID: UUIDv7? = nil
    ) {
        self.localSequence = localSequence
        self.ledgerLocalSequence = ledgerLocalSequence
        self.sourceEventID = sourceEventID
        self.mutation = mutation
        self.documentSHA256 = documentSHA256
        self.recordedAt = recordedAt
        self.sourceKind = sourceKind
        self.serverChangeID = serverChangeID
        self.originOperationID = originOperationID
    }
}

public struct SyncOperationExport: Codable, Hashable, Sendable {
    public let operation: PendingSyncOperation
    public let canonicalRevision: Int?
    public let serverChangeID: Int64?
    public let completedAt: Date?
    public let resultCode: String?
    public let resultMessage: String?
    public let resultRetryable: Bool?
    public let mergeResult: String?
    public let conflictID: UUIDv7?

    public init(
        operation: PendingSyncOperation,
        canonicalRevision: Int?,
        serverChangeID: Int64?,
        completedAt: Date?,
        resultCode: String? = nil,
        resultMessage: String? = nil,
        resultRetryable: Bool? = nil,
        mergeResult: String? = nil,
        conflictID: UUIDv7? = nil
    ) {
        self.operation = operation
        self.canonicalRevision = canonicalRevision
        self.serverChangeID = serverChangeID
        self.completedAt = completedAt
        self.resultCode = resultCode
        self.resultMessage = resultMessage
        self.resultRetryable = resultRetryable
        self.mergeResult = mergeResult
        self.conflictID = conflictID
    }
}

public struct LedgerExportArchive: Codable, Hashable, Sendable {
    public let exportFormatVersion: Int
    public let schemaVersion: Int
    public let exportedAt: Date
    public let binaryEncoding: String
    public let migrations: [LedgerMigrationExport]
    public let syncState: LocalSyncState
    public let ledgerEntries: [StoredLedgerEntry]
    public let projectionEvents: [ProjectionEventExport]
    public let currentProjections: [ProjectedEntity]
    public let syncOperations: [SyncOperationExport]
    public let remoteChangeReceipts: [RemoteChangeReceipt]
    public let lifeModelAcceptances: [StoredLifeModelAcceptance]
    public let cachedLifeModelVersions: [CachedLifeModelVersion]

    public init(
        exportFormatVersion: Int,
        schemaVersion: Int,
        exportedAt: Date,
        binaryEncoding: String,
        migrations: [LedgerMigrationExport],
        syncState: LocalSyncState,
        ledgerEntries: [StoredLedgerEntry],
        projectionEvents: [ProjectionEventExport],
        currentProjections: [ProjectedEntity],
        syncOperations: [SyncOperationExport],
        remoteChangeReceipts: [RemoteChangeReceipt],
        lifeModelAcceptances: [StoredLifeModelAcceptance],
        cachedLifeModelVersions: [CachedLifeModelVersion]
    ) {
        self.exportFormatVersion = exportFormatVersion
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.binaryEncoding = binaryEncoding
        self.migrations = migrations
        self.syncState = syncState
        self.ledgerEntries = ledgerEntries
        self.projectionEvents = projectionEvents
        self.currentProjections = currentProjections
        self.syncOperations = syncOperations
        self.remoteChangeReceipts = remoteChangeReceipts
        self.lifeModelAcceptances = lifeModelAcceptances
        self.cachedLifeModelVersions = cachedLifeModelVersions
    }
}
