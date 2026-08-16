import Foundation
import GRDB
import OdysseyDomain
import OdysseyTelemetry

public struct SQLiteLedgerConfiguration: Sendable {
    public let databaseURL: URL
    public let deviceID: UUIDv7
    public let preMigrationBackupDirectory: URL?
    public let busyTimeoutMilliseconds: Int
    public let featureConfigurationVerifier: FeatureConfigurationVerifier?
    public let clock: @Sendable () -> Date

    public init(
        databaseURL: URL,
        deviceID: UUIDv7,
        preMigrationBackupDirectory: URL? = nil,
        busyTimeoutMilliseconds: Int = 5_000,
        featureConfigurationVerifier: FeatureConfigurationVerifier? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL
        self.deviceID = deviceID
        self.preMigrationBackupDirectory = preMigrationBackupDirectory
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        self.featureConfigurationVerifier = featureConfigurationVerifier
        self.clock = clock
    }
}

public final class SQLiteLedgerStore:
    @unchecked Sendable,
    LedgerStore,
    SyncOutboxStore,
    SyncPersistenceStore,
    ProjectionRebuilder,
    OwnerExporter,
    LocalBackupProvider
{
    public static let currentSchemaVersion = 7
    public static let maximumSyncPayloadBytes = 256 * 1_024
    public static let maximumProjectionPayloadBytes = 1_024 * 1_024

    let databasePool: DatabasePool
    let configuration: SQLiteLedgerConfiguration
    private let accessLock: NSRecursiveLock
    private var activeSession: SQLiteSession?

    var connection: SQLiteSession {
        guard let activeSession else {
            preconditionFailure("SQLite access must run inside a GRDB read or write transaction.")
        }
        return activeSession
    }

    public init(configuration: SQLiteLedgerConfiguration) throws {
        guard configuration.databaseURL.isFileURL else {
            throw SQLiteLedgerError.invalidConfiguration("The ledger database must use a file URL.")
        }
        guard configuration.busyTimeoutMilliseconds >= 0 else {
            throw SQLiteLedgerError.invalidConfiguration("The SQLite busy timeout cannot be negative.")
        }

        let parentDirectory = configuration.databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        Self.applyFileProtectionIfAvailable(to: parentDirectory)

        let databasePool = try Self.makeDatabasePool(
            at: configuration.databaseURL,
            busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds
        )
        self.databasePool = databasePool
        self.configuration = configuration
        accessLock = NSRecursiveLock()
        activeSession = nil

        let existingVersion = try databasePool.read { database in
            Int(try SQLiteSession(database: database).scalarInt("PRAGMA user_version"))
        }
        guard existingVersion <= Self.currentSchemaVersion else {
            throw SQLiteLedgerError.unsupportedSchemaVersion(
                found: existingVersion,
                supported: Self.currentSchemaVersion
            )
        }
        if existingVersion > 0, existingVersion < Self.currentSchemaVersion {
            guard let backupDirectory = configuration.preMigrationBackupDirectory else {
                throw SQLiteLedgerError.invalidConfiguration(
                    "A pre-migration backup directory is required to upgrade an existing ledger."
                )
            }
            try Self.createPreMigrationBackup(
                databasePool: databasePool,
                sourceURL: configuration.databaseURL,
                backupDirectory: backupDirectory,
                fromVersion: existingVersion,
                clock: configuration.clock
            )
        }
        try Self.makeMigrator(clock: configuration.clock).migrate(databasePool)
        try databasePool.write { database in
            try Self.initializeDeviceState(
                SQLiteSession(database: database),
                deviceID: configuration.deviceID,
                clock: configuration.clock
            )
        }
        Self.applyFileProtectionIfAvailable(to: configuration.databaseURL)
    }

    public func append(_ entry: LedgerEntry) async throws {
        _ = try await commit(LedgerCommit(entry: entry))
    }

    public func commit(_ commit: LedgerCommit) async throws -> LedgerCommitReceipt {
        try Self.validate(commit)
        return try withWrite {
            let localSequence = try insertLedgerEntry(commit.entry)
            if let projection = commit.projection {
                try insertProjection(
                    projection,
                    ledgerLocalSequence: localSequence,
                    sourceEventID: commit.entry.eventID,
                    recordedAt: commit.entry.recordedAt
                )
            }
            let queuedOperation = try commit.syncMutation.map {
                try insertSyncOperation(
                    $0,
                    ledgerLocalSequence: localSequence,
                    sourceEventID: commit.entry.eventID
                )
            }
            return LedgerCommitReceipt(
                localSequence: localSequence,
                queuedOperation: queuedOperation
            )
        }
    }

    public func entries(after eventID: UUIDv7?, limit: Int) async throws -> [LedgerEntry] {
        try storedEntries(after: eventID, limit: limit).map(\.entry)
    }

    public func storedEntries(
        after eventID: UUIDv7? = nil,
        limit: Int = 500
    ) throws -> [StoredLedgerEntry] {
        try withRead {
            try readStoredEntries(after: eventID, limit: limit)
        }
    }

    private func readStoredEntries(
        after eventID: UUIDv7?,
        limit: Int
    ) throws -> [StoredLedgerEntry] {
        guard (1 ... 10_000).contains(limit) else {
            throw SQLiteLedgerError.invalidConfiguration("Ledger page size must be between 1 and 10,000.")
        }
        let startingSequence: Int64
        if let eventID {
            let statement = try connection.statement(
                "SELECT local_sequence FROM ledger_entries WHERE event_id = ?"
            )
            try statement.bind([.text(eventID.description)])
            guard try statement.step() else {
                throw SQLiteLedgerError.unknownLedgerEvent(eventID.description)
            }
            startingSequence = statement.int64(at: 0)
        } else {
            startingSequence = 0
        }

        let statement = try connection.statement(
            """
            SELECT local_sequence, event_id, event_type, aggregate_type, aggregate_id,
                   occurred_at, recorded_at, payload, payload_sha256, provenance_id
            FROM ledger_entries
            WHERE local_sequence > ?
            ORDER BY local_sequence
            LIMIT ?
            """
        )
        try statement.bind([.integer(startingSequence), .integer(Int64(limit))])
        var entries: [StoredLedgerEntry] = []
        while try statement.step() {
            entries.append(try Self.decodeLedgerEntry(statement))
        }
        return entries
    }

    public func projectedEntity(
        entityType: String,
        entityID: UUIDv7
    ) throws -> ProjectedEntity? {
        try withRead {
            try readProjectedEntity(entityType: entityType, entityID: entityID)
        }
    }

    private func readProjectedEntity(
        entityType: String,
        entityID: UUIDv7
    ) throws -> ProjectedEntity? {
        let statement = try connection.statement(
            """
            SELECT entity_type, entity_id, revision, document, tombstone,
                   source_event_id, updated_at
            FROM entity_projections
            WHERE entity_type = ? AND entity_id = ?
            """
        )
        try statement.bind([.text(entityType), .text(entityID.description)])
        guard try statement.step() else {
            return nil
        }
        return try Self.decodeProjectedEntity(statement)
    }

    public func pendingSyncOperations(
        limit: Int = 500,
        readyAt: Date = Date()
    ) async throws -> [PendingSyncOperation] {
        try withRead {
            try readPendingSyncOperations(limit: limit, readyAt: readyAt)
        }
    }

    private func readPendingSyncOperations(
        limit: Int,
        readyAt: Date
    ) throws -> [PendingSyncOperation] {
        guard (1 ... 500).contains(limit) else {
            throw SQLiteLedgerError.invalidConfiguration("Sync batch size must be between 1 and 500.")
        }
        let statement = try connection.statement(
            """
            SELECT operation.operation_id, operation.device_sequence,
                   operation.entity_type, operation.entity_id, operation.mutation_type,
                   operation.base_revision, operation.payload, operation.payload_sha256,
                   operation.created_at, operation.idempotency_key,
                   operation.sensitivity_class, ledger.event_id,
                   state.status, state.attempt_count, state.next_attempt_at, state.last_error
            FROM sync_operations AS operation
            JOIN sync_operation_state AS state USING (operation_id)
            JOIN ledger_entries AS ledger
              ON ledger.local_sequence = operation.ledger_local_sequence
            WHERE state.status IN ('pending', 'retry')
              AND (state.next_attempt_at IS NULL OR state.next_attempt_at <= ?)
            ORDER BY operation.device_sequence
            LIMIT ?
            """
        )
        try statement.bind([
            .text(SQLiteValueCodec.dateString(readyAt)),
            .integer(Int64(limit)),
        ])
        var operations: [PendingSyncOperation] = []
        while try statement.step() {
            operations.append(try Self.decodeSyncOperation(statement))
        }
        return operations
    }

    public func syncState() async throws -> LocalSyncState {
        try withRead {
            try readSyncState()
        }
    }

    public func localSyncDiagnostics() async throws -> LocalSyncDiagnostics {
        try withRead {
            let statement = try connection.statement(
                """
                SELECT COUNT(*), MIN(operation.created_at)
                FROM sync_operations AS operation
                JOIN sync_operation_state AS state USING (operation_id)
                WHERE state.status IN ('pending', 'retry')
                """
            )
            guard try statement.step() else {
                throw SQLiteLedgerError.integrityFailure(
                    "The local sync diagnostics query returned no aggregate row."
                )
            }
            let operationsQueued = Int(statement.int64(at: 0))
            let oldestUnsyncedOperationAt = try statement.optionalText(at: 1)
                .map(SQLiteValueCodec.date)
            let conflictCount = Int(
                try connection.scalarInt(
                    "SELECT COUNT(*) FROM sync_operation_state WHERE status = 'conflict'"
                )
            )
            guard (operationsQueued == 0) == (oldestUnsyncedOperationAt == nil) else {
                throw SQLiteLedgerError.integrityFailure(
                    "The local sync queue count and oldest operation are inconsistent."
                )
            }
            return LocalSyncDiagnostics(
                syncState: try readSyncState(),
                operationsQueued: operationsQueued,
                oldestUnsyncedOperationAt: oldestUnsyncedOperationAt,
                conflictCount: conflictCount
            )
        }
    }

    func markOperationAccepted(
        operationID: UUIDv7,
        canonicalRevision: Int,
        serverChangeID: Int64,
        acceptedAt: Date
    ) throws {
        guard canonicalRevision >= 1, serverChangeID >= 1 else {
            throw SQLiteLedgerError.invalidSyncMutation(
                "Accepted operations require positive canonical revisions and server change identifiers."
            )
        }
        try withWrite {
            let statement = try connection.statement(
                """
                UPDATE sync_operation_state
                SET status = 'accepted', canonical_revision = ?, server_change_id = ?,
                    completed_at = ?, next_attempt_at = NULL, last_error = NULL
                WHERE operation_id = ? AND status IN ('pending', 'retry')
                """
            )
            try statement.bind([
                .integer(Int64(canonicalRevision)),
                .integer(serverChangeID),
                .text(SQLiteValueCodec.dateString(acceptedAt)),
                .text(operationID.description),
            ])
            _ = try statement.step()
            guard try connection.scalarInt("SELECT changes()") == 1 else {
                throw SQLiteLedgerError.invalidSyncMutation(
                    "Operation \(operationID) is missing or is no longer pending."
                )
            }
        }
    }

    func markOperationForRetry(
        operationID: UUIDv7,
        error: String,
        nextAttemptAt: Date
    ) throws {
        guard !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteLedgerError.invalidSyncMutation("A retry must retain a nonempty error message.")
        }
        try withWrite {
            let statement = try connection.statement(
                """
                UPDATE sync_operation_state
                SET status = 'retry', attempt_count = attempt_count + 1,
                    next_attempt_at = ?, last_error = ?, completed_at = NULL
                WHERE operation_id = ? AND status IN ('pending', 'retry')
                """
            )
            try statement.bind([
                .text(SQLiteValueCodec.dateString(nextAttemptAt)),
                .text(error),
                .text(operationID.description),
            ])
            _ = try statement.step()
            guard try connection.scalarInt("SELECT changes()") == 1 else {
                throw SQLiteLedgerError.invalidSyncMutation(
                    "Operation \(operationID) is missing or is no longer pending."
                )
            }
        }
    }

    func markOperationTerminal(
        operationID: UUIDv7,
        status: SyncOperationStatus,
        message: String,
        completedAt: Date
    ) throws {
        guard status == .rejected || status == .conflict else {
            throw SQLiteLedgerError.invalidSyncMutation(
                "Only rejected or conflict operations may use terminal failure state."
            )
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteLedgerError.invalidSyncMutation("A terminal sync result requires a message.")
        }
        try withWrite {
            let statement = try connection.statement(
                """
                UPDATE sync_operation_state
                SET status = ?, attempt_count = attempt_count + 1,
                    next_attempt_at = NULL, last_error = ?, completed_at = ?
                WHERE operation_id = ? AND status IN ('pending', 'retry')
                """
            )
            try statement.bind([
                .text(status.rawValue),
                .text(message),
                .text(SQLiteValueCodec.dateString(completedAt)),
                .text(operationID.description),
            ])
            _ = try statement.step()
            guard try connection.scalarInt("SELECT changes()") == 1 else {
                throw SQLiteLedgerError.invalidSyncMutation(
                    "Operation \(operationID) is missing or is no longer pending."
                )
            }
        }
    }

    func recordSuccessfulPush(
        cursor: String,
        serverSchemaVersion: Int,
        at date: Date
    ) throws {
        try withWrite {
            try updateSyncState(
                deviceCursor: nil,
                serverCursor: cursor,
                serverSchemaVersion: serverSchemaVersion,
                pushAt: date,
                pullAt: nil
            )
        }
    }

    func recordSuccessfulPull(
        cursor: String,
        serverSchemaVersion: Int,
        at date: Date
    ) throws {
        try withWrite {
            try updateSyncState(
                deviceCursor: cursor,
                serverCursor: cursor,
                serverSchemaVersion: serverSchemaVersion,
                pushAt: nil,
                pullAt: date
            )
        }
    }

    func insertLedgerEntry(_ entry: LedgerEntry) throws -> Int64 {
        let statement = try connection.statement(
            """
            INSERT INTO ledger_entries (
                event_id, event_type, aggregate_type, aggregate_id,
                occurred_at, recorded_at, payload, payload_sha256, provenance_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind([
            .text(entry.eventID.description),
            .text(entry.eventType),
            .text(entry.aggregateType),
            .text(entry.aggregateID.description),
            .text(SQLiteValueCodec.dateString(entry.occurredAt)),
            .text(SQLiteValueCodec.dateString(entry.recordedAt)),
            .blob(entry.payload),
            .text(SHA256Digest.hexDigest(of: entry.payload)),
            .text(entry.provenanceID.uuidString.lowercased()),
        ])
        _ = try statement.step()
        return connection.lastInsertedRowID
    }

    private func insertProjection(
        _ projection: ProjectionMutation,
        ledgerLocalSequence: Int64,
        sourceEventID: UUIDv7,
        recordedAt: Date
    ) throws {
        let existingStatement = try connection.statement(
            """
            SELECT revision, tombstone
            FROM entity_projections
            WHERE entity_type = ? AND entity_id = ?
            """
        )
        try existingStatement.bind([
            .text(projection.entityType),
            .text(projection.entityID.description),
        ])
        let hasExisting = try existingStatement.step()
        if projection.mutationType == .create {
            guard !hasExisting, projection.revision == 1 else {
                throw SQLiteLedgerError.invalidProjection(
                    "Create projections require revision 1 and no existing entity."
                )
            }
        } else {
            guard hasExisting else {
                throw SQLiteLedgerError.invalidProjection(
                    "Update and delete projections require an existing entity."
                )
            }
            let currentRevision = Int(existingStatement.int64(at: 0))
            let isTombstoned = existingStatement.int64(at: 1) == 1
            guard !isTombstoned, projection.revision == currentRevision + 1 else {
                throw SQLiteLedgerError.invalidProjection(
                    "Projection revisions must advance one step from a live entity."
                )
            }
        }

        let documentHash = SHA256Digest.hexDigest(of: projection.document)
        let eventStatement = try connection.statement(
            """
            INSERT INTO projection_events (
                ledger_local_sequence, entity_type, entity_id, revision,
                mutation_type, document, document_sha256, recorded_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try eventStatement.bind([
            .integer(ledgerLocalSequence),
            .text(projection.entityType),
            .text(projection.entityID.description),
            .integer(Int64(projection.revision)),
            .text(projection.mutationType.rawValue),
            .blob(projection.document),
            .text(documentHash),
            .text(SQLiteValueCodec.dateString(recordedAt)),
        ])
        _ = try eventStatement.step()

        let projectionStatement = try connection.statement(
            """
            INSERT INTO entity_projections (
                entity_type, entity_id, revision, document, document_sha256,
                tombstone, source_event_id, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (entity_type, entity_id) DO UPDATE SET
                revision = excluded.revision,
                document = excluded.document,
                document_sha256 = excluded.document_sha256,
                tombstone = excluded.tombstone,
                source_event_id = excluded.source_event_id,
                updated_at = excluded.updated_at
            """
        )
        try projectionStatement.bind([
            .text(projection.entityType),
            .text(projection.entityID.description),
            .integer(Int64(projection.revision)),
            .blob(projection.document),
            .text(documentHash),
            .integer(projection.mutationType == .delete ? 1 : 0),
            .text(sourceEventID.description),
            .text(SQLiteValueCodec.dateString(recordedAt)),
        ])
        _ = try projectionStatement.step()
    }

    private func insertSyncOperation(
        _ mutation: SyncMutationDraft,
        ledgerLocalSequence: Int64,
        sourceEventID: UUIDv7
    ) throws -> PendingSyncOperation {
        let currentState = try readSyncState()
        let deviceSequence = currentState.nextDeviceSequence
        let payloadHash = SHA256Digest.hexDigest(of: mutation.payload)
        let operationStatement = try connection.statement(
            """
            INSERT INTO sync_operations (
                operation_id, device_sequence, ledger_local_sequence,
                entity_type, entity_id, mutation_type, base_revision,
                payload, payload_sha256, created_at, idempotency_key,
                sensitivity_class
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try operationStatement.bind([
            .text(mutation.operationID.description),
            .integer(deviceSequence),
            .integer(ledgerLocalSequence),
            .text(mutation.entityType),
            .text(mutation.entityID.description),
            .text(mutation.mutationType.rawValue),
            mutation.baseRevision.map { .integer(Int64($0)) } ?? .null,
            .blob(mutation.payload),
            .text(payloadHash),
            .text(SQLiteValueCodec.dateString(mutation.createdAt)),
            .text(mutation.idempotencyKey),
            .text(mutation.sensitivityClass.rawValue),
        ])
        _ = try operationStatement.step()

        let stateStatement = try connection.statement(
            """
            INSERT INTO sync_operation_state (operation_id, status, attempt_count)
            VALUES (?, 'pending', 0)
            """
        )
        try stateStatement.bind([.text(mutation.operationID.description)])
        _ = try stateStatement.step()

        let sequenceStatement = try connection.statement(
            """
            UPDATE sync_state
            SET next_device_sequence = next_device_sequence + 1
            WHERE singleton = 1 AND next_device_sequence = ?
            """
        )
        try sequenceStatement.bind([.integer(deviceSequence)])
        _ = try sequenceStatement.step()
        guard try connection.scalarInt("SELECT changes()") == 1 else {
            throw SQLiteLedgerError.integrityFailure("Device sequence allocation lost atomicity.")
        }

        return PendingSyncOperation(
            operationID: mutation.operationID,
            deviceSequence: deviceSequence,
            entityType: mutation.entityType,
            entityID: mutation.entityID,
            mutationType: mutation.mutationType,
            baseRevision: mutation.baseRevision,
            payload: mutation.payload,
            payloadSHA256: payloadHash,
            createdAt: mutation.createdAt,
            idempotencyKey: mutation.idempotencyKey,
            sensitivityClass: mutation.sensitivityClass,
            sourceEventID: sourceEventID,
            status: .pending,
            attemptCount: 0,
            nextAttemptAt: nil,
            lastError: nil
        )
    }

    func readSyncState() throws -> LocalSyncState {
        let statement = try connection.statement(
            """
            SELECT device_id, cursor, server_cursor, receipt_floor, next_device_sequence,
                   last_successful_push_at, last_successful_pull_at, server_schema_version
            FROM sync_state
            WHERE singleton = 1
            """
        )
        guard try statement.step() else {
            throw SQLiteLedgerError.integrityFailure("The singleton sync state is missing.")
        }
        let serverSchemaVersion = statement.optionalText(at: 7).flatMap(Int.init)
        return LocalSyncState(
            deviceID: try SQLiteValueCodec.uuidV7(statement.text(at: 0)),
            cursor: try statement.text(at: 1),
            serverCursor: try statement.text(at: 2),
            receiptFloor: statement.int64(at: 3),
            nextDeviceSequence: statement.int64(at: 4),
            lastSuccessfulPushAt: try statement.optionalText(at: 5).map(SQLiteValueCodec.date),
            lastSuccessfulPullAt: try statement.optionalText(at: 6).map(SQLiteValueCodec.date),
            serverSchemaVersion: serverSchemaVersion
        )
    }

    func updateSyncState(
        deviceCursor: String?,
        serverCursor: String,
        serverSchemaVersion: Int,
        pushAt: Date?,
        pullAt: Date?
    ) throws {
        guard deviceCursor.map(Self.isValidCursor) ?? true,
              Self.isValidCursor(serverCursor)
        else {
            throw SQLiteLedgerError.invalidSyncMutation(
                "Sync cursor must use c_<nonnegative integer>."
            )
        }
        guard serverSchemaVersion >= 1 else {
            throw SQLiteLedgerError.invalidSyncMutation("Server schema version must be positive.")
        }
        let current = try readSyncState()
        guard let currentServerValue = Self.cursorValue(current.serverCursor),
              let serverValue = Self.cursorValue(serverCursor),
              serverValue >= currentServerValue
        else {
            throw SQLiteLedgerError.invalidSyncMutation("Server sync cursor cannot move backward.")
        }
        if let deviceCursor {
            guard let currentDeviceValue = Self.cursorValue(current.cursor),
                  let deviceValue = Self.cursorValue(deviceCursor),
                  deviceValue >= currentDeviceValue,
                  deviceValue <= serverValue
            else {
                throw SQLiteLedgerError.invalidSyncMutation(
                    "Applied sync cursor must advance monotonically and cannot exceed the server cursor."
                )
            }
        }
        let statement = try connection.statement(
            """
            UPDATE sync_state
            SET cursor = COALESCE(?, cursor), server_cursor = ?, server_schema_version = ?,
                last_successful_push_at = COALESCE(?, last_successful_push_at),
                last_successful_pull_at = COALESCE(?, last_successful_pull_at)
            WHERE singleton = 1
            """
        )
        try statement.bind([
            deviceCursor.map(SQLiteValue.text) ?? .null,
            .text(serverCursor),
            .integer(Int64(serverSchemaVersion)),
            pushAt.map { .text(SQLiteValueCodec.dateString($0)) } ?? .null,
            pullAt.map { .text(SQLiteValueCodec.dateString($0)) } ?? .null,
        ])
        _ = try statement.step()
        guard try connection.scalarInt("SELECT changes()") == 1 else {
            throw SQLiteLedgerError.integrityFailure("The singleton sync state is missing.")
        }
    }

    func withRead<Result>(_ access: () throws -> Result) throws -> Result {
        accessLock.lock()
        defer { accessLock.unlock() }
        precondition(activeSession == nil, "GRDB database access is not reentrant.")
        return try databasePool.read { database in
            activeSession = SQLiteSession(database: database)
            defer { activeSession = nil }
            return try access()
        }
    }

    func withWrite<Result>(_ access: () throws -> Result) throws -> Result {
        accessLock.lock()
        defer { accessLock.unlock() }
        precondition(activeSession == nil, "GRDB database access is not reentrant.")
        return try databasePool.write { database in
            activeSession = SQLiteSession(database: database)
            defer { activeSession = nil }
            let result = try access()
            try activeSession?.notifyChanges()
            return result
        }
    }
}

extension SQLiteLedgerStore {
    private static func validate(_ commit: LedgerCommit) throws {
        let entry = commit.entry
        guard isValidTypeName(entry.eventType), isValidTypeName(entry.aggregateType) else {
            throw SQLiteLedgerError.invalidLedgerEntry(
                "Event and aggregate types must contain 1 through 100 non-whitespace characters."
            )
        }
        guard entry.payload.count <= 16 * 1_024 * 1_024 else {
            throw SQLiteLedgerError.invalidLedgerEntry("Ledger payload exceeds the 16 MiB local limit.")
        }
        guard entry.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              entry.recordedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SQLiteLedgerError.invalidLedgerEntry("Ledger timestamps must be finite.")
        }

        if let projection = commit.projection {
            guard isValidTypeName(projection.entityType), projection.revision >= 1 else {
                throw SQLiteLedgerError.invalidProjection(
                    "Projection entity types must be nonempty and revisions must be positive."
                )
            }
            try validateJSONObject(
                projection.document,
                maximumBytes: maximumProjectionPayloadBytes,
                context: "Projection document"
            )
            guard projection.entityType == entry.aggregateType,
                  projection.entityID == entry.aggregateID
            else {
                throw SQLiteLedgerError.invalidProjection(
                    "Projection identity must match the ledger aggregate identity."
                )
            }
            if projection.mutationType == .create, projection.revision != 1 {
                throw SQLiteLedgerError.invalidProjection("Create projections must use revision 1.")
            }
        }

        if let mutation = commit.syncMutation {
            guard isValidTypeName(mutation.entityType) else {
                throw SQLiteLedgerError.invalidSyncMutation(
                    "Sync entity types must contain 1 through 100 non-whitespace characters."
                )
            }
            try validateJSONObject(
                mutation.payload,
                maximumBytes: maximumSyncPayloadBytes,
                context: "Sync payload"
            )
            guard (1 ... 500).contains(mutation.idempotencyKey.count) else {
                throw SQLiteLedgerError.invalidSyncMutation(
                    "Idempotency keys must contain 1 through 500 characters."
                )
            }
            guard mutation.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw SQLiteLedgerError.invalidSyncMutation(
                    "Sync operation timestamps must be finite."
                )
            }
            switch mutation.mutationType {
            case .create:
                guard mutation.baseRevision == nil else {
                    throw SQLiteLedgerError.invalidSyncMutation(
                        "Create sync operations cannot declare a base revision."
                    )
                }
            case .update:
                guard let baseRevision = mutation.baseRevision, baseRevision >= 1 else {
                    throw SQLiteLedgerError.invalidSyncMutation(
                        "Update sync operations require a positive base revision."
                    )
                }
            case .delete:
                guard let baseRevision = mutation.baseRevision, baseRevision >= 1 else {
                    throw SQLiteLedgerError.invalidSyncMutation(
                        "Delete sync operations require a positive base revision."
                    )
                }
                let object = try JSONSerialization.jsonObject(with: mutation.payload)
                guard let dictionary = object as? [String: Any], dictionary.isEmpty else {
                    throw SQLiteLedgerError.invalidSyncMutation(
                        "Delete sync operations must use an empty JSON object payload."
                    )
                }
            }
            guard mutation.entityType == entry.aggregateType,
                  mutation.entityID == entry.aggregateID
            else {
                throw SQLiteLedgerError.invalidSyncMutation(
                    "Sync operation identity must match the ledger aggregate identity."
                )
            }
            if let projection = commit.projection {
                guard projection.entityType == mutation.entityType,
                      projection.entityID == mutation.entityID,
                      projection.mutationType == mutation.mutationType
                else {
                    throw SQLiteLedgerError.invalidSyncMutation(
                        "Projection and sync mutation semantics must match."
                    )
                }
                if let baseRevision = mutation.baseRevision {
                    guard projection.revision == baseRevision + 1 else {
                        throw SQLiteLedgerError.invalidSyncMutation(
                            "Projected revision must immediately follow the sync base revision."
                        )
                    }
                }
            }
        }
    }

    private static func validateJSONObject(
        _ data: Data,
        maximumBytes: Int,
        context: String
    ) throws {
        guard data.count <= maximumBytes else {
            throw SQLiteLedgerError.invalidSyncMutation(
                "\(context) exceeds the \(maximumBytes)-byte limit."
            )
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard object is [String: Any] else {
                throw SQLiteLedgerError.invalidSyncMutation("\(context) must be a JSON object.")
            }
        } catch let error as SQLiteLedgerError {
            throw error
        } catch {
            throw SQLiteLedgerError.invalidSyncMutation("\(context) is not valid JSON.")
        }
    }

    static func isValidTypeName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 100
    }

    static func isValidCursor(_ cursor: String) -> Bool {
        guard cursor.hasPrefix("c_"), cursor.count > 2 else {
            return false
        }
        let suffix = cursor.dropFirst(2)
        guard suffix.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            return false
        }
        return suffix == "0" || suffix.first != "0"
    }

    static func cursorValue(_ cursor: String) -> Int64? {
        guard isValidCursor(cursor) else {
            return nil
        }
        return Int64(cursor.dropFirst(2))
    }

    static func decodeLedgerEntry(_ statement: SQLiteRowStatement) throws -> StoredLedgerEntry {
        let eventID = try SQLiteValueCodec.uuidV7(statement.text(at: 1))
        let aggregateID = try SQLiteValueCodec.uuidV7(statement.text(at: 4))
        let provenanceValue = try statement.text(at: 9)
        guard let provenanceID = UUID(uuidString: provenanceValue) else {
            throw SQLiteLedgerError.integrityFailure(
                "Invalid provenance UUID for event \(eventID)."
            )
        }
        let payload = try statement.data(at: 7)
        return StoredLedgerEntry(
            localSequence: statement.int64(at: 0),
            entry: LedgerEntry(
                eventID: eventID,
                eventType: try statement.text(at: 2),
                aggregateType: try statement.text(at: 3),
                aggregateID: aggregateID,
                occurredAt: try SQLiteValueCodec.date(statement.text(at: 5)),
                recordedAt: try SQLiteValueCodec.date(statement.text(at: 6)),
                payload: payload,
                provenanceID: provenanceID
            ),
            payloadSHA256: try statement.text(at: 8)
        )
    }

    static func decodeProjectedEntity(_ statement: SQLiteRowStatement) throws -> ProjectedEntity {
        ProjectedEntity(
            entityType: try statement.text(at: 0),
            entityID: try SQLiteValueCodec.uuidV7(statement.text(at: 1)),
            revision: Int(statement.int64(at: 2)),
            document: try statement.data(at: 3),
            tombstone: statement.int64(at: 4) == 1,
            sourceEventID: try SQLiteValueCodec.uuidV7(statement.text(at: 5)),
            updatedAt: try SQLiteValueCodec.date(statement.text(at: 6))
        )
    }

    static func decodeSyncOperation(_ statement: SQLiteRowStatement) throws -> PendingSyncOperation {
        let mutationValue = try statement.text(at: 4)
        guard let mutationType = LedgerMutationType(rawValue: mutationValue) else {
            throw SQLiteLedgerError.integrityFailure("Invalid sync mutation type: \(mutationValue)")
        }
        let sensitivityValue = try statement.text(at: 10)
        guard let sensitivity = DataClass(rawValue: sensitivityValue) else {
            throw SQLiteLedgerError.integrityFailure(
                "Invalid sync sensitivity class: \(sensitivityValue)"
            )
        }
        let statusValue = try statement.text(at: 12)
        guard let status = SyncOperationStatus(rawValue: statusValue) else {
            throw SQLiteLedgerError.integrityFailure("Invalid sync operation status: \(statusValue)")
        }
        let baseRevision = statement.optionalText(at: 5).flatMap(Int.init)
        return PendingSyncOperation(
            operationID: try SQLiteValueCodec.uuidV7(statement.text(at: 0)),
            deviceSequence: statement.int64(at: 1),
            entityType: try statement.text(at: 2),
            entityID: try SQLiteValueCodec.uuidV7(statement.text(at: 3)),
            mutationType: mutationType,
            baseRevision: baseRevision,
            payload: try statement.data(at: 6),
            payloadSHA256: try statement.text(at: 7),
            createdAt: try SQLiteValueCodec.date(statement.text(at: 8)),
            idempotencyKey: try statement.text(at: 9),
            sensitivityClass: sensitivity,
            sourceEventID: try SQLiteValueCodec.uuidV7(statement.text(at: 11)),
            status: status,
            attemptCount: Int(statement.int64(at: 13)),
            nextAttemptAt: try statement.optionalText(at: 14).map(SQLiteValueCodec.date),
            lastError: statement.optionalText(at: 15)
        )
    }
}
