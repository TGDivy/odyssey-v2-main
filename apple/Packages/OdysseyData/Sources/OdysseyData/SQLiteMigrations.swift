import Foundation
import GRDB
import OdysseyDomain

extension SQLiteLedgerStore {
    static func makeDatabasePool(
        at databaseURL: URL,
        busyTimeoutMilliseconds: Int
    ) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.busyMode = .timeout(Double(busyTimeoutMilliseconds) / 1_000)
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { database in
            let session = SQLiteSession(database: database)
            try session.execute("PRAGMA foreign_keys = ON")
            try session.execute("PRAGMA synchronous = FULL")
            try session.execute("PRAGMA wal_autocheckpoint = 1000")
            try session.execute("PRAGMA temp_store = MEMORY")
            try session.execute("PRAGMA trusted_schema = OFF")
        }
        let databasePool = try DatabasePool(
            path: databaseURL.path,
            configuration: configuration
        )
        try databasePool.writeWithoutTransaction { database in
            try SQLiteSession(database: database).execute("PRAGMA journal_mode = WAL")
        }
        return databasePool
    }

    static func makeMigrator(
        clock: @escaping @Sendable () -> Date
    ) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-durable-ledger", foreignKeyChecks: .immediate) { database in
            try applyVersionOne(
                SQLiteSession(database: database),
                appliedAt: clock()
            )
        }
        migrator.registerMigration("v2-remote-sync-reconciliation", foreignKeyChecks: .immediate) { database in
            try applyVersionTwo(
                SQLiteSession(database: database),
                appliedAt: clock()
            )
        }
        return migrator
    }

    static func initializeDeviceState(
        _ connection: SQLiteSession,
        deviceID: UUIDv7,
        clock: @Sendable () -> Date
    ) throws {
        let count = try connection.scalarInt("SELECT COUNT(*) FROM sync_state")
        if count == 0 {
            let statement = try connection.statement(
                """
                INSERT INTO sync_state (
                    singleton, device_id, cursor, next_device_sequence, created_at
                ) VALUES (1, ?, 'c_0', 1, ?)
                """
            )
            try statement.bind([
                .text(deviceID.description),
                .text(SQLiteValueCodec.dateString(clock())),
            ])
            _ = try statement.step()
            return
        }
        guard count == 1 else {
            throw SQLiteLedgerError.integrityFailure(
                "The ledger contains \(count) sync-state rows instead of one."
            )
        }
        guard let storedDeviceID = try connection.scalarText(
            "SELECT device_id FROM sync_state WHERE singleton = 1"
        ) else {
            throw SQLiteLedgerError.integrityFailure("The singleton sync state is missing.")
        }
        guard storedDeviceID == deviceID.description else {
            throw SQLiteLedgerError.deviceIdentityMismatch(
                expected: deviceID.description,
                found: storedDeviceID
            )
        }
    }

    static func createPreMigrationBackup(
        databasePool: DatabasePool,
        sourceURL: URL,
        backupDirectory: URL,
        fromVersion: Int,
        clock: @Sendable () -> Date
    ) throws {
        guard backupDirectory.isFileURL else {
            throw SQLiteLedgerError.invalidConfiguration(
                "The pre-migration backup directory must use a file URL."
            )
        }
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        let timestamp = backupTimestamp(clock())
        let destination = backupDirectory.appendingPathComponent(
            "odyssey-pre-migration-v\(fromVersion)-to-v\(currentSchemaVersion)-\(timestamp).sqlite3"
        )
        guard destination.standardizedFileURL != sourceURL.standardizedFileURL else {
            throw SQLiteLedgerError.invalidConfiguration(
                "A pre-migration backup cannot replace the live ledger."
            )
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SQLiteLedgerError.invalidConfiguration(
                "Refusing to overwrite existing pre-migration backup \(destination.lastPathComponent)."
            )
        }
        let destinationDatabase = try DatabaseQueue(path: destination.path)
        try databasePool.backup(to: destinationDatabase)
        try destinationDatabase.close()
        try verifyBackupFile(destination, expectedSchemaVersion: fromVersion)
        applyFileProtectionIfAvailable(to: destination)
    }

    static func verifyBackupFile(
        _ url: URL,
        expectedSchemaVersion: Int
    ) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let backupDatabase = try DatabaseQueue(path: url.path, configuration: configuration)
        try backupDatabase.read { database in
            let backup = SQLiteSession(database: database)
            try backup.execute("PRAGMA foreign_keys = ON")
            guard try backup.scalarText("PRAGMA integrity_check") == "ok" else {
                throw SQLiteLedgerError.integrityFailure(
                    "SQLite integrity_check failed for backup \(url.lastPathComponent)."
                )
            }
            let foreignKeyStatement = try backup.statement("PRAGMA foreign_key_check")
            guard !(try foreignKeyStatement.step()) else {
                throw SQLiteLedgerError.integrityFailure(
                    "SQLite foreign_key_check failed for backup \(url.lastPathComponent)."
                )
            }
            let version = Int(try backup.scalarInt("PRAGMA user_version"))
            guard version == expectedSchemaVersion else {
                throw SQLiteLedgerError.integrityFailure(
                    "Backup schema version \(version) does not match expected version \(expectedSchemaVersion)."
                )
            }
        }
    }

    static func applyFileProtectionIfAvailable(to url: URL) {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func applyVersionOne(
        _ connection: SQLiteSession,
        appliedAt: Date
    ) throws {
        try connection.execute(
            """
            CREATE TABLE schema_migrations (
                version INTEGER PRIMARY KEY CHECK (version >= 1),
                name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
                applied_at TEXT NOT NULL
            ) STRICT;

            CREATE TABLE ledger_entries (
                local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
                event_type TEXT NOT NULL CHECK (length(event_type) BETWEEN 1 AND 100),
                aggregate_type TEXT NOT NULL CHECK (length(aggregate_type) BETWEEN 1 AND 100),
                aggregate_id TEXT NOT NULL CHECK (length(aggregate_id) = 36),
                occurred_at TEXT NOT NULL,
                recorded_at TEXT NOT NULL,
                payload BLOB NOT NULL,
                payload_sha256 TEXT NOT NULL CHECK (length(payload_sha256) = 64),
                provenance_id TEXT NOT NULL CHECK (length(provenance_id) = 36)
            ) STRICT;

            CREATE INDEX ledger_entries_aggregate_index
                ON ledger_entries (aggregate_type, aggregate_id, local_sequence);
            CREATE INDEX ledger_entries_recorded_index
                ON ledger_entries (recorded_at, local_sequence);

            CREATE TABLE projection_events (
                local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                ledger_local_sequence INTEGER NOT NULL UNIQUE
                    REFERENCES ledger_entries(local_sequence) ON DELETE RESTRICT,
                entity_type TEXT NOT NULL CHECK (length(entity_type) BETWEEN 1 AND 100),
                entity_id TEXT NOT NULL CHECK (length(entity_id) = 36),
                revision INTEGER NOT NULL CHECK (revision >= 1),
                mutation_type TEXT NOT NULL CHECK (mutation_type IN ('create', 'update', 'delete')),
                document BLOB NOT NULL,
                document_sha256 TEXT NOT NULL CHECK (length(document_sha256) = 64),
                recorded_at TEXT NOT NULL,
                UNIQUE (entity_type, entity_id, revision)
            ) STRICT;

            CREATE INDEX projection_events_entity_index
                ON projection_events (entity_type, entity_id, revision);

            CREATE TABLE entity_projections (
                entity_type TEXT NOT NULL CHECK (length(entity_type) BETWEEN 1 AND 100),
                entity_id TEXT NOT NULL CHECK (length(entity_id) = 36),
                revision INTEGER NOT NULL CHECK (revision >= 1),
                document BLOB NOT NULL,
                document_sha256 TEXT NOT NULL CHECK (length(document_sha256) = 64),
                tombstone INTEGER NOT NULL CHECK (tombstone IN (0, 1)),
                source_event_id TEXT NOT NULL CHECK (length(source_event_id) = 36),
                updated_at TEXT NOT NULL,
                PRIMARY KEY (entity_type, entity_id)
            ) STRICT, WITHOUT ROWID;

            CREATE INDEX entity_projections_live_index
                ON entity_projections (entity_type, updated_at)
                WHERE tombstone = 0;

            CREATE VIRTUAL TABLE projection_search USING fts5 (
                entity_type UNINDEXED,
                entity_id UNINDEXED,
                search_text,
                tokenize = 'unicode61 remove_diacritics 2'
            );

            CREATE TRIGGER entity_projections_search_insert
            AFTER INSERT ON entity_projections
            WHEN new.tombstone = 0
            BEGIN
                INSERT INTO projection_search (entity_type, entity_id, search_text)
                VALUES (new.entity_type, new.entity_id, CAST(new.document AS TEXT));
            END;

            CREATE TRIGGER entity_projections_search_update
            AFTER UPDATE ON entity_projections
            BEGIN
                DELETE FROM projection_search
                WHERE entity_type = old.entity_type AND entity_id = old.entity_id;
                INSERT INTO projection_search (entity_type, entity_id, search_text)
                SELECT new.entity_type, new.entity_id, CAST(new.document AS TEXT)
                WHERE new.tombstone = 0;
            END;

            CREATE TRIGGER entity_projections_search_delete
            AFTER DELETE ON entity_projections
            BEGIN
                DELETE FROM projection_search
                WHERE entity_type = old.entity_type AND entity_id = old.entity_id;
            END;

            CREATE TABLE sync_operations (
                operation_id TEXT PRIMARY KEY CHECK (length(operation_id) = 36),
                device_sequence INTEGER NOT NULL UNIQUE CHECK (device_sequence >= 1),
                ledger_local_sequence INTEGER NOT NULL UNIQUE
                    REFERENCES ledger_entries(local_sequence) ON DELETE RESTRICT,
                entity_type TEXT NOT NULL CHECK (length(entity_type) BETWEEN 1 AND 100),
                entity_id TEXT NOT NULL CHECK (length(entity_id) = 36),
                mutation_type TEXT NOT NULL CHECK (mutation_type IN ('create', 'update', 'delete')),
                base_revision INTEGER CHECK (base_revision >= 1),
                payload BLOB NOT NULL,
                payload_sha256 TEXT NOT NULL CHECK (length(payload_sha256) = 64),
                created_at TEXT NOT NULL,
                idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 500),
                sensitivity_class TEXT NOT NULL CHECK (
                    sensitivity_class IN (
                        'public', 'private', 'sensitive', 'highly_sensitive',
                        'operational_secret', 'derived_sensitive'
                    )
                ),
                CHECK (
                    (mutation_type = 'create' AND base_revision IS NULL)
                    OR (mutation_type IN ('update', 'delete') AND base_revision IS NOT NULL)
                )
            ) STRICT, WITHOUT ROWID;

            CREATE TABLE sync_operation_state (
                operation_id TEXT PRIMARY KEY
                    REFERENCES sync_operations(operation_id) ON DELETE RESTRICT,
                status TEXT NOT NULL CHECK (
                    status IN ('pending', 'retry', 'accepted', 'rejected', 'conflict')
                ),
                attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
                next_attempt_at TEXT,
                last_error TEXT,
                canonical_revision INTEGER CHECK (canonical_revision >= 1),
                server_change_id INTEGER CHECK (server_change_id >= 1),
                completed_at TEXT,
                CHECK (
                    (status IN ('pending', 'retry') AND completed_at IS NULL)
                    OR (status IN ('accepted', 'rejected', 'conflict') AND completed_at IS NOT NULL)
                )
            ) STRICT, WITHOUT ROWID;

            CREATE INDEX sync_operation_state_pending_index
                ON sync_operation_state (status, next_attempt_at)
                WHERE status IN ('pending', 'retry');

            CREATE TABLE sync_state (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                device_id TEXT NOT NULL UNIQUE CHECK (length(device_id) = 36),
                cursor TEXT NOT NULL DEFAULT 'c_0',
                next_device_sequence INTEGER NOT NULL DEFAULT 1 CHECK (next_device_sequence >= 1),
                last_successful_push_at TEXT,
                last_successful_pull_at TEXT,
                server_schema_version INTEGER CHECK (server_schema_version >= 1),
                created_at TEXT NOT NULL
            ) STRICT;

            CREATE TRIGGER schema_migrations_no_update
            BEFORE UPDATE ON schema_migrations
            BEGIN
                SELECT RAISE(ABORT, 'schema migration history is immutable');
            END;

            CREATE TRIGGER schema_migrations_no_delete
            BEFORE DELETE ON schema_migrations
            BEGIN
                SELECT RAISE(ABORT, 'schema migration history is immutable');
            END;

            CREATE TRIGGER ledger_entries_no_update
            BEFORE UPDATE ON ledger_entries
            BEGIN
                SELECT RAISE(ABORT, 'ledger entries are immutable');
            END;

            CREATE TRIGGER ledger_entries_no_delete
            BEFORE DELETE ON ledger_entries
            BEGIN
                SELECT RAISE(ABORT, 'ledger entries are immutable');
            END;

            CREATE TRIGGER projection_events_no_update
            BEFORE UPDATE ON projection_events
            BEGIN
                SELECT RAISE(ABORT, 'projection events are immutable');
            END;

            CREATE TRIGGER projection_events_no_delete
            BEFORE DELETE ON projection_events
            BEGIN
                SELECT RAISE(ABORT, 'projection events are immutable');
            END;

            CREATE TRIGGER sync_operations_no_update
            BEFORE UPDATE ON sync_operations
            BEGIN
                SELECT RAISE(ABORT, 'sync operations are immutable');
            END;

            CREATE TRIGGER sync_operations_no_delete
            BEFORE DELETE ON sync_operations
            BEGIN
                SELECT RAISE(ABORT, 'sync operations are immutable');
            END;
            """
        )
        let migration = try connection.statement(
            """
            INSERT INTO schema_migrations (version, name, applied_at)
            VALUES (1, 'durable ledger, projections, and sync outbox', ?)
            """
        )
        try migration.bind([.text(SQLiteValueCodec.dateString(appliedAt))])
        _ = try migration.step()
        try connection.execute("PRAGMA user_version = 1")
    }

    private static func applyVersionTwo(
        _ connection: SQLiteSession,
        appliedAt: Date
    ) throws {
        try connection.execute(
            """
            DROP TRIGGER projection_events_no_update;
            DROP TRIGGER projection_events_no_delete;
            DROP INDEX projection_events_entity_index;

            ALTER TABLE projection_events RENAME TO projection_events_v1;

            CREATE TABLE projection_events (
                local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                ledger_local_sequence INTEGER NOT NULL UNIQUE
                    REFERENCES ledger_entries(local_sequence) ON DELETE RESTRICT,
                entity_type TEXT NOT NULL CHECK (length(entity_type) BETWEEN 1 AND 100),
                entity_id TEXT NOT NULL CHECK (length(entity_id) = 36),
                revision INTEGER NOT NULL CHECK (revision >= 1),
                mutation_type TEXT NOT NULL CHECK (mutation_type IN ('create', 'update', 'delete')),
                document BLOB NOT NULL,
                document_sha256 TEXT NOT NULL CHECK (length(document_sha256) = 64),
                recorded_at TEXT NOT NULL,
                source_kind TEXT NOT NULL DEFAULT 'local'
                    CHECK (source_kind IN ('local', 'remote')),
                server_change_id INTEGER CHECK (server_change_id >= 1),
                origin_operation_id TEXT CHECK (
                    origin_operation_id IS NULL OR length(origin_operation_id) = 36
                ),
                CHECK (
                    (source_kind = 'local'
                        AND server_change_id IS NULL
                        AND origin_operation_id IS NULL)
                    OR (source_kind = 'remote'
                        AND server_change_id IS NOT NULL
                        AND origin_operation_id IS NOT NULL)
                )
            ) STRICT;

            INSERT INTO projection_events (
                local_sequence, ledger_local_sequence, entity_type, entity_id,
                revision, mutation_type, document, document_sha256,
                recorded_at, source_kind, server_change_id, origin_operation_id
            )
            SELECT local_sequence, ledger_local_sequence, entity_type, entity_id,
                   revision, mutation_type, document, document_sha256,
                   recorded_at, 'local', NULL, NULL
            FROM projection_events_v1
            ORDER BY local_sequence;

            DROP TABLE projection_events_v1;

            CREATE INDEX projection_events_entity_index
                ON projection_events (entity_type, entity_id, local_sequence);
            CREATE UNIQUE INDEX projection_events_remote_change_index
                ON projection_events (server_change_id)
                WHERE source_kind = 'remote';

            CREATE TRIGGER projection_events_no_update
            BEFORE UPDATE ON projection_events
            BEGIN
                SELECT RAISE(ABORT, 'projection events are immutable');
            END;

            CREATE TRIGGER projection_events_no_delete
            BEFORE DELETE ON projection_events
            BEGIN
                SELECT RAISE(ABORT, 'projection events are immutable');
            END;

            ALTER TABLE sync_operation_state
                ADD COLUMN result_code TEXT;
            ALTER TABLE sync_operation_state
                ADD COLUMN result_message TEXT;
            ALTER TABLE sync_operation_state
                ADD COLUMN result_retryable INTEGER
                    CHECK (result_retryable IS NULL OR result_retryable IN (0, 1));
            ALTER TABLE sync_operation_state
                ADD COLUMN merge_result TEXT;
            ALTER TABLE sync_operation_state
                ADD COLUMN conflict_id TEXT
                    CHECK (conflict_id IS NULL OR length(conflict_id) = 36);

            ALTER TABLE sync_state
                ADD COLUMN server_cursor TEXT NOT NULL DEFAULT 'c_0';
            ALTER TABLE sync_state
                ADD COLUMN receipt_floor INTEGER NOT NULL DEFAULT 0
                    CHECK (receipt_floor >= 0);
            UPDATE sync_state
            SET server_cursor = cursor,
                receipt_floor = CAST(substr(cursor, 3) AS INTEGER);

            CREATE TABLE remote_change_receipts (
                change_id INTEGER PRIMARY KEY CHECK (change_id >= 1),
                projection_event_sequence INTEGER NOT NULL UNIQUE
                    REFERENCES projection_events(local_sequence) ON DELETE RESTRICT,
                canonical_revision INTEGER NOT NULL CHECK (canonical_revision >= 1),
                entity_type TEXT NOT NULL CHECK (length(entity_type) BETWEEN 1 AND 100),
                entity_id TEXT NOT NULL CHECK (length(entity_id) = 36),
                mutation_type TEXT NOT NULL CHECK (mutation_type IN ('create', 'update', 'delete')),
                payload BLOB NOT NULL,
                payload_sha256 TEXT NOT NULL CHECK (length(payload_sha256) = 64),
                tombstone INTEGER NOT NULL CHECK (tombstone IN (0, 1)),
                deletion_epoch INTEGER CHECK (deletion_epoch >= 1),
                merge_result TEXT NOT NULL CHECK (length(merge_result) BETWEEN 1 AND 200),
                origin_device_id TEXT NOT NULL CHECK (length(origin_device_id) = 36),
                origin_operation_id TEXT NOT NULL CHECK (length(origin_operation_id) = 36),
                server_received_at TEXT NOT NULL,
                applied_at TEXT NOT NULL,
                application_kind TEXT NOT NULL CHECK (
                    application_kind IN ('local_reconciliation', 'remote_commit')
                ),
                CHECK (
                    (mutation_type = 'delete'
                        AND tombstone = 1
                        AND deletion_epoch = change_id)
                    OR (mutation_type IN ('create', 'update')
                        AND tombstone = 0
                        AND deletion_epoch IS NULL)
                )
            ) STRICT, WITHOUT ROWID;

            CREATE INDEX remote_change_receipts_entity_index
                ON remote_change_receipts (entity_type, entity_id, change_id);
            CREATE INDEX remote_change_receipts_origin_index
                ON remote_change_receipts (origin_device_id, origin_operation_id);

            CREATE TRIGGER remote_change_receipts_no_update
            BEFORE UPDATE ON remote_change_receipts
            BEGIN
                SELECT RAISE(ABORT, 'remote change receipts are immutable');
            END;

            CREATE TRIGGER remote_change_receipts_no_delete
            BEFORE DELETE ON remote_change_receipts
            BEGIN
                SELECT RAISE(ABORT, 'remote change receipts are immutable');
            END;
            """
        )
        let migration = try connection.statement(
            """
            INSERT INTO schema_migrations (version, name, applied_at)
            VALUES (2, 'remote receipts and atomic sync reconciliation', ?)
            """
        )
        try migration.bind([.text(SQLiteValueCodec.dateString(appliedAt))])
        _ = try migration.step()
        try connection.execute("PRAGMA user_version = 2")
    }

    private static func backupTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: date)
    }
}
