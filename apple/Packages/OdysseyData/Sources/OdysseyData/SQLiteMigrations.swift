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
        migrator.registerMigration("v3-life-model-acceptance", foreignKeyChecks: .immediate) { database in
            try applyVersionThree(
                SQLiteSession(database: database),
                appliedAt: clock()
            )
        }
        migrator.registerMigration("v4-local-integration-mirrors", foreignKeyChecks: .immediate) { database in
            try applyVersionFour(
                SQLiteSession(database: database),
                appliedAt: clock()
            )
        }
        migrator.registerMigration("v5-local-application-state", foreignKeyChecks: .immediate) { database in
            try applyVersionFive(
                SQLiteSession(database: database),
                appliedAt: clock()
            )
        }
        migrator.registerMigration("v6-product-telemetry", foreignKeyChecks: .immediate) { database in
            try applyVersionSix(
                SQLiteSession(database: database),
                appliedAt: clock()
            )
        }
        migrator.registerMigration(
            "v7-verified-feature-configuration",
            foreignKeyChecks: .immediate
        ) { database in
            try applyVersionSeven(
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

    private static func applyVersionThree(
        _ connection: SQLiteSession,
        appliedAt: Date
    ) throws {
        try connection.execute(
            """
            CREATE TABLE life_model_acceptance_commands (
                local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
                kind TEXT NOT NULL CHECK (kind IN ('charter', 'life_stage', 'season')),
                version_id TEXT NOT NULL UNIQUE CHECK (length(version_id) = 36),
                logical_id TEXT NOT NULL CHECK (length(logical_id) = 36),
                version_number INTEGER NOT NULL CHECK (version_number >= 1),
                expected_current_version_id TEXT CHECK (
                    expected_current_version_id IS NULL OR length(expected_current_version_id) = 36
                ),
                acceptance_method TEXT NOT NULL CHECK (
                    acceptance_method IN (
                        'owner_authored', 'owner_reviewed_assisted', 'owner_approved_import'
                    )
                ),
                accepted_at TEXT NOT NULL,
                request_body BLOB NOT NULL CHECK (length(request_body) BETWEEN 1 AND 1048576),
                request_sha256 TEXT NOT NULL CHECK (length(request_sha256) = 64),
                document BLOB NOT NULL CHECK (length(document) BETWEEN 1 AND 786432),
                document_sha256 TEXT NOT NULL CHECK (length(document_sha256) = 64),
                created_at TEXT NOT NULL
            ) STRICT;

            CREATE TABLE life_model_acceptance_state (
                event_id TEXT PRIMARY KEY
                    REFERENCES life_model_acceptance_commands(event_id) ON DELETE RESTRICT,
                delivery_status TEXT NOT NULL CHECK (
                    delivery_status IN ('pending', 'retry', 'accepted', 'conflict', 'rejected')
                ),
                attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
                next_attempt_at TEXT,
                last_error_code TEXT,
                last_error_message TEXT,
                actual_current_version_id TEXT CHECK (
                    actual_current_version_id IS NULL OR length(actual_current_version_id) = 36
                ),
                completed_at TEXT,
                updated_at TEXT NOT NULL,
                CHECK (
                    (delivery_status IN ('pending', 'retry') AND completed_at IS NULL)
                    OR (delivery_status IN ('accepted', 'conflict', 'rejected') AND completed_at IS NOT NULL)
                )
            ) STRICT, WITHOUT ROWID;

            CREATE INDEX life_model_acceptance_ready_index
                ON life_model_acceptance_state (delivery_status, next_attempt_at);
            CREATE INDEX life_model_acceptance_kind_index
                ON life_model_acceptance_commands (kind, local_sequence DESC);

            CREATE TABLE life_model_remote_versions (
                version_id TEXT PRIMARY KEY CHECK (length(version_id) = 36),
                kind TEXT NOT NULL CHECK (kind IN ('charter', 'life_stage', 'season')),
                logical_id TEXT NOT NULL CHECK (length(logical_id) = 36),
                version_number INTEGER NOT NULL CHECK (version_number >= 1),
                acceptance_sequence INTEGER NOT NULL CHECK (acceptance_sequence >= 1),
                supersedes_version_id TEXT CHECK (
                    supersedes_version_id IS NULL OR length(supersedes_version_id) = 36
                ),
                status TEXT,
                acceptance_method TEXT NOT NULL CHECK (
                    acceptance_method IN (
                        'owner_authored', 'owner_reviewed_assisted', 'owner_approved_import'
                    )
                ),
                accepted_at TEXT NOT NULL,
                content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
                document BLOB NOT NULL CHECK (length(document) BETWEEN 1 AND 786432),
                document_sha256 TEXT NOT NULL CHECK (length(document_sha256) = 64),
                event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
                ledger_sequence INTEGER NOT NULL UNIQUE CHECK (ledger_sequence >= 1),
                policy_version TEXT NOT NULL CHECK (length(policy_version) BETWEEN 1 AND 200),
                cached_at TEXT NOT NULL,
                UNIQUE (kind, acceptance_sequence),
                UNIQUE (kind, logical_id, version_number)
            ) STRICT, WITHOUT ROWID;

            CREATE INDEX life_model_remote_history_index
                ON life_model_remote_versions (kind, acceptance_sequence DESC);

            CREATE TRIGGER life_model_acceptance_commands_no_update
            BEFORE UPDATE ON life_model_acceptance_commands
            BEGIN
                SELECT RAISE(ABORT, 'life-model acceptance commands are immutable');
            END;

            CREATE TRIGGER life_model_acceptance_commands_no_delete
            BEFORE DELETE ON life_model_acceptance_commands
            BEGIN
                SELECT RAISE(ABORT, 'life-model acceptance commands are immutable');
            END;

            CREATE TRIGGER life_model_remote_versions_no_update
            BEFORE UPDATE ON life_model_remote_versions
            BEGIN
                SELECT RAISE(ABORT, 'cached life-model versions are immutable');
            END;

            CREATE TRIGGER life_model_remote_versions_no_delete
            BEFORE DELETE ON life_model_remote_versions
            BEGIN
                SELECT RAISE(ABORT, 'cached life-model versions are immutable');
            END;
            """
        )
        let migration = try connection.statement(
            """
            INSERT INTO schema_migrations (version, name, applied_at)
            VALUES (3, 'local life-model acceptance queue and immutable history', ?)
            """
        )
        try migration.bind([.text(SQLiteValueCodec.dateString(appliedAt))])
        _ = try migration.step()
        try connection.execute("PRAGMA user_version = 3")
    }

    private static func applyVersionFour(
        _ connection: SQLiteSession,
        appliedAt: Date
    ) throws {
        try connection.execute(
            """
            CREATE TABLE integration_records (
                connector TEXT NOT NULL CHECK (length(connector) BETWEEN 1 AND 100),
                stream TEXT NOT NULL CHECK (length(stream) BETWEEN 1 AND 100),
                external_identifier TEXT NOT NULL
                    CHECK (length(external_identifier) BETWEEN 1 AND 200),
                source_timestamp TEXT NOT NULL,
                document BLOB NOT NULL
                    CHECK (length(document) BETWEEN 1 AND 1048576),
                document_sha256 TEXT NOT NULL CHECK (length(document_sha256) = 64),
                imported_at TEXT NOT NULL,
                PRIMARY KEY (connector, stream, external_identifier)
            ) STRICT, WITHOUT ROWID;

            CREATE INDEX integration_records_source_index
                ON integration_records (connector, stream, source_timestamp);

            CREATE TABLE integration_cursors (
                connector TEXT NOT NULL CHECK (length(connector) BETWEEN 1 AND 100),
                stream TEXT NOT NULL CHECK (length(stream) BETWEEN 1 AND 100),
                cursor BLOB NOT NULL CHECK (length(cursor) BETWEEN 1 AND 65536),
                updated_at TEXT NOT NULL,
                PRIMARY KEY (connector, stream)
            ) STRICT, WITHOUT ROWID;
            """
        )
        let migration = try connection.statement(
            """
            INSERT INTO schema_migrations (version, name, applied_at)
            VALUES (4, 'local-only integration mirrors and cursors', ?)
            """
        )
        try migration.bind([.text(SQLiteValueCodec.dateString(appliedAt))])
        _ = try migration.step()
        try connection.execute("PRAGMA user_version = 4")
    }

    private static func applyVersionFive(
        _ connection: SQLiteSession,
        appliedAt: Date
    ) throws {
        try connection.execute(
            """
            CREATE TABLE local_application_state (
                state_key TEXT PRIMARY KEY CHECK (length(state_key) BETWEEN 1 AND 100),
                schema_version INTEGER NOT NULL CHECK (schema_version >= 1),
                document BLOB NOT NULL CHECK (length(document) BETWEEN 1 AND 65536),
                document_sha256 TEXT NOT NULL CHECK (length(document_sha256) = 64),
                updated_at TEXT NOT NULL
            ) STRICT, WITHOUT ROWID;
            """
        )
        let migration = try connection.statement(
            """
            INSERT INTO schema_migrations (version, name, applied_at)
            VALUES (5, 'hash-verified local application state', ?)
            """
        )
        try migration.bind([.text(SQLiteValueCodec.dateString(appliedAt))])
        _ = try migration.step()
        try connection.execute("PRAGMA user_version = 5")
    }

    private static func applyVersionSix(
        _ connection: SQLiteSession,
        appliedAt: Date
    ) throws {
        try connection.execute(
            """
            CREATE TABLE product_telemetry_preferences (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                document BLOB NOT NULL CHECK (length(document) BETWEEN 1 AND 65536),
                document_sha256 TEXT NOT NULL CHECK (length(document_sha256) = 64),
                updated_at TEXT NOT NULL
            ) STRICT;

            CREATE TABLE product_telemetry_events (
                event_id TEXT PRIMARY KEY CHECK (length(event_id) = 36),
                occurred_at TEXT NOT NULL,
                received_at TEXT NOT NULL,
                event_name TEXT NOT NULL CHECK (length(event_name) BETWEEN 1 AND 100),
                question_id TEXT NOT NULL CHECK (length(question_id) BETWEEN 1 AND 100),
                document BLOB NOT NULL CHECK (length(document) BETWEEN 1 AND 16384),
                document_sha256 TEXT NOT NULL CHECK (length(document_sha256) = 64),
                expires_at TEXT NOT NULL,
                local_only INTEGER NOT NULL CHECK (local_only = 1),
                CHECK (received_at >= occurred_at),
                CHECK (expires_at > occurred_at)
            ) STRICT, WITHOUT ROWID;

            CREATE INDEX product_telemetry_events_time_index
                ON product_telemetry_events (occurred_at, event_id);
            CREATE INDEX product_telemetry_events_question_index
                ON product_telemetry_events (question_id, occurred_at);
            CREATE INDEX product_telemetry_events_expiry_index
                ON product_telemetry_events (expires_at);

            CREATE TRIGGER product_telemetry_events_no_update
            BEFORE UPDATE ON product_telemetry_events
            BEGIN
                SELECT RAISE(ABORT, 'product telemetry events are immutable');
            END;
            """
        )
        let migration = try connection.statement(
            """
            INSERT INTO schema_migrations (version, name, applied_at)
            VALUES (6, 'privacy-controlled local product telemetry', ?)
            """
        )
        try migration.bind([.text(SQLiteValueCodec.dateString(appliedAt))])
        _ = try migration.step()
        try connection.execute("PRAGMA user_version = 6")
    }

    private static func applyVersionSeven(
        _ connection: SQLiteSession,
        appliedAt: Date
    ) throws {
        try connection.execute(
            """
            CREATE TABLE verified_feature_configuration_cache (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                environment TEXT NOT NULL
                    CHECK (environment IN ('local', 'development', 'staging', 'production', 'test')),
                audience TEXT NOT NULL CHECK (length(audience) BETWEEN 3 AND 255),
                configuration_id TEXT NOT NULL CHECK (length(configuration_id) = 36),
                version INTEGER NOT NULL CHECK (version >= 1),
                key_id TEXT NOT NULL CHECK (length(key_id) BETWEEN 1 AND 100),
                envelope_document BLOB NOT NULL
                    CHECK (length(envelope_document) BETWEEN 1 AND 100000),
                envelope_sha256 TEXT NOT NULL CHECK (length(envelope_sha256) = 64),
                payload_sha256 TEXT NOT NULL CHECK (length(payload_sha256) = 64),
                issued_at TEXT NOT NULL,
                not_before TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                verified_at TEXT NOT NULL,
                CHECK (not_before >= issued_at),
                CHECK (expires_at > not_before),
                CHECK (verified_at >= issued_at)
            ) STRICT;

            CREATE TRIGGER verified_feature_configuration_no_rollback
            BEFORE UPDATE ON verified_feature_configuration_cache
            WHEN NEW.version <= OLD.version
            BEGIN
                SELECT RAISE(ABORT, 'verified feature configuration cannot roll back');
            END;
            """
        )
        let migration = try connection.statement(
            """
            INSERT INTO schema_migrations (version, name, applied_at)
            VALUES (7, 'verified signed feature configuration cache', ?)
            """
        )
        try migration.bind([.text(SQLiteValueCodec.dateString(appliedAt))])
        _ = try migration.step()
        try connection.execute("PRAGMA user_version = 7")
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
