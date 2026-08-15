import Foundation
import OdysseyData
import OdysseyDomain

public enum SyncContractError: Error, Equatable, Sendable {
    case invalidCursor(String)
    case invalidOperation(String)
    case invalidBatch(String)
    case invalidDiagnostics(String)
    case invalidConflictResolution(String)
    case payloadIsNotJSONObject
}

public enum SyncSchema {
    public static let currentVersion = 1
}

public struct SyncCursor: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: Int64

    public init(value: Int64) throws {
        guard value >= 0 else {
            throw SyncContractError.invalidCursor("A sync cursor cannot be negative.")
        }
        self.value = value
    }

    public init(_ rawValue: String) throws {
        guard rawValue.hasPrefix("c_"), rawValue.count > 2 else {
            throw SyncContractError.invalidCursor(rawValue)
        }
        let suffix = rawValue.dropFirst(2)
        guard suffix.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              suffix == "0" || suffix.first != "0",
              let value = Int64(suffix)
        else {
            throw SyncContractError.invalidCursor(rawValue)
        }
        self.value = value
    }

    public var description: String {
        "c_\(value)"
    }

    public static func < (lhs: SyncCursor, rhs: SyncCursor) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public typealias MutationType = LedgerMutationType

public struct SyncOperation: Codable, Hashable, Sendable {
    public let operationID: UUIDv7
    public let deviceSequence: Int64
    public let entityType: String
    public let entityID: UUIDv7
    public let mutationType: MutationType
    public let baseRevision: Int?
    public let payload: [String: JSONValue]
    public let createdAt: Date
    public let idempotencyKey: String?
    public let sensitivityClass: DataClass

    public init(
        operationID: UUIDv7,
        deviceSequence: Int64,
        entityType: String,
        entityID: UUIDv7,
        mutationType: MutationType,
        baseRevision: Int? = nil,
        payload: [String: JSONValue] = [:],
        createdAt: Date,
        idempotencyKey: String? = nil,
        sensitivityClass: DataClass = .private
    ) throws {
        guard deviceSequence >= 1 else {
            throw SyncContractError.invalidOperation("Device sequence must be positive.")
        }
        let trimmedEntityType = entityType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 100).contains(trimmedEntityType.count) else {
            throw SyncContractError.invalidOperation("Entity type must contain 1 through 100 characters.")
        }
        if let baseRevision, baseRevision < 1 {
            throw SyncContractError.invalidOperation("Base revision must be positive when present.")
        }
        if mutationType == .create, baseRevision != nil {
            throw SyncContractError.invalidOperation("Create operations cannot declare a base revision.")
        }
        if mutationType != .create, baseRevision == nil {
            throw SyncContractError.invalidOperation("Update and delete operations require a base revision.")
        }
        if mutationType == .delete, !payload.isEmpty {
            throw SyncContractError.invalidOperation("Delete operations require an empty payload.")
        }
        if let idempotencyKey, !(1 ... 500).contains(idempotencyKey.count) {
            throw SyncContractError.invalidOperation("Idempotency keys must contain 1 through 500 characters.")
        }
        let payloadData = try SyncJSONCoding.makeEncoder().encode(payload)
        guard payloadData.count <= SQLiteLedgerStore.maximumSyncPayloadBytes else {
            throw SyncContractError.invalidOperation("Operation payload exceeds 256 KiB.")
        }
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.entityType = trimmedEntityType
        self.entityID = entityID
        self.mutationType = mutationType
        self.baseRevision = baseRevision
        self.payload = payload
        self.createdAt = createdAt
        self.idempotencyKey = idempotencyKey
        self.sensitivityClass = sensitivityClass
    }

    public init(pending operation: PendingSyncOperation) throws {
        let payload: [String: JSONValue]
        do {
            payload = try SyncJSONCoding.makeDecoder().decode(
                [String: JSONValue].self,
                from: operation.payload
            )
        } catch {
            throw SyncContractError.payloadIsNotJSONObject
        }
        try self.init(
            operationID: operation.operationID,
            deviceSequence: operation.deviceSequence,
            entityType: operation.entityType,
            entityID: operation.entityID,
            mutationType: operation.mutationType,
            baseRevision: operation.baseRevision,
            payload: payload,
            createdAt: operation.createdAt,
            idempotencyKey: operation.idempotencyKey,
            sensitivityClass: operation.sensitivityClass
        )
    }
}

public struct SyncPushRequest: Codable, Hashable, Sendable {
    public let deviceID: UUIDv7
    public let clientSchemaVersion: Int
    public let baseCursor: SyncCursor
    public let operations: [SyncOperation]

    public init(
        deviceID: UUIDv7,
        clientSchemaVersion: Int = SyncSchema.currentVersion,
        baseCursor: SyncCursor,
        operations: [SyncOperation]
    ) throws {
        guard clientSchemaVersion >= 1 else {
            throw SyncContractError.invalidBatch("Client schema version must be positive.")
        }
        guard (1 ... 500).contains(operations.count) else {
            throw SyncContractError.invalidBatch("Push batches require 1 through 500 operations.")
        }
        let sequences = operations.map(\.deviceSequence)
        guard sequences == sequences.sorted(), Set(sequences).count == sequences.count else {
            throw SyncContractError.invalidBatch(
                "Push operations must have unique ascending device sequences."
            )
        }
        self.deviceID = deviceID
        self.clientSchemaVersion = clientSchemaVersion
        self.baseCursor = baseCursor
        self.operations = operations
    }
}

public struct AcceptedOperation: Codable, Hashable, Sendable {
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

public struct RejectedOperation: Codable, Hashable, Sendable {
    public let operationID: UUIDv7
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(operationID: UUIDv7, code: String, message: String, retryable: Bool) {
        self.operationID = operationID
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct SyncConflictSummary: Codable, Hashable, Sendable {
    public let conflictID: UUIDv7
    public let operationID: UUIDv7
    public let entityType: String
    public let entityID: UUIDv7
    public let code: String
    public let currentRevision: Int?
    public let conflictingFields: [String]

    public init(
        conflictID: UUIDv7,
        operationID: UUIDv7,
        entityType: String,
        entityID: UUIDv7,
        code: String,
        currentRevision: Int?,
        conflictingFields: [String] = []
    ) {
        self.conflictID = conflictID
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.code = code
        self.currentRevision = currentRevision
        self.conflictingFields = conflictingFields
    }
}

public struct SyncPushResponse: Codable, Hashable, Sendable {
    public let accepted: [AcceptedOperation]
    public let rejected: [RejectedOperation]
    public let conflicts: [SyncConflictSummary]
    public let nextCursor: SyncCursor
    public let serverTime: Date
    public let serverSchemaVersion: Int
    public let minimumClientSchemaVersion: Int

    public init(
        accepted: [AcceptedOperation] = [],
        rejected: [RejectedOperation] = [],
        conflicts: [SyncConflictSummary] = [],
        nextCursor: SyncCursor,
        serverTime: Date,
        serverSchemaVersion: Int,
        minimumClientSchemaVersion: Int
    ) {
        self.accepted = accepted
        self.rejected = rejected
        self.conflicts = conflicts
        self.nextCursor = nextCursor
        self.serverTime = serverTime
        self.serverSchemaVersion = serverSchemaVersion
        self.minimumClientSchemaVersion = minimumClientSchemaVersion
    }
}

public struct SyncChange: Codable, Hashable, Sendable {
    public let changeID: Int64
    public let canonicalRevision: Int
    public let entityType: String
    public let entityID: UUIDv7
    public let mutationType: MutationType
    public let payload: [String: JSONValue]
    public let tombstone: Bool
    public let deletionEpoch: Int?
    public let mergeResult: String
    public let originDeviceID: UUIDv7
    public let originOperationID: UUIDv7
    public let serverReceivedAt: Date

    public init(
        changeID: Int64,
        canonicalRevision: Int,
        entityType: String,
        entityID: UUIDv7,
        mutationType: MutationType,
        payload: [String: JSONValue],
        tombstone: Bool,
        deletionEpoch: Int?,
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

public struct SyncPullResponse: Codable, Hashable, Sendable {
    public let changes: [SyncChange]
    public let nextCursor: SyncCursor
    public let hasMore: Bool
    public let serverTime: Date
    public let serverSchemaVersion: Int
    public let minimumClientSchemaVersion: Int

    public init(
        changes: [SyncChange],
        nextCursor: SyncCursor,
        hasMore: Bool,
        serverTime: Date,
        serverSchemaVersion: Int,
        minimumClientSchemaVersion: Int
    ) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.serverTime = serverTime
        self.serverSchemaVersion = serverSchemaVersion
        self.minimumClientSchemaVersion = minimumClientSchemaVersion
    }
}

public enum SchemaCompatibility: String, Codable, Hashable, Sendable {
    case compatible
    case clientUpgradeRequired = "client_upgrade_required"
    case serverUpgradeRequired = "server_upgrade_required"
}

public struct SyncDeviceDiagnosticsInput: Codable, Hashable, Sendable {
    public let clientSchemaVersion: Int
    public let deviceCursor: SyncCursor
    public let operationsQueued: Int
    public let oldestUnsyncedOperationAt: Date?
    public let attachmentBacklog: Int

    public init(
        clientSchemaVersion: Int = SyncSchema.currentVersion,
        deviceCursor: SyncCursor,
        operationsQueued: Int,
        oldestUnsyncedOperationAt: Date?,
        attachmentBacklog: Int
    ) throws {
        guard clientSchemaVersion >= 1, operationsQueued >= 0, attachmentBacklog >= 0 else {
            throw SyncContractError.invalidDiagnostics("Diagnostics counts cannot be negative.")
        }
        guard (operationsQueued == 0) == (oldestUnsyncedOperationAt == nil) else {
            throw SyncContractError.invalidDiagnostics(
                "Oldest unsynced time must be present exactly when the queue is nonempty."
            )
        }
        self.clientSchemaVersion = clientSchemaVersion
        self.deviceCursor = deviceCursor
        self.operationsQueued = operationsQueued
        self.oldestUnsyncedOperationAt = oldestUnsyncedOperationAt
        self.attachmentBacklog = attachmentBacklog
    }
}

public struct SyncDeviceDiagnostics: Codable, Hashable, Sendable {
    public let deviceID: UUIDv7
    public let clientSchemaVersion: Int
    public let schemaCompatibility: SchemaCompatibility
    public let lastSuccessfulPushAt: Date?
    public let lastSuccessfulPullAt: Date?
    public let operationsQueued: Int
    public let oldestUnsyncedOperationAt: Date?
    public let attachmentBacklog: Int
    public let lastDeviceSequence: Int64
    public let deviceCursor: SyncCursor
    public let serverCursor: SyncCursor
    public let clockSkewSeconds: Int?
    public let diagnosticsReportedAt: Date?
    public let diagnosticsStale: Bool

    public init(
        deviceID: UUIDv7,
        clientSchemaVersion: Int,
        schemaCompatibility: SchemaCompatibility,
        lastSuccessfulPushAt: Date?,
        lastSuccessfulPullAt: Date?,
        operationsQueued: Int,
        oldestUnsyncedOperationAt: Date?,
        attachmentBacklog: Int,
        lastDeviceSequence: Int64,
        deviceCursor: SyncCursor,
        serverCursor: SyncCursor,
        clockSkewSeconds: Int?,
        diagnosticsReportedAt: Date?,
        diagnosticsStale: Bool
    ) {
        self.deviceID = deviceID
        self.clientSchemaVersion = clientSchemaVersion
        self.schemaCompatibility = schemaCompatibility
        self.lastSuccessfulPushAt = lastSuccessfulPushAt
        self.lastSuccessfulPullAt = lastSuccessfulPullAt
        self.operationsQueued = operationsQueued
        self.oldestUnsyncedOperationAt = oldestUnsyncedOperationAt
        self.attachmentBacklog = attachmentBacklog
        self.lastDeviceSequence = lastDeviceSequence
        self.deviceCursor = deviceCursor
        self.serverCursor = serverCursor
        self.clockSkewSeconds = clockSkewSeconds
        self.diagnosticsReportedAt = diagnosticsReportedAt
        self.diagnosticsStale = diagnosticsStale
    }
}

public struct SyncRepairOptions: Codable, Hashable, Sendable {
    public let projectionRebuildAvailable: Bool
    public let projectionRebuildCommand: String
    public let integrityCheckCommand: String

    public init(
        projectionRebuildAvailable: Bool,
        projectionRebuildCommand: String,
        integrityCheckCommand: String
    ) {
        self.projectionRebuildAvailable = projectionRebuildAvailable
        self.projectionRebuildCommand = projectionRebuildCommand
        self.integrityCheckCommand = integrityCheckCommand
    }
}

public struct SyncDiagnosticsResponse: Codable, Hashable, Sendable {
    public let serverTime: Date
    public let serverCursor: SyncCursor
    public let serverSchemaVersion: Int
    public let minimumClientSchemaVersion: Int
    public let pendingConflicts: Int
    public let pendingAttachmentUploads: Int
    public let pendingOutboxJobs: Int
    public let syncPushEnabled: Bool
    public let syncPullEnabled: Bool
    public let devices: [SyncDeviceDiagnostics]
    public let repair: SyncRepairOptions

    public init(
        serverTime: Date,
        serverCursor: SyncCursor,
        serverSchemaVersion: Int,
        minimumClientSchemaVersion: Int,
        pendingConflicts: Int,
        pendingAttachmentUploads: Int,
        pendingOutboxJobs: Int,
        syncPushEnabled: Bool,
        syncPullEnabled: Bool,
        devices: [SyncDeviceDiagnostics],
        repair: SyncRepairOptions
    ) {
        self.serverTime = serverTime
        self.serverCursor = serverCursor
        self.serverSchemaVersion = serverSchemaVersion
        self.minimumClientSchemaVersion = minimumClientSchemaVersion
        self.pendingConflicts = pendingConflicts
        self.pendingAttachmentUploads = pendingAttachmentUploads
        self.pendingOutboxJobs = pendingOutboxJobs
        self.syncPushEnabled = syncPushEnabled
        self.syncPullEnabled = syncPullEnabled
        self.devices = devices
        self.repair = repair
    }
}

public enum ConflictResolutionStrategy: String, Codable, Hashable, Sendable {
    case keepCurrent = "keep_current"
    case acceptIncoming = "accept_incoming"
    case merge
}

public enum SyncConflictStatusFilter: String, Codable, Hashable, Sendable {
    case pending
    case resolved
    case all
}

public struct SyncConflictDetail: Codable, Hashable, Sendable {
    public let conflictID: UUIDv7
    public let operationID: UUIDv7
    public let originatingDeviceID: UUIDv7
    public let entityType: String
    public let entityID: UUIDv7
    public let code: String
    public let baseRevision: Int?
    public let currentRevision: Int?
    public let currentDocument: [String: JSONValue]
    public let incomingDocument: [String: JSONValue]
    public let conflictingFields: [String]
    public let status: String
    public let createdAt: Date
    public let resolvedAt: Date?
    public let explanation: String
    public let allowedStrategies: [ConflictResolutionStrategy]

    public init(
        conflictID: UUIDv7,
        operationID: UUIDv7,
        originatingDeviceID: UUIDv7,
        entityType: String,
        entityID: UUIDv7,
        code: String,
        baseRevision: Int?,
        currentRevision: Int?,
        currentDocument: [String: JSONValue],
        incomingDocument: [String: JSONValue],
        conflictingFields: [String],
        status: String,
        createdAt: Date,
        resolvedAt: Date?,
        explanation: String,
        allowedStrategies: [ConflictResolutionStrategy]
    ) {
        self.conflictID = conflictID
        self.operationID = operationID
        self.originatingDeviceID = originatingDeviceID
        self.entityType = entityType
        self.entityID = entityID
        self.code = code
        self.baseRevision = baseRevision
        self.currentRevision = currentRevision
        self.currentDocument = currentDocument
        self.incomingDocument = incomingDocument
        self.conflictingFields = conflictingFields
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.explanation = explanation
        self.allowedStrategies = allowedStrategies
    }
}

public struct SyncConflictListResponse: Codable, Hashable, Sendable {
    public let conflicts: [SyncConflictDetail]
    public let pendingCount: Int
    public let serverTime: Date

    public init(conflicts: [SyncConflictDetail], pendingCount: Int, serverTime: Date) {
        self.conflicts = conflicts
        self.pendingCount = pendingCount
        self.serverTime = serverTime
    }
}

public struct SyncConflictResolutionRequest: Codable, Hashable, Sendable {
    public let operationID: UUIDv7
    public let deviceID: UUIDv7
    public let deviceSequence: Int64
    public let clientSchemaVersion: Int
    public let expectedCurrentRevision: Int
    public let strategy: ConflictResolutionStrategy
    public let mergedDocument: [String: JSONValue]?
    public let createdAt: Date
    public let idempotencyKey: String?
    public let sensitivityClass: DataClass

    public init(
        operationID: UUIDv7,
        deviceID: UUIDv7,
        deviceSequence: Int64,
        clientSchemaVersion: Int = SyncSchema.currentVersion,
        expectedCurrentRevision: Int,
        strategy: ConflictResolutionStrategy,
        mergedDocument: [String: JSONValue]? = nil,
        createdAt: Date,
        idempotencyKey: String? = nil,
        sensitivityClass: DataClass = .private
    ) throws {
        guard deviceSequence >= 1, clientSchemaVersion >= 1, expectedCurrentRevision >= 1 else {
            throw SyncContractError.invalidConflictResolution(
                "Conflict sequence and revisions must be positive."
            )
        }
        guard (strategy == .merge) == (mergedDocument != nil) else {
            throw SyncContractError.invalidConflictResolution(
                "Only merge resolution requires a merged document."
            )
        }
        self.operationID = operationID
        self.deviceID = deviceID
        self.deviceSequence = deviceSequence
        self.clientSchemaVersion = clientSchemaVersion
        self.expectedCurrentRevision = expectedCurrentRevision
        self.strategy = strategy
        self.mergedDocument = mergedDocument
        self.createdAt = createdAt
        self.idempotencyKey = idempotencyKey
        self.sensitivityClass = sensitivityClass
    }
}

public struct SyncConflictResolutionResponse: Codable, Hashable, Sendable {
    public let resolutionID: UUIDv7
    public let conflictID: UUIDv7
    public let status: String
    public let strategy: ConflictResolutionStrategy
    public let acceptedOperation: AcceptedOperation
    public let nextCursor: SyncCursor
    public let serverTime: Date
    public let serverSchemaVersion: Int

    public init(
        resolutionID: UUIDv7,
        conflictID: UUIDv7,
        status: String,
        strategy: ConflictResolutionStrategy,
        acceptedOperation: AcceptedOperation,
        nextCursor: SyncCursor,
        serverTime: Date,
        serverSchemaVersion: Int
    ) {
        self.resolutionID = resolutionID
        self.conflictID = conflictID
        self.status = status
        self.strategy = strategy
        self.acceptedOperation = acceptedOperation
        self.nextCursor = nextCursor
        self.serverTime = serverTime
        self.serverSchemaVersion = serverSchemaVersion
    }
}

public protocol BearerTokenProvider: Sendable {
    func validAccessToken() async throws -> String
}

public protocol SyncTransport: Sendable {
    func push(
        _ request: SyncPushRequest,
        batchIdempotencyKey: String
    ) async throws -> SyncPushResponse

    func pull(
        after cursor: SyncCursor,
        limit: Int,
        deviceID: UUIDv7
    ) async throws -> SyncPullResponse

    func reportDiagnostics(
        deviceID: UUIDv7,
        diagnostics: SyncDeviceDiagnosticsInput
    ) async throws -> SyncDeviceDiagnostics

    func diagnostics() async throws -> SyncDiagnosticsResponse

    func conflicts(
        status: SyncConflictStatusFilter,
        limit: Int
    ) async throws -> SyncConflictListResponse

    func resolveConflict(
        conflictID: UUIDv7,
        request: SyncConflictResolutionRequest
    ) async throws -> SyncConflictResolutionResponse
}

public struct SyncRunReport: Codable, Hashable, Sendable {
    public let pushedOperationCount: Int
    public let pulledChangeCount: Int
    public let conflictCount: Int
    public let finalCursor: SyncCursor
    public let completedAt: Date

    public init(
        pushedOperationCount: Int,
        pulledChangeCount: Int,
        conflictCount: Int,
        finalCursor: SyncCursor,
        completedAt: Date
    ) {
        self.pushedOperationCount = pushedOperationCount
        self.pulledChangeCount = pulledChangeCount
        self.conflictCount = conflictCount
        self.finalCursor = finalCursor
        self.completedAt = completedAt
    }
}

public protocol SyncCoordinator: Sendable {
    func synchronize() async throws -> SyncRunReport
    func diagnostics() async throws -> SyncDiagnosticsResponse
}
