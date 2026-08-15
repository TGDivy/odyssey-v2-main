import Foundation
import GRDB
import OdysseyDomain

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
        let projectionEvents = try readStoredProjectionEvents()
        try verifyProjectionHistory(projectionEvents)
        try verifyRemoteChanges(projectionEvents)
        try verifyProjectionMaterialization(projectionEvents)
        try verifySearchIndex()
        try verifySyncOperations()
        try verifyLifeModelStorage()

        return LedgerIntegrityReport(
            schemaVersion: Self.currentSchemaVersion,
            ledgerEntryCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM ledger_entries")),
            projectionEventCount: projectionEvents.count,
            projectedEntityCount: Int(
                try connection.scalarInt("SELECT COUNT(*) FROM entity_projections")
            ),
            syncOperationCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM sync_operations")),
            remoteChangeReceiptCount: Int(
                try connection.scalarInt("SELECT COUNT(*) FROM remote_change_receipts")
            ),
            lifeModelCommandCount: Int(
                try connection.scalarInt("SELECT COUNT(*) FROM life_model_acceptance_commands")
            ),
            cachedLifeModelVersionCount: Int(
                try connection.scalarInt("SELECT COUNT(*) FROM life_model_remote_versions")
            ),
            checkedAt: configuration.clock()
        )
    }

    public func rebuildAll() async throws {
        try withWrite {
            let projectionEvents = try readStoredProjectionEvents()
            try verifyProjectionHistory(projectionEvents)
            try verifyRemoteChanges(projectionEvents)
            try connection.execute("DELETE FROM entity_projections")
            let identities = Set(projectionEvents.map {
                ProjectionIdentity(
                    entityType: $0.mutation.entityType,
                    entityID: $0.mutation.entityID
                )
            })
            for identity in identities {
                try rebuildMaterializedProjection(for: identity)
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
            "remote_change_receipts_no_update",
            "remote_change_receipts_no_delete",
            "life_model_acceptance_commands_no_update",
            "life_model_acceptance_commands_no_delete",
            "life_model_remote_versions_no_update",
            "life_model_remote_versions_no_delete",
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

    private func verifyLifeModelStorage() throws {
        let commands = try connection.statement(
            """
            SELECT event_id, request_body, request_sha256, document, document_sha256
            FROM life_model_acceptance_commands
            ORDER BY local_sequence
            """
        )
        while try commands.step() {
            let eventID = try commands.text(at: 0)
            let request = try commands.data(at: 1)
            let requestHash = try commands.text(at: 2)
            let document = try commands.data(at: 3)
            let documentHash = try commands.text(at: 4)
            guard SHA256Digest.hexDigest(of: request) == requestHash,
                  SHA256Digest.hexDigest(of: document) == documentHash
            else {
                throw SQLiteLedgerError.integrityFailure(
                    "Stored life-model command hash mismatch for event \(eventID)."
                )
            }
        }
        let versions = try connection.statement(
            """
            SELECT version_id, document, document_sha256
            FROM life_model_remote_versions
            ORDER BY kind, acceptance_sequence
            """
        )
        while try versions.step() {
            let versionID = try versions.text(at: 0)
            let document = try versions.data(at: 1)
            let expectedHash = try versions.text(at: 2)
            guard SHA256Digest.hexDigest(of: document) == expectedHash else {
                throw SQLiteLedgerError.integrityFailure(
                    "Cached life-model document hash mismatch for version \(versionID)."
                )
            }
        }
        let missingReceipts = try connection.scalarInt(
            """
            SELECT COUNT(*)
            FROM life_model_acceptance_state AS state
            LEFT JOIN life_model_remote_versions AS version ON version.event_id = state.event_id
            WHERE state.delivery_status = 'accepted' AND version.version_id IS NULL
            """
        )
        guard missingReceipts == 0 else {
            throw SQLiteLedgerError.integrityFailure(
                "Accepted local life-model commands are missing immutable server receipts."
            )
        }
    }

    private func verifyProjectionHistory(_ events: [StoredProjectionEvent]) throws {
        for event in events {
            guard SHA256Digest.hexDigest(of: event.mutation.document) == event.documentSHA256 else {
                throw SQLiteLedgerError.integrityFailure(
                    "Projection document hash mismatch at sequence \(event.projectionSequence)."
                )
            }
            let remoteMetadataIsValid = event.sourceKind == .remote
                ? event.serverChangeID != nil && event.originOperationID != nil
                : event.serverChangeID == nil && event.originOperationID == nil
            guard remoteMetadataIsValid else {
                throw SQLiteLedgerError.integrityFailure(
                    "Projection source metadata is inconsistent at sequence \(event.projectionSequence)."
                )
            }
        }
    }

    private func verifyProjectionMaterialization(
        _ events: [StoredProjectionEvent]
    ) throws {
        let grouped = Dictionary(grouping: events) {
            ProjectionKey(
                entityType: $0.mutation.entityType,
                entityID: $0.mutation.entityID.description
            )
        }
        var expected: [ProjectionKey: StoredProjectionEvent] = [:]
        for (key, history) in grouped {
            expected[key] = Self.selectMaterializedProjection(from: history)
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
        guard Self.isValidCursor(state.serverCursor),
              let cursor = Self.cursorValue(state.cursor),
              let serverCursor = Self.cursorValue(state.serverCursor),
              state.receiptFloor >= 0,
              state.receiptFloor <= cursor,
              cursor <= serverCursor
        else {
            throw SQLiteLedgerError.integrityFailure(
                "Stored applied/server cursors or the receipt floor are inconsistent."
            )
        }
    }

    private func verifyRemoteChanges(_ events: [StoredProjectionEvent]) throws {
        let receipts = try readAllRemoteChangeReceipts()
        let state = try readSyncState()
        guard let cursor = Self.cursorValue(state.cursor) else {
            throw SQLiteLedgerError.integrityFailure("Stored sync cursor is invalid.")
        }
        let expectedReceiptCount = cursor - state.receiptFloor
        guard expectedReceiptCount >= 0, Int64(receipts.count) == expectedReceiptCount else {
            throw SQLiteLedgerError.integrityFailure(
                "Remote receipt continuity does not match the applied cursor."
            )
        }
        for (offset, receipt) in receipts.enumerated() {
            guard receipt.change.changeID == state.receiptFloor + Int64(offset) + 1,
                  receipt.payloadSHA256 == SHA256Digest.hexDigest(of: receipt.change.payload)
            else {
                throw SQLiteLedgerError.integrityFailure(
                    "Remote receipt change identifiers or payload hashes are discontinuous."
                )
            }
            if receipt.applicationKind == .localReconciliation,
               receipt.change.originDeviceID != state.deviceID
            {
                throw SQLiteLedgerError.integrityFailure(
                    "A local reconciliation receipt belongs to another device."
                )
            }
        }

        let remoteEvents = events.filter { $0.sourceKind == .remote }
        guard remoteEvents.count == receipts.count else {
            throw SQLiteLedgerError.integrityFailure(
                "Remote projection events and immutable receipts diverge."
            )
        }
        let eventsByChangeID = Dictionary(
            uniqueKeysWithValues: remoteEvents.compactMap { event in
                event.serverChangeID.map { ($0, event) }
            }
        )
        guard eventsByChangeID.count == remoteEvents.count else {
            throw SQLiteLedgerError.integrityFailure(
                "Remote projection events contain duplicate or missing change identifiers."
            )
        }
        for receipt in receipts {
            guard let event = eventsByChangeID[receipt.change.changeID],
                  event.projectionSequence == receipt.projectionEventSequence,
                  event.sourceEventID == receipt.ledgerEventID,
                  event.mutation.entityType == receipt.change.entityType,
                  event.mutation.entityID == receipt.change.entityID,
                  event.mutation.revision == receipt.change.canonicalRevision,
                  event.mutation.mutationType == receipt.change.mutationType,
                  event.mutation.document == receipt.change.payload,
                  event.documentSHA256 == receipt.payloadSHA256,
                  event.recordedAt == receipt.appliedAt,
                  event.originOperationID == receipt.change.originOperationID
            else {
                throw SQLiteLedgerError.integrityFailure(
                    "A remote projection event does not match its immutable receipt."
                )
            }
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
        try readStoredProjectionEvents().map { event in
            ProjectionEventExport(
                localSequence: event.projectionSequence,
                ledgerLocalSequence: event.ledgerLocalSequence,
                sourceEventID: event.sourceEventID,
                mutation: event.mutation,
                documentSHA256: event.documentSHA256,
                recordedAt: event.recordedAt,
                sourceKind: event.sourceKind,
                serverChangeID: event.serverChangeID,
                originOperationID: event.originOperationID
            )
        }
    }

    private func readExportArchive(exportedAt: Date) throws -> LedgerExportArchive {
        LedgerExportArchive(
            exportFormatVersion: 3,
            schemaVersion: Self.currentSchemaVersion,
            exportedAt: exportedAt,
            binaryEncoding: "base64",
            migrations: try readMigrationExports(),
            syncState: try readSyncState(),
            ledgerEntries: try readAllLedgerEntries(),
            projectionEvents: try readProjectionEvents(),
            currentProjections: try readCurrentProjections(),
            syncOperations: try readSyncOperationExports(),
            remoteChangeReceipts: try readAllRemoteChangeReceipts(),
            lifeModelAcceptances: try allLifeModelAcceptancesInCurrentTransaction(),
            cachedLifeModelVersions: try allCachedLifeModelVersionsInCurrentTransaction()
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
                   state.canonical_revision, state.server_change_id, state.completed_at,
                   state.result_code, state.result_message, state.result_retryable,
                   state.merge_result, state.conflict_id
            FROM sync_operations AS operation
            JOIN sync_operation_state AS state USING (operation_id)
            JOIN ledger_entries AS ledger
              ON ledger.local_sequence = operation.ledger_local_sequence
            ORDER BY operation.device_sequence
            """
        )
        var operations: [SyncOperationExport] = []
        while try statement.step() {
            let conflictID: UUIDv7?
            if let conflictValue = statement.optionalText(at: 23) {
                conflictID = try SQLiteValueCodec.uuidV7(conflictValue)
            } else {
                conflictID = nil
            }
            operations.append(
                SyncOperationExport(
                    operation: try Self.decodeSyncOperation(statement),
                    canonicalRevision: statement.optionalText(at: 16).flatMap(Int.init),
                    serverChangeID: statement.optionalText(at: 17).flatMap(Int64.init),
                    completedAt: try statement.optionalText(at: 18).map(SQLiteValueCodec.date),
                    resultCode: statement.optionalText(at: 19),
                    resultMessage: statement.optionalText(at: 20),
                    resultRetryable: statement.optionalText(at: 21).map { $0 == "1" },
                    mergeResult: statement.optionalText(at: 22),
                    conflictID: conflictID
                )
            )
        }
        return operations
    }

    private func readAllRemoteChangeReceipts() throws -> [RemoteChangeReceipt] {
        let statement = try connection.statement(
            """
            SELECT receipt.change_id, receipt.canonical_revision,
                   receipt.entity_type, receipt.entity_id, receipt.mutation_type,
                   receipt.payload, receipt.payload_sha256, receipt.tombstone,
                   receipt.deletion_epoch, receipt.merge_result,
                   receipt.origin_device_id, receipt.origin_operation_id,
                   receipt.server_received_at, receipt.applied_at,
                   receipt.application_kind, receipt.projection_event_sequence,
                   ledger.event_id
            FROM remote_change_receipts AS receipt
            JOIN projection_events AS projection
              ON projection.local_sequence = receipt.projection_event_sequence
            JOIN ledger_entries AS ledger
              ON ledger.local_sequence = projection.ledger_local_sequence
            ORDER BY receipt.change_id
            """
        )
        var receipts: [RemoteChangeReceipt] = []
        while try statement.step() {
            receipts.append(try Self.decodeRemoteChangeReceipt(statement))
        }
        return receipts
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
