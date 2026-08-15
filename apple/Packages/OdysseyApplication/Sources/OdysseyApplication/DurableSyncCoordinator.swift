import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public enum DurableSyncCoordinatorError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidLocalState(String)
    case invalidPushResponse(String)
    case invalidPullResponse(String)
    case invalidSchemaMetadata(String)
    case clientUpgradeRequired(minimumVersion: Int, currentVersion: Int)
    case serverUpgradeRequired(serverVersion: Int, currentVersion: Int)
    case pullPageLimitExceeded(Int)
}

extension DurableSyncCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message),
             let .invalidLocalState(message),
             let .invalidPushResponse(message),
             let .invalidPullResponse(message),
             let .invalidSchemaMetadata(message):
            message
        case let .clientUpgradeRequired(minimumVersion, currentVersion):
            "Sync requires client schema \(minimumVersion); this app supports \(currentVersion)."
        case let .serverUpgradeRequired(serverVersion, currentVersion):
            "The server schema is \(serverVersion); this app requires \(currentVersion)."
        case let .pullPageLimitExceeded(limit):
            "Sync stopped after the safety limit of \(limit) pull pages and can resume later."
        }
    }
}

public struct DurableSyncCoordinatorConfiguration: Sendable {
    public let pushBatchSize: Int
    public let pullPageSize: Int
    public let maximumPullPages: Int
    public let retryBaseDelay: TimeInterval
    public let retryMaximumDelay: TimeInterval

    public init(
        pushBatchSize: Int = 100,
        pullPageSize: Int = 100,
        maximumPullPages: Int = 1_000,
        retryBaseDelay: TimeInterval = 30,
        retryMaximumDelay: TimeInterval = 60 * 60
    ) {
        self.pushBatchSize = pushBatchSize
        self.pullPageSize = pullPageSize
        self.maximumPullPages = maximumPullPages
        self.retryBaseDelay = retryBaseDelay
        self.retryMaximumDelay = retryMaximumDelay
    }
}

public enum NativeSchemaCompatibility: String, Codable, Hashable, Sendable {
    case unknown
    case compatible
    case clientUpgradeRequired = "client_upgrade_required"
    case serverUpgradeRequired = "server_upgrade_required"
}

public struct NativeSyncDiagnostics: Codable, Hashable, Sendable {
    public let deviceID: UUIDv7
    public let lastSuccessfulPushAt: Date?
    public let lastSuccessfulPullAt: Date?
    public let operationsQueued: Int
    public let oldestUnsyncedOperationAt: Date?
    public let conflictCount: Int
    public let attachmentBacklog: Int
    public let deviceCursor: SyncCursor
    public let serverCursor: SyncCursor
    public let serverSchemaVersion: Int?
    public let schemaCompatibility: NativeSchemaCompatibility

    public init(
        deviceID: UUIDv7,
        lastSuccessfulPushAt: Date?,
        lastSuccessfulPullAt: Date?,
        operationsQueued: Int,
        oldestUnsyncedOperationAt: Date?,
        conflictCount: Int,
        attachmentBacklog: Int,
        deviceCursor: SyncCursor,
        serverCursor: SyncCursor,
        serverSchemaVersion: Int?,
        schemaCompatibility: NativeSchemaCompatibility
    ) {
        self.deviceID = deviceID
        self.lastSuccessfulPushAt = lastSuccessfulPushAt
        self.lastSuccessfulPullAt = lastSuccessfulPullAt
        self.operationsQueued = operationsQueued
        self.oldestUnsyncedOperationAt = oldestUnsyncedOperationAt
        self.conflictCount = conflictCount
        self.attachmentBacklog = attachmentBacklog
        self.deviceCursor = deviceCursor
        self.serverCursor = serverCursor
        self.serverSchemaVersion = serverSchemaVersion
        self.schemaCompatibility = schemaCompatibility
    }
}

public actor DurableSyncCoordinator: SyncCoordinator {
    public typealias AttachmentBacklogProvider = @Sendable () async throws -> Int

    private let store: any SyncOutboxStore & SyncPersistenceStore
    private let transport: any SyncTransport
    private let configuration: DurableSyncCoordinatorConfiguration
    private let clock: @Sendable () -> Date
    private let attachmentBacklogProvider: AttachmentBacklogProvider
    private var activeSynchronization: Task<SyncRunReport, Error>?
    private var lastObservedServerSchemaVersion: Int?
    private var lastObservedMinimumClientSchemaVersion: Int?

    public init(
        store: any SyncOutboxStore & SyncPersistenceStore,
        transport: any SyncTransport,
        configuration: DurableSyncCoordinatorConfiguration = .init(),
        clock: @escaping @Sendable () -> Date = Date.init,
        attachmentBacklogProvider: @escaping AttachmentBacklogProvider = { 0 }
    ) throws {
        guard (1 ... 500).contains(configuration.pushBatchSize) else {
            throw DurableSyncCoordinatorError.invalidConfiguration(
                "Push batch size must be between 1 and 500."
            )
        }
        guard (1 ... 500).contains(configuration.pullPageSize) else {
            throw DurableSyncCoordinatorError.invalidConfiguration(
                "Pull page size must be between 1 and 500."
            )
        }
        guard configuration.maximumPullPages >= 1 else {
            throw DurableSyncCoordinatorError.invalidConfiguration(
                "At least one pull page must be allowed."
            )
        }
        guard configuration.retryBaseDelay.isFinite,
              configuration.retryMaximumDelay.isFinite,
              configuration.retryBaseDelay > 0,
              configuration.retryMaximumDelay >= configuration.retryBaseDelay
        else {
            throw DurableSyncCoordinatorError.invalidConfiguration(
                "Retry delays must be finite, positive, and monotonically bounded."
            )
        }
        self.store = store
        self.transport = transport
        self.configuration = configuration
        self.clock = clock
        self.attachmentBacklogProvider = attachmentBacklogProvider
    }

    public func synchronize() async throws -> SyncRunReport {
        if let activeSynchronization {
            return try await activeSynchronization.value
        }
        let task = Task { try await performSynchronization() }
        activeSynchronization = task
        defer { activeSynchronization = nil }
        return try await task.value
    }

    public func localDiagnostics() async throws -> NativeSyncDiagnostics {
        let local = try await store.localSyncDiagnostics()
        let attachmentBacklog = try await attachmentBacklogProvider()
        guard attachmentBacklog >= 0 else {
            throw DurableSyncCoordinatorError.invalidLocalState(
                "Attachment backlog cannot be negative."
            )
        }
        let state = local.syncState
        let deviceCursor = try SyncCursor(state.cursor)
        let serverCursor = try SyncCursor(state.serverCursor)
        let serverSchemaVersion = lastObservedServerSchemaVersion ?? state.serverSchemaVersion
        return NativeSyncDiagnostics(
            deviceID: state.deviceID,
            lastSuccessfulPushAt: state.lastSuccessfulPushAt,
            lastSuccessfulPullAt: state.lastSuccessfulPullAt,
            operationsQueued: local.operationsQueued,
            oldestUnsyncedOperationAt: local.oldestUnsyncedOperationAt,
            conflictCount: local.conflictCount,
            attachmentBacklog: attachmentBacklog,
            deviceCursor: deviceCursor,
            serverCursor: serverCursor,
            serverSchemaVersion: serverSchemaVersion,
            schemaCompatibility: schemaCompatibility(serverSchemaVersion: serverSchemaVersion)
        )
    }

    public func diagnostics() async throws -> SyncDiagnosticsResponse {
        let local = try await localDiagnostics()
        let input = try SyncDeviceDiagnosticsInput(
            deviceCursor: local.deviceCursor,
            operationsQueued: local.operationsQueued,
            oldestUnsyncedOperationAt: local.oldestUnsyncedOperationAt,
            attachmentBacklog: local.attachmentBacklog
        )
        _ = try await transport.reportDiagnostics(
            deviceID: local.deviceID,
            diagnostics: input
        )
        let response = try await transport.diagnostics()
        observeSchema(
            serverVersion: response.serverSchemaVersion,
            minimumClientVersion: response.minimumClientSchemaVersion
        )
        return response
    }

    private func performSynchronization() async throws -> SyncRunReport {
        let startedAt = clock()
        guard startedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DurableSyncCoordinatorError.invalidLocalState(
                "The local clock returned a non-finite instant."
            )
        }
        var pushedOperationCount = 0
        var pulledChangeCount = 0
        var conflictCount = 0

        let pushState = try await store.syncState()
        let readyOperations = try await store.pendingSyncOperations(
            limit: configuration.pushBatchSize,
            readyAt: startedAt
        )
        if !readyOperations.isEmpty {
            guard Set(readyOperations.map(\.operationID)).count == readyOperations.count else {
                throw DurableSyncCoordinatorError.invalidLocalState(
                    "The local sync queue contains duplicate operation identifiers."
                )
            }
            let operations = try readyOperations.map(SyncOperation.init(pending:))
            let baseCursor = try SyncCursor(pushState.cursor)
            let request = try SyncPushRequest(
                deviceID: pushState.deviceID,
                baseCursor: baseCursor,
                operations: operations
            )
            let response = try await transport.push(
                request,
                batchIdempotencyKey: batchIdempotencyKey(
                    deviceID: pushState.deviceID,
                    baseCursor: baseCursor,
                    operations: readyOperations
                )
            )
            try validateSchema(
                serverVersion: response.serverSchemaVersion,
                minimumClientVersion: response.minimumClientSchemaVersion
            )
            try validatePushResponse(
                response,
                pendingOperations: readyOperations,
                currentServerCursor: try SyncCursor(pushState.serverCursor)
            )
            let retryScheduledAt = clock()
            guard retryScheduledAt.timeIntervalSinceReferenceDate.isFinite else {
                throw DurableSyncCoordinatorError.invalidLocalState(
                    "The local clock returned a non-finite retry instant."
                )
            }
            try await store.applyPushResult(
                makePushResultBatch(
                    response,
                    pendingOperations: readyOperations,
                    retryScheduledAt: retryScheduledAt
                )
            )
            pushedOperationCount = operations.count
            conflictCount = response.conflicts.count
        }

        var pullState = try await store.syncState()
        var currentCursor = try SyncCursor(pullState.cursor)
        var hasMore = true
        var pulledPageCount = 0
        while hasMore {
            guard pulledPageCount < configuration.maximumPullPages else {
                throw DurableSyncCoordinatorError.pullPageLimitExceeded(
                    configuration.maximumPullPages
                )
            }
            let response = try await transport.pull(
                after: currentCursor,
                limit: configuration.pullPageSize,
                deviceID: pullState.deviceID
            )
            try validateSchema(
                serverVersion: response.serverSchemaVersion,
                minimumClientVersion: response.minimumClientSchemaVersion
            )
            try validatePullResponse(response, requestedAfter: currentCursor)
            let application = try await store.applyPullPage(makeRemotePage(response))
            pulledChangeCount += application.appliedCount
            let appliedCursor = try SyncCursor(application.finalCursor)
            guard appliedCursor >= currentCursor else {
                throw DurableSyncCoordinatorError.invalidLocalState(
                    "The durable pull cursor regressed after applying a page."
                )
            }
            currentCursor = appliedCursor
            hasMore = response.hasMore
            pulledPageCount += 1
            if hasMore {
                pullState = try await store.syncState()
            }
        }

        let completedAt = clock()
        guard completedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DurableSyncCoordinatorError.invalidLocalState(
                "The local clock returned a non-finite completion instant."
            )
        }
        return SyncRunReport(
            pushedOperationCount: pushedOperationCount,
            pulledChangeCount: pulledChangeCount,
            conflictCount: conflictCount,
            finalCursor: currentCursor,
            completedAt: completedAt
        )
    }

    private func validateSchema(
        serverVersion: Int,
        minimumClientVersion: Int
    ) throws {
        observeSchema(
            serverVersion: serverVersion,
            minimumClientVersion: minimumClientVersion
        )
        guard serverVersion >= 1,
              minimumClientVersion >= 1,
              minimumClientVersion <= serverVersion
        else {
            throw DurableSyncCoordinatorError.invalidSchemaMetadata(
                "The server returned inconsistent schema metadata."
            )
        }
        if minimumClientVersion > SyncSchema.currentVersion {
            throw DurableSyncCoordinatorError.clientUpgradeRequired(
                minimumVersion: minimumClientVersion,
                currentVersion: SyncSchema.currentVersion
            )
        }
        if serverVersion < SyncSchema.currentVersion {
            throw DurableSyncCoordinatorError.serverUpgradeRequired(
                serverVersion: serverVersion,
                currentVersion: SyncSchema.currentVersion
            )
        }
    }

    private func validatePushResponse(
        _ response: SyncPushResponse,
        pendingOperations: [PendingSyncOperation],
        currentServerCursor: SyncCursor
    ) throws {
        guard response.serverTime.timeIntervalSinceReferenceDate.isFinite,
              response.nextCursor >= currentServerCursor
        else {
            throw DurableSyncCoordinatorError.invalidPushResponse(
                "The push response has an invalid time or regressed server cursor."
            )
        }
        let pendingByID = Dictionary(
            uniqueKeysWithValues: pendingOperations.map { ($0.operationID, $0) }
        )
        let acceptedIDs = response.accepted.map(\.operationID)
        let rejectedIDs = response.rejected.map(\.operationID)
        let conflictIDs = response.conflicts.map(\.operationID)
        let resultIDs = acceptedIDs + rejectedIDs + conflictIDs
        guard resultIDs.count == pendingOperations.count,
              Set(resultIDs).count == resultIDs.count,
              Set(resultIDs) == Set(pendingByID.keys)
        else {
            throw DurableSyncCoordinatorError.invalidPushResponse(
                "Every pushed operation must receive exactly one result."
            )
        }
        for acceptance in response.accepted {
            guard acceptance.canonicalRevision >= 1,
                  acceptance.serverChangeID >= 1,
                  acceptance.serverChangeID <= response.nextCursor.value,
                  Self.isBoundedNonempty(acceptance.mergeResult, maximum: 200)
            else {
                throw DurableSyncCoordinatorError.invalidPushResponse(
                    "An accepted operation has invalid canonical metadata."
                )
            }
        }
        for rejection in response.rejected {
            guard Self.isBoundedNonempty(rejection.code, maximum: 200),
                  Self.isBoundedNonempty(rejection.message, maximum: 2_000)
            else {
                throw DurableSyncCoordinatorError.invalidPushResponse(
                    "A rejected operation has invalid details."
                )
            }
        }
        for conflict in response.conflicts {
            guard let pending = pendingByID[conflict.operationID],
                  pending.entityType == conflict.entityType,
                  pending.entityID == conflict.entityID,
                  Self.isBoundedNonempty(conflict.code, maximum: 200),
                  conflict.currentRevision.map({ $0 >= 1 }) ?? true
            else {
                throw DurableSyncCoordinatorError.invalidPushResponse(
                    "A conflict does not match its pushed operation."
                )
            }
        }
    }

    private func validatePullResponse(
        _ response: SyncPullResponse,
        requestedAfter cursor: SyncCursor
    ) throws {
        guard response.serverTime.timeIntervalSinceReferenceDate.isFinite,
              response.nextCursor >= cursor
        else {
            throw DurableSyncCoordinatorError.invalidPullResponse(
                "The pull response has an invalid time or regressed cursor."
            )
        }
        if response.hasMore, response.nextCursor == cursor {
            throw DurableSyncCoordinatorError.invalidPullResponse(
                "A resumable pull page must advance its cursor when more data remains."
            )
        }
        let changeIDs = response.changes.map(\.changeID)
        guard changeIDs == changeIDs.sorted(),
              Set(changeIDs).count == changeIDs.count,
              changeIDs.allSatisfy({ $0 >= 1 && $0 <= response.nextCursor.value })
        else {
            throw DurableSyncCoordinatorError.invalidPullResponse(
                "Pull changes must have unique ascending identifiers within the cursor."
            )
        }
        for change in response.changes {
            let validDeletion = change.mutationType == .delete
                ? change.tombstone && change.deletionEpoch.map(Int64.init) == change.changeID
                : !change.tombstone && change.deletionEpoch == nil
            guard change.canonicalRevision >= 1,
                  Self.isBoundedNonempty(change.entityType, maximum: 100),
                  Self.isBoundedNonempty(change.mergeResult, maximum: 200),
                  change.serverReceivedAt.timeIntervalSinceReferenceDate.isFinite,
                  validDeletion
            else {
                throw DurableSyncCoordinatorError.invalidPullResponse(
                    "A pulled change has invalid canonical or tombstone metadata."
                )
            }
        }
    }

    private func makePushResultBatch(
        _ response: SyncPushResponse,
        pendingOperations: [PendingSyncOperation],
        retryScheduledAt: Date
    ) -> SyncPushResultBatch {
        let pendingByID = Dictionary(
            uniqueKeysWithValues: pendingOperations.map { ($0.operationID, $0) }
        )
        return SyncPushResultBatch(
            accepted: response.accepted.map {
                SyncPushAcceptance(
                    operationID: $0.operationID,
                    canonicalRevision: $0.canonicalRevision,
                    serverChangeID: $0.serverChangeID,
                    mergeResult: $0.mergeResult
                )
            },
            rejected: response.rejected.map {
                let operation = pendingByID[$0.operationID]!
                return SyncPushRejection(
                    operationID: $0.operationID,
                    code: $0.code,
                    message: "The server rejected this operation.",
                    retryable: $0.retryable,
                    nextAttemptAt: $0.retryable
                        ? retryScheduledAt.addingTimeInterval(
                            retryDelay(previousAttemptCount: operation.attemptCount)
                        )
                        : nil
                )
            },
            conflicts: response.conflicts.map {
                SyncPushConflict(
                    conflictID: $0.conflictID,
                    operationID: $0.operationID,
                    code: $0.code,
                    message: "A canonical revision conflict requires review.",
                    currentRevision: $0.currentRevision
                )
            },
            nextServerCursor: response.nextCursor.description,
            serverSchemaVersion: response.serverSchemaVersion,
            completedAt: response.serverTime
        )
    }

    private func makeRemotePage(_ response: SyncPullResponse) throws -> RemoteSyncPage {
        try RemoteSyncPage(
            changes: response.changes.map {
                RemoteSyncChange(
                    changeID: $0.changeID,
                    canonicalRevision: $0.canonicalRevision,
                    entityType: $0.entityType,
                    entityID: $0.entityID,
                    mutationType: $0.mutationType,
                    payload: try SyncJSONCoding.makeEncoder().encode($0.payload),
                    tombstone: $0.tombstone,
                    deletionEpoch: $0.deletionEpoch.map(Int64.init),
                    mergeResult: $0.mergeResult,
                    originDeviceID: $0.originDeviceID,
                    originOperationID: $0.originOperationID,
                    serverReceivedAt: $0.serverReceivedAt
                )
            },
            nextCursor: response.nextCursor.description,
            hasMore: response.hasMore,
            serverSchemaVersion: response.serverSchemaVersion,
            completedAt: response.serverTime
        )
    }

    private func batchIdempotencyKey(
        deviceID: UUIDv7,
        baseCursor: SyncCursor,
        operations: [PendingSyncOperation]
    ) -> String {
        let material = ([deviceID.description, baseCursor.description] + operations.flatMap {
            [
                $0.operationID.description,
                String($0.deviceSequence),
                $0.payloadSHA256,
            ]
        }).joined(separator: "|")
        return "sync-v1-\(SHA256Digest.hexDigest(of: Data(material.utf8)))"
    }

    private func retryDelay(previousAttemptCount: Int) -> TimeInterval {
        let exponent = min(max(previousAttemptCount, 0), 20)
        let multiplier = pow(2, Double(exponent))
        return min(
            configuration.retryMaximumDelay,
            configuration.retryBaseDelay * multiplier
        )
    }

    private func observeSchema(
        serverVersion: Int?,
        minimumClientVersion: Int?
    ) {
        if let serverVersion {
            lastObservedServerSchemaVersion = serverVersion
        }
        if let minimumClientVersion {
            lastObservedMinimumClientSchemaVersion = minimumClientVersion
        }
    }

    private func schemaCompatibility(
        serverSchemaVersion: Int?
    ) -> NativeSchemaCompatibility {
        if let minimum = lastObservedMinimumClientSchemaVersion,
           minimum > SyncSchema.currentVersion
        {
            return .clientUpgradeRequired
        }
        if let serverSchemaVersion,
           serverSchemaVersion < SyncSchema.currentVersion
        {
            return .serverUpgradeRequired
        }
        if serverSchemaVersion == SyncSchema.currentVersion {
            return .compatible
        }
        if serverSchemaVersion != nil,
           lastObservedMinimumClientSchemaVersion != nil
        {
            return .compatible
        }
        return .unknown
    }

    private static func isBoundedNonempty(
        _ value: String,
        maximum: Int
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value && value.count <= maximum
    }
}
