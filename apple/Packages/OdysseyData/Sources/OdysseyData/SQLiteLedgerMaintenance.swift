import Foundation
import GRDB

extension SQLiteLedgerStore {
    public func verifyIntegrity() async throws {
        _ = try integrityReport()
    }

    public func integrityReport() throws -> LedgerIntegrityReport {
        try withRead {
            try readIntegrityReport()
        }
    }

    private func readIntegrityReport() throws -> LedgerIntegrityReport {
        guard try connection.scalarText("PRAGMA integrity_check") == "ok" else {
            throw SQLiteLedgerError.integrityFailure("SQLite integrity_check did not return ok.")
        }
        let foreignKeyStatement = try connection.statement("PRAGMA foreign_key_check")
        guard !(try foreignKeyStatement.step()) else {
            throw SQLiteLedgerError.integrityFailure("SQLite foreign_key_check found a violation.")
        }
        guard Int(try connection.scalarInt("PRAGMA user_version")) == Self.currentSchemaVersion else {
            throw SQLiteLedgerError.integrityFailure("SQLite user_version does not match the package schema.")
        }
        try verifyRequiredPragmas()
        try verifyImmutableTriggers()
        try verifyLedgerHashes()
        let projectionEvents = try readProjectionEvents()
        try verifyProjectionHistory(projectionEvents)
        try verifyProjectionMaterialization(projectionEvents)
        try verifySearchIndex()
        try verifySyncOperations()

        return LedgerIntegrityReport(
            schemaVersion: Self.currentSchemaVersion,
            ledgerEntryCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM ledger_entries")),
            projectionEventCount: projectionEvents.count,
            projectedEntityCount: Int(
                try connection.scalarInt("SELECT COUNT(*) FROM entity_projections")
            ),
            syncOperationCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM sync_operations")),
            checkedAt: configuration.clock()
        )
    }

    public func rebuildAll() async throws {
        try withWrite {
            let projectionEvents = try readProjectionEvents()
            try verifyProjectionHistory(projectionEvents)
            try connection.execute("DELETE FROM entity_projections")
            for event in projectionEvents {
                try materializeProjectionEvent(event)
            }
            try verifyProjectionMaterialization(projectionEvents)
        }
    }

    public func createBackup(at destination: URL) async throws -> URL {
        guard destination.isFileURL else {
            throw SQLiteLedgerError.invalidConfiguration("A local backup must use a file URL.")
        }
        guard destination.standardizedFileURL != configuration.databaseURL.standardizedFileURL else {
            throw SQLiteLedgerError.invalidConfiguration("A backup cannot replace the live ledger.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SQLiteLedgerError.invalidConfiguration(
                "Refusing to overwrite existing backup \(destination.lastPathComponent)."
            )
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try integrityReport()
        let destinationDatabase = try DatabaseQueue(path: destination.path)
        try databasePool.backup(to: destinationDatabase)
        try destinationDatabase.close()
        try Self.verifyBackupFile(
            destination,
            expectedSchemaVersion: Self.currentSchemaVersion
        )
        let verificationStore = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: destination,
                deviceID: configuration.deviceID,
                preMigrationBackupDirectory: destination.deletingLastPathComponent(),
                busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds,
                clock: configuration.clock
            )
        )
        _ = try verificationStore.integrityReport()
        Self.applyFileProtectionIfAvailable(to: destination)
        return destination
    }

    public func exportAll(to destination: URL) async throws -> URL {
        guard destination.isFileURL else {
            throw SQLiteLedgerError.invalidConfiguration("A local export must use a file URL.")
        }
        let outputURL: URL
        var isDirectory: ObjCBool = false
        if destination.hasDirectoryPath
            || (FileManager.default.fileExists(
                atPath: destination.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue)
        {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            outputURL = destination.appendingPathComponent(
                "odyssey-ledger-export-\(Self.exportTimestamp(configuration.clock())).json"
            )
        } else {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            outputURL = destination
        }
        guard outputURL.standardizedFileURL != configuration.databaseURL.standardizedFileURL else {
            throw SQLiteLedgerError.invalidConfiguration("An export cannot replace the live ledger.")
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SQLiteLedgerError.invalidConfiguration(
                "Refusing to overwrite existing export \(outputURL.lastPathComponent)."
            )
        }

        let archive = try withRead {
            try readExportArchive(exportedAt: configuration.clock())
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SQLiteValueCodec.dateString(date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)
        try data.write(to: outputURL, options: .atomic)
        Self.applyFileProtectionIfAvailable(to: outputURL)
        return outputURL
    }

    private func verifyRequiredPragmas() throws {
        guard try connection.scalarInt("PRAGMA foreign_keys") == 1 else {
            throw SQLiteLedgerError.integrityFailure("SQLite foreign-key enforcement is disabled.")
        }
        guard try connection.scalarText("PRAGMA journal_mode")?.lowercased() == "wal" else {
            throw SQLiteLedgerError.integrityFailure("The live ledger is not in WAL mode.")
        }
        guard try connection.scalarInt("PRAGMA synchronous") == 2 else {
            throw SQLiteLedgerError.integrityFailure("The live ledger is not using FULL synchronous mode.")
        }
    }

    private func verifyImmutableTriggers() throws {
        let requiredTriggers = [
            "schema_migrations_no_update",
            "schema_migrations_no_delete",
            "ledger_entries_no_update",
            "ledger_entries_no_delete",
            "projection_events_no_update",
            "projection_events_no_delete",
            "sync_operations_no_update",
            "sync_operations_no_delete",
            "entity_projections_search_insert",
            "entity_projections_search_update",
            "entity_projections_search_delete",
        ]
        let statement = try connection.statement(
            "SELECT name FROM sqlite_schema WHERE type = 'trigger' ORDER BY name"
        )
        var existing: Set<String> = []
        while try statement.step() {
            existing.insert(try statement.text(at: 0))
        }
        let missing = requiredTriggers.filter { !existing.contains($0) }
        guard missing.isEmpty else {
            throw SQLiteLedgerError.integrityFailure(
                "Required immutability triggers are missing: \(missing.joined(separator: ", "))."
            )
        }
    }

    private func verifyLedgerHashes() throws {
        let statement = try connection.statement(
            "SELECT event_id, payload, payload_sha256 FROM ledger_entries ORDER BY local_sequence"
        )
        while try statement.step() {
            let eventID = try statement.text(at: 0)
            let payload = try statement.data(at: 1)
            let expectedHash = try statement.text(at: 2)
            guard SHA256Digest.hexDigest(of: payload) == expectedHash else {
                throw SQLiteLedgerError.integrityFailure(
                    "Ledger payload hash mismatch for event \(eventID)."
                )
            }
        }
    }

    private func verifyProjectionHistory(_ events: [ProjectionEventExport]) throws {
        var state: [ProjectionKey: (revision: Int, tombstone: Bool)] = [:]
        for event in events {
            guard SHA256Digest.hexDigest(of: event.mutation.document) == event.documentSHA256 else {
                throw SQLiteLedgerError.integrityFailure(
                    "Projection document hash mismatch at sequence \(event.localSequence)."
                )
            }
            let key = ProjectionKey(
                entityType: event.mutation.entityType,
                entityID: event.mutation.entityID.description
            )
            let current = state[key]
            switch event.mutation.mutationType {
            case .create:
                guard current == nil, event.mutation.revision == 1 else {
                    throw SQLiteLedgerError.integrityFailure(
                        "Projection create history is invalid for \(key.description)."
                    )
                }
            case .update, .delete:
                guard let current,
                      !current.tombstone,
                      event.mutation.revision == current.revision + 1
                else {
                    throw SQLiteLedgerError.integrityFailure(
                        "Projection revision history is invalid for \(key.description)."
                    )
                }
            }
            state[key] = (
                revision: event.mutation.revision,
                tombstone: event.mutation.mutationType == .delete
            )
        }
    }

    private func verifyProjectionMaterialization(
        _ events: [ProjectionEventExport]
    ) throws {
        var expected: [ProjectionKey: ProjectionEventExport] = [:]
        for event in events {
            expected[
                ProjectionKey(
                    entityType: event.mutation.entityType,
                    entityID: event.mutation.entityID.description
                )
            ] = event
        }
        guard Int(try connection.scalarInt("SELECT COUNT(*) FROM entity_projections")) == expected.count else {
            throw SQLiteLedgerError.integrityFailure(
                "Materialized projection count does not match projection history."
            )
        }
        let statement = try connection.statement(
            """
            SELECT entity_type, entity_id, revision, document, document_sha256,
                   tombstone, source_event_id, updated_at
            FROM entity_projections
            ORDER BY entity_type, entity_id
            """
        )
        while try statement.step() {
            let key = ProjectionKey(
                entityType: try statement.text(at: 0),
                entityID: try statement.text(at: 1)
            )
            guard let event = expected[key] else {
                throw SQLiteLedgerError.integrityFailure(
                    "Materialized projection has no history for \(key.description)."
                )
            }
            let document = try statement.data(at: 3)
            guard Int(statement.int64(at: 2)) == event.mutation.revision,
                  document == event.mutation.document,
                  try statement.text(at: 4) == event.documentSHA256,
                  (statement.int64(at: 5) == 1) == (event.mutation.mutationType == .delete),
                  try statement.text(at: 6) == event.sourceEventID.description,
                  try SQLiteValueCodec.date(statement.text(at: 7)) == event.recordedAt
            else {
                throw SQLiteLedgerError.integrityFailure(
                    "Materialized projection diverges from history for \(key.description)."
                )
            }
        }
    }

    private func verifySyncOperations() throws {
        let operationStatement = try connection.statement(
            """
            SELECT operation_id, payload, payload_sha256
            FROM sync_operations
            ORDER BY device_sequence
            """
        )
        var operationCount = 0
        while try operationStatement.step() {
            operationCount += 1
            let operationID = try operationStatement.text(at: 0)
            let payload = try operationStatement.data(at: 1)
            let expectedHash = try operationStatement.text(at: 2)
            guard SHA256Digest.hexDigest(of: payload) == expectedHash else {
                throw SQLiteLedgerError.integrityFailure(
                    "Sync payload hash mismatch for operation \(operationID)."
                )
            }
        }
        let maximumSequence = try connection.scalarInt(
            "SELECT COALESCE(MAX(device_sequence), 0) FROM sync_operations"
        )
        guard try connection.scalarInt("SELECT COUNT(*) FROM sync_operation_state") == Int64(operationCount) else {
            throw SQLiteLedgerError.integrityFailure(
                "Sync operation records and mutable state counts diverge."
            )
        }
        let state = try readSyncState()
        guard state.nextDeviceSequence == maximumSequence + 1 else {
            throw SQLiteLedgerError.integrityFailure(
                "Next device sequence does not immediately follow retained operations."
            )
        }
        guard Self.isValidCursor(state.cursor) else {
            throw SQLiteLedgerError.integrityFailure("Stored sync cursor is invalid.")
        }
    }

    private func verifySearchIndex() throws {
        let liveProjectionCount = try connection.scalarInt(
            "SELECT COUNT(*) FROM entity_projections WHERE tombstone = 0"
        )
        guard try connection.scalarInt("SELECT COUNT(*) FROM projection_search") == liveProjectionCount else {
            throw SQLiteLedgerError.integrityFailure(
                "FTS5 search row count does not match live projections."
            )
        }
        let mismatchCount = try connection.scalarInt(
            """
            SELECT COUNT(*)
            FROM entity_projections AS projection
            LEFT JOIN projection_search AS search
              ON search.entity_type = projection.entity_type
             AND search.entity_id = projection.entity_id
            WHERE projection.tombstone = 0
              AND (
                search.rowid IS NULL
                OR search.search_text != CAST(projection.document AS TEXT)
              )
            """
        )
        guard mismatchCount == 0 else {
            throw SQLiteLedgerError.integrityFailure(
                "FTS5 search content diverges from live projections."
            )
        }
    }

    private func readProjectionEvents() throws -> [ProjectionEventExport] {
        let statement = try connection.statement(
            """
            SELECT projection.local_sequence, ledger.event_id,
                   projection.entity_type, projection.entity_id, projection.revision,
                   projection.mutation_type, projection.document,
                   projection.document_sha256, projection.recorded_at
            FROM projection_events AS projection
            JOIN ledger_entries AS ledger
              ON ledger.local_sequence = projection.ledger_local_sequence
            ORDER BY projection.local_sequence
            """
        )
        var events: [ProjectionEventExport] = []
        while try statement.step() {
            let mutationValue = try statement.text(at: 5)
            guard let mutationType = LedgerMutationType(rawValue: mutationValue) else {
                throw SQLiteLedgerError.integrityFailure(
                    "Invalid projection mutation type: \(mutationValue)"
                )
            }
            events.append(
                ProjectionEventExport(
                    localSequence: statement.int64(at: 0),
                    sourceEventID: try SQLiteValueCodec.uuidV7(statement.text(at: 1)),
                    mutation: ProjectionMutation(
                        entityType: try statement.text(at: 2),
                        entityID: try SQLiteValueCodec.uuidV7(statement.text(at: 3)),
                        revision: Int(statement.int64(at: 4)),
                        mutationType: mutationType,
                        document: try statement.data(at: 6)
                    ),
                    documentSHA256: try statement.text(at: 7),
                    recordedAt: try SQLiteValueCodec.date(statement.text(at: 8))
                )
            )
        }
        return events
    }

    private func materializeProjectionEvent(_ event: ProjectionEventExport) throws {
        let statement = try connection.statement(
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
        try statement.bind([
            .text(event.mutation.entityType),
            .text(event.mutation.entityID.description),
            .integer(Int64(event.mutation.revision)),
            .blob(event.mutation.document),
            .text(event.documentSHA256),
            .integer(event.mutation.mutationType == .delete ? 1 : 0),
            .text(event.sourceEventID.description),
            .text(SQLiteValueCodec.dateString(event.recordedAt)),
        ])
        _ = try statement.step()
    }

    private func readExportArchive(exportedAt: Date) throws -> LedgerExportArchive {
        LedgerExportArchive(
            exportFormatVersion: 1,
            schemaVersion: Self.currentSchemaVersion,
            exportedAt: exportedAt,
            binaryEncoding: "base64",
            migrations: try readMigrationExports(),
            syncState: try readSyncState(),
            ledgerEntries: try readAllLedgerEntries(),
            projectionEvents: try readProjectionEvents(),
            currentProjections: try readCurrentProjections(),
            syncOperations: try readSyncOperationExports()
        )
    }

    private func readMigrationExports() throws -> [LedgerMigrationExport] {
        let statement = try connection.statement(
            "SELECT version, name, applied_at FROM schema_migrations ORDER BY version"
        )
        var migrations: [LedgerMigrationExport] = []
        while try statement.step() {
            migrations.append(
                LedgerMigrationExport(
                    version: Int(statement.int64(at: 0)),
                    name: try statement.text(at: 1),
                    appliedAt: try SQLiteValueCodec.date(statement.text(at: 2))
                )
            )
        }
        return migrations
    }

    private func readAllLedgerEntries() throws -> [StoredLedgerEntry] {
        let statement = try connection.statement(
            """
            SELECT local_sequence, event_id, event_type, aggregate_type, aggregate_id,
                   occurred_at, recorded_at, payload, payload_sha256, provenance_id
            FROM ledger_entries
            ORDER BY local_sequence
            """
        )
        var entries: [StoredLedgerEntry] = []
        while try statement.step() {
            entries.append(try Self.decodeLedgerEntry(statement))
        }
        return entries
    }

    private func readCurrentProjections() throws -> [ProjectedEntity] {
        let statement = try connection.statement(
            """
            SELECT entity_type, entity_id, revision, document, tombstone,
                   source_event_id, updated_at
            FROM entity_projections
            ORDER BY entity_type, entity_id
            """
        )
        var projections: [ProjectedEntity] = []
        while try statement.step() {
            projections.append(try Self.decodeProjectedEntity(statement))
        }
        return projections
    }

    private func readSyncOperationExports() throws -> [SyncOperationExport] {
        let statement = try connection.statement(
            """
            SELECT operation.operation_id, operation.device_sequence,
                   operation.entity_type, operation.entity_id, operation.mutation_type,
                   operation.base_revision, operation.payload, operation.payload_sha256,
                   operation.created_at, operation.idempotency_key,
                   operation.sensitivity_class, ledger.event_id,
                   state.status, state.attempt_count, state.next_attempt_at, state.last_error,
                   state.canonical_revision, state.server_change_id, state.completed_at
            FROM sync_operations AS operation
            JOIN sync_operation_state AS state USING (operation_id)
            JOIN ledger_entries AS ledger
              ON ledger.local_sequence = operation.ledger_local_sequence
            ORDER BY operation.device_sequence
            """
        )
        var operations: [SyncOperationExport] = []
        while try statement.step() {
            operations.append(
                SyncOperationExport(
                    operation: try Self.decodeSyncOperation(statement),
                    canonicalRevision: statement.optionalText(at: 16).flatMap(Int.init),
                    serverChangeID: statement.optionalText(at: 17).flatMap(Int64.init),
                    completedAt: try statement.optionalText(at: 18).map(SQLiteValueCodec.date)
                )
            )
        }
        return operations
    }

    private static func exportTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: date)
    }
}

private struct ProjectionKey: Hashable {
    let entityType: String
    let entityID: String

    var description: String {
        "\(entityType)/\(entityID)"
    }
}
