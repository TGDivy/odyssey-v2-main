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
    public let sourceEventID: UUIDv7
    public let mutation: ProjectionMutation
    public let documentSHA256: String
    public let recordedAt: Date

    public init(
        localSequence: Int64,
        sourceEventID: UUIDv7,
        mutation: ProjectionMutation,
        documentSHA256: String,
        recordedAt: Date
    ) {
        self.localSequence = localSequence
        self.sourceEventID = sourceEventID
        self.mutation = mutation
        self.documentSHA256 = documentSHA256
        self.recordedAt = recordedAt
    }
}

public struct SyncOperationExport: Codable, Hashable, Sendable {
    public let operation: PendingSyncOperation
    public let canonicalRevision: Int?
    public let serverChangeID: Int64?
    public let completedAt: Date?

    public init(
        operation: PendingSyncOperation,
        canonicalRevision: Int?,
        serverChangeID: Int64?,
        completedAt: Date?
    ) {
        self.operation = operation
        self.canonicalRevision = canonicalRevision
        self.serverChangeID = serverChangeID
        self.completedAt = completedAt
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
        syncOperations: [SyncOperationExport]
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
    }
}
