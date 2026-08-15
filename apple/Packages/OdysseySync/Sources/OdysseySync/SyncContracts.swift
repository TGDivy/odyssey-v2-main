import Foundation
import OdysseyData
import OdysseyDomain

public enum MutationType: String, Codable, Sendable {
    case create
    case update
    case tombstone
    case supersede
}

public struct SyncOperation: Codable, Hashable, Sendable {
    public let operationID: UUIDv7
    public let deviceSequence: Int64
    public let entityType: String
    public let entityID: UUIDv7
    public let mutationType: MutationType
    public let baseRevision: Int?
    public let payload: Data
    public let createdAt: Date

    public init(
        operationID: UUIDv7 = UUIDv7(),
        deviceSequence: Int64,
        entityType: String,
        entityID: UUIDv7,
        mutationType: MutationType,
        baseRevision: Int? = nil,
        payload: Data,
        createdAt: Date
    ) {
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.entityType = entityType
        self.entityID = entityID
        self.mutationType = mutationType
        self.baseRevision = baseRevision
        self.payload = payload
        self.createdAt = createdAt
    }
}

public protocol SyncTransport: Sendable {
    func push(_ operations: [SyncOperation], baseCursor: String?) async throws -> String
    func pull(after cursor: String?, limit: Int) async throws -> [LedgerEntry]
}

public protocol SyncCoordinator: Sendable {
    func synchronize() async throws
    func diagnostics() async -> SyncDiagnostics
}

public struct SyncDiagnostics: Codable, Hashable, Sendable {
    public let lastSuccessfulPush: Date?
    public let lastSuccessfulPull: Date?
    public let queuedOperationCount: Int
    public let conflictCount: Int
    public let attachmentBacklog: Int
    public let deviceCursor: String?
    public let serverCursor: String?
}

