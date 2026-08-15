import Foundation
import OdysseyDomain

extension SQLiteLedgerStore {
    public func applyPushResult(_ batch: SyncPushResultBatch) async throws {
        try Self.validate(batch)
        try withWrite {
            var affectedEntities: Set<ProjectionIdentity> = []
            for acceptance in batch.accepted {
                try applyAcceptance(acceptance, completedAt: batch.completedAt)
            }
            for rejection in batch.rejected {
                try applyRejection(rejection, completedAt: batch.completedAt)
                if !rejection.retryable,
                   let operation = try readLocalOperationMetadata(operationID: rejection.operationID)
                {
                    affectedEntities.insert(
                        ProjectionIdentity(
                            entityType: operation.entityType,
                            entityID: operation.entityID
                        )
                    )
                }
            }
            for conflict in batch.conflicts {
                try applyConflict(conflict, completedAt: batch.completedAt)
                if let operation = try readLocalOperationMetadata(operationID: conflict.operationID) {
                    affectedEntities.insert(
                        ProjectionIdentity(
                            entityType: operation.entityType,
                            entityID: operation.entityID
                        )
                    )
                }
            }
            for identity in affectedEntities {
                try rebuildMaterializedProjection(for: identity)
            }
            try updateSyncState(
                deviceCursor: nil,
                serverCursor: batch.nextServerCursor,
                serverSchemaVersion: batch.serverSchemaVersion,
                pushAt: batch.completedAt,
                pullAt: nil
            )
        }
    }

    public func applyPullPage(
        _ page: RemoteSyncPage
    ) async throws -> RemoteChangeApplicationReport {
        try Self.validate(page)
        return try withWrite {
            let state = try readSyncState()
            guard let currentCursorValue = Self.cursorValue(state.cursor),
                  let currentServerCursorValue = Self.cursorValue(state.serverCursor),
                  let nextCursorValue = Self.cursorValue(page.nextCursor)
            else {
                throw SQLiteLedgerError.integrityFailure("Stored sync cursors are invalid.")
            }

            var workingCursorValue = currentCursorValue
            var appliedCount = 0
            var duplicateCount = 0
            var localReconciliationCount = 0
            var remoteCommitCount = 0
            var affectedEntities: Set<ProjectionIdentity> = []

            for change in page.changes {
                if change.changeID <= currentCursorValue {
                    guard let receipt = try readRemoteChangeReceipt(changeID: change.changeID),
                          Self.receipt(receipt, matches: change)
                    else {
                        throw SQLiteLedgerError.invalidRemoteChange(
                            "A replayed server change does not match its immutable receipt."
                        )
                    }
                    duplicateCount += 1
                    continue
                }

                guard change.changeID == workingCursorValue + 1 else {
                    throw SQLiteLedgerError.invalidRemoteChange(
                        "Remote changes must continue immediately after the applied cursor."
                    )
                }
                guard try readRemoteChangeReceipt(changeID: change.changeID) == nil else {
                    throw SQLiteLedgerError.integrityFailure(
                        "A remote receipt exists beyond the applied cursor."
                    )
                }

                let applicationKind = try insertRemoteChange(
                    change,
                    localDeviceID: state.deviceID,
                    appliedAt: page.completedAt
                )
                switch applicationKind {
                case .localReconciliation:
                    localReconciliationCount += 1
                case .remoteCommit:
                    remoteCommitCount += 1
                }
                affectedEntities.insert(
                    ProjectionIdentity(
                        entityType: change.entityType,
                        entityID: change.entityID
                    )
                )
                workingCursorValue = change.changeID
                appliedCount += 1
            }

            guard nextCursorValue <= workingCursorValue else {
                throw SQLiteLedgerError.invalidRemoteChange(
                    "The pull cursor cannot skip changes absent from the response."
                )
            }
            if appliedCount > 0, nextCursorValue != workingCursorValue {
                throw SQLiteLedgerError.invalidRemoteChange(
                    "The pull cursor must identify the final applied change."
                )
            }

            for identity in affectedEntities {
                try rebuildMaterializedProjection(for: identity)
            }

            let finalCursorValue = max(currentCursorValue, nextCursorValue)
            let serverCursorValue = max(currentServerCursorValue, finalCursorValue)
            try updateSyncState(
                deviceCursor: "c_\(finalCursorValue)",
                serverCursor: "c_\(serverCursorValue)",
                serverSchemaVersion: page.serverSchemaVersion,
                pushAt: nil,
                pullAt: page.completedAt
            )

            return RemoteChangeApplicationReport(
                appliedCount: appliedCount,
                duplicateCount: duplicateCount,
                localReconciliationCount: localReconciliationCount,
                remoteCommitCount: remoteCommitCount,
                finalCursor: "c_\(finalCursorValue)",
                hasMore: page.hasMore
            )
        }
    }

    public func remoteChangeReceipts(
        after changeID: Int64? = nil,
        limit: Int = 500
    ) async throws -> [RemoteChangeReceipt] {
        guard (1 ... 10_000).contains(limit), (changeID ?? 0) >= 0 else {
            throw SQLiteLedgerError.invalidConfiguration(
                "Remote receipt pages require a nonnegative cursor and 1 through 10,000 rows."
            )
        }
        return try withRead {
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
                WHERE receipt.change_id > ?
                ORDER BY receipt.change_id
                LIMIT ?
                """
            )
            try statement.bind([
                .integer(changeID ?? 0),
                .integer(Int64(limit)),
            ])
            var receipts: [RemoteChangeReceipt] = []
            while try statement.step() {
                receipts.append(try Self.decodeRemoteChangeReceipt(statement))
            }
            return receipts
        }
    }

    private func applyAcceptance(
        _ acceptance: SyncPushAcceptance,
        completedAt: Date
    ) throws {
        let state = try readOperationResultState(operationID: acceptance.operationID)
        if state.status == .accepted {
            guard state.canonicalRevision == acceptance.canonicalRevision,
                  state.serverChangeID == acceptance.serverChangeID,
                  state.mergeResult == acceptance.mergeResult
            else {
                throw SQLiteLedgerError.integrityFailure(
                    "An accepted operation was replayed with a different server result."
                )
            }
            return
        }
        guard state.status == .pending || state.status == .retry else {
            throw SQLiteLedgerError.invalidSyncResult(
                "Only pending operations can transition to accepted."
            )
        }
        let statement = try connection.statement(
            """
            UPDATE sync_operation_state
            SET status = 'accepted', attempt_count = attempt_count + 1,
                next_attempt_at = NULL, last_error = NULL,
                canonical_revision = ?, server_change_id = ?, completed_at = ?,
                result_code = NULL, result_message = NULL, result_retryable = NULL,
                merge_result = ?, conflict_id = NULL
            WHERE operation_id = ? AND status IN ('pending', 'retry')
            """
        )
        try statement.bind([
            .integer(Int64(acceptance.canonicalRevision)),
            .integer(acceptance.serverChangeID),
            .text(SQLiteValueCodec.dateString(completedAt)),
            .text(acceptance.mergeResult),
            .text(acceptance.operationID.description),
        ])
        _ = try statement.step()
        guard try connection.scalarInt("SELECT changes()") == 1 else {
            throw SQLiteLedgerError.integrityFailure(
                "Accepted operation state lost transaction isolation."
            )
        }
    }

    private func applyRejection(
        _ rejection: SyncPushRejection,
        completedAt: Date
    ) throws {
        let state = try readOperationResultState(operationID: rejection.operationID)
        if !rejection.retryable, state.status == .rejected {
            guard state.resultCode == rejection.code,
                  state.resultMessage == rejection.message,
                  state.resultRetryable == false
            else {
                throw SQLiteLedgerError.integrityFailure(
                    "A rejected operation was replayed with a different server result."
                )
            }
            return
        }
        guard state.status == .pending || state.status == .retry else {
            throw SQLiteLedgerError.invalidSyncResult(
                "Only pending operations can transition to retry or rejected."
            )
        }
        let status: SyncOperationStatus = rejection.retryable ? .retry : .rejected
        let statement = try connection.statement(
            """
            UPDATE sync_operation_state
            SET status = ?, attempt_count = attempt_count + 1,
                next_attempt_at = ?, last_error = ?,
                canonical_revision = NULL, server_change_id = NULL,
                completed_at = ?, result_code = ?, result_message = ?,
                result_retryable = ?, merge_result = NULL, conflict_id = NULL
            WHERE operation_id = ? AND status IN ('pending', 'retry')
            """
        )
        try statement.bind([
            .text(status.rawValue),
            rejection.nextAttemptAt.map { .text(SQLiteValueCodec.dateString($0)) } ?? .null,
            .text(rejection.message),
            rejection.retryable ? .null : .text(SQLiteValueCodec.dateString(completedAt)),
            .text(rejection.code),
            .text(rejection.message),
            .integer(rejection.retryable ? 1 : 0),
            .text(rejection.operationID.description),
        ])
        _ = try statement.step()
        guard try connection.scalarInt("SELECT changes()") == 1 else {
            throw SQLiteLedgerError.integrityFailure(
                "Rejected operation state lost transaction isolation."
            )
        }
    }

    private func applyConflict(
        _ conflict: SyncPushConflict,
        completedAt: Date
    ) throws {
        let state = try readOperationResultState(operationID: conflict.operationID)
        if state.status == .conflict {
            guard state.conflictID == conflict.conflictID,
                  state.resultCode == conflict.code,
                  state.resultMessage == conflict.message,
                  state.canonicalRevision == conflict.currentRevision
            else {
                throw SQLiteLedgerError.integrityFailure(
                    "A conflicted operation was replayed with a different server result."
                )
            }
            return
        }
        guard state.status == .pending || state.status == .retry else {
            throw SQLiteLedgerError.invalidSyncResult(
                "Only pending operations can transition to conflict."
            )
        }
        let statement = try connection.statement(
            """
            UPDATE sync_operation_state
            SET status = 'conflict', attempt_count = attempt_count + 1,
                next_attempt_at = NULL, last_error = ?, canonical_revision = ?,
                server_change_id = NULL, completed_at = ?, result_code = ?,
                result_message = ?, result_retryable = 0, merge_result = NULL,
                conflict_id = ?
            WHERE operation_id = ? AND status IN ('pending', 'retry')
            """
        )
        try statement.bind([
            .text(conflict.message),
            conflict.currentRevision.map { .integer(Int64($0)) } ?? .null,
            .text(SQLiteValueCodec.dateString(completedAt)),
            .text(conflict.code),
            .text(conflict.message),
            .text(conflict.conflictID.description),
            .text(conflict.operationID.description),
        ])
        _ = try statement.step()
        guard try connection.scalarInt("SELECT changes()") == 1 else {
            throw SQLiteLedgerError.integrityFailure(
                "Conflicted operation state lost transaction isolation."
            )
        }
    }

    private func insertRemoteChange(
        _ change: RemoteSyncChange,
        localDeviceID: UUIDv7,
        appliedAt: Date
    ) throws -> RemoteChangeApplicationKind {
        let localOperation = try readLocalOperationMetadata(operationID: change.originOperationID)
        let applicationKind: RemoteChangeApplicationKind
        if change.originDeviceID == localDeviceID, let localOperation {
            guard localOperation.entityType == change.entityType,
                  localOperation.entityID == change.entityID,
                  localOperation.mutationType == change.mutationType
            else {
                throw SQLiteLedgerError.integrityFailure(
                    "A same-device server change does not match its immutable local operation."
                )
            }
            applicationKind = .localReconciliation
        } else {
            applicationKind = .remoteCommit
        }

        let ledgerEventID = UUIDv7()
        let ledgerLocalSequence = try insertLedgerEntry(
            LedgerEntry(
                eventID: ledgerEventID,
                eventType: applicationKind == .localReconciliation
                    ? "sync.local_change_reconciled"
                    : "sync.remote_change_applied",
                aggregateType: change.entityType,
                aggregateID: change.entityID,
                occurredAt: change.serverReceivedAt,
                recordedAt: appliedAt,
                payload: change.payload,
                provenanceID: change.originOperationID.rawValue
            )
        )
        let payloadHash = SHA256Digest.hexDigest(of: change.payload)
        let projectionStatement = try connection.statement(
            """
            INSERT INTO projection_events (
                ledger_local_sequence, entity_type, entity_id, revision,
                mutation_type, document, document_sha256, recorded_at,
                source_kind, server_change_id, origin_operation_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'remote', ?, ?)
            """
        )
        try projectionStatement.bind([
            .integer(ledgerLocalSequence),
            .text(change.entityType),
            .text(change.entityID.description),
            .integer(Int64(change.canonicalRevision)),
            .text(change.mutationType.rawValue),
            .blob(change.payload),
            .text(payloadHash),
            .text(SQLiteValueCodec.dateString(appliedAt)),
            .integer(change.changeID),
            .text(change.originOperationID.description),
        ])
        _ = try projectionStatement.step()
        let projectionEventSequence = connection.lastInsertedRowID

        let receiptStatement = try connection.statement(
            """
            INSERT INTO remote_change_receipts (
                change_id, projection_event_sequence, canonical_revision,
                entity_type, entity_id, mutation_type, payload, payload_sha256,
                tombstone, deletion_epoch, merge_result, origin_device_id,
                origin_operation_id, server_received_at, applied_at, application_kind
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try receiptStatement.bind([
            .integer(change.changeID),
            .integer(projectionEventSequence),
            .integer(Int64(change.canonicalRevision)),
            .text(change.entityType),
            .text(change.entityID.description),
            .text(change.mutationType.rawValue),
            .blob(change.payload),
            .text(payloadHash),
            .integer(change.tombstone ? 1 : 0),
            change.deletionEpoch.map(SQLiteValue.integer) ?? .null,
            .text(change.mergeResult),
            .text(change.originDeviceID.description),
            .text(change.originOperationID.description),
            .text(SQLiteValueCodec.dateString(change.serverReceivedAt)),
            .text(SQLiteValueCodec.dateString(appliedAt)),
            .text(applicationKind.rawValue),
        ])
        _ = try receiptStatement.step()

        if applicationKind == .localReconciliation {
            try applyAcceptance(
                SyncPushAcceptance(
                    operationID: change.originOperationID,
                    canonicalRevision: change.canonicalRevision,
                    serverChangeID: change.changeID,
                    mergeResult: change.mergeResult
                ),
                completedAt: appliedAt
            )
        }
        return applicationKind
    }

    func rebuildMaterializedProjection(for identity: ProjectionIdentity) throws {
        let events = try readStoredProjectionEvents(for: identity)
        guard let selected = Self.selectMaterializedProjection(from: events) else {
            let statement = try connection.statement(
                "DELETE FROM entity_projections WHERE entity_type = ? AND entity_id = ?"
            )
            try statement.bind([
                .text(identity.entityType),
                .text(identity.entityID.description),
            ])
            _ = try statement.step()
            return
        }
        try materialize(selected)
    }

    func readStoredProjectionEvents(
        for identity: ProjectionIdentity? = nil
    ) throws -> [StoredProjectionEvent] {
        let predicate = identity == nil ? "" : "WHERE projection.entity_type = ? AND projection.entity_id = ?"
        let statement = try connection.statement(
            """
            SELECT projection.local_sequence, projection.ledger_local_sequence,
                   ledger.event_id, projection.entity_type, projection.entity_id,
                   projection.revision, projection.mutation_type, projection.document,
                   projection.document_sha256, projection.recorded_at,
                   projection.source_kind, projection.server_change_id,
                   projection.origin_operation_id,
                   state.status, state.server_change_id
            FROM projection_events AS projection
            JOIN ledger_entries AS ledger
              ON ledger.local_sequence = projection.ledger_local_sequence
            LEFT JOIN sync_operations AS operation
              ON operation.ledger_local_sequence = projection.ledger_local_sequence
            LEFT JOIN sync_operation_state AS state
              ON state.operation_id = operation.operation_id
            \(predicate)
            ORDER BY projection.local_sequence
            """
        )
        if let identity {
            try statement.bind([
                .text(identity.entityType),
                .text(identity.entityID.description),
            ])
        }
        var events: [StoredProjectionEvent] = []
        while try statement.step() {
            let mutationValue = try statement.text(at: 6)
            let sourceValue = try statement.text(at: 10)
            guard let mutationType = LedgerMutationType(rawValue: mutationValue),
                  let sourceKind = ProjectionSourceKind(rawValue: sourceValue)
            else {
                throw SQLiteLedgerError.integrityFailure(
                    "Projection history contains an unsupported source or mutation type."
                )
            }
            let operationStatus: SyncOperationStatus?
            if let statusValue = statement.optionalText(at: 13) {
                guard let status = SyncOperationStatus(rawValue: statusValue) else {
                    throw SQLiteLedgerError.integrityFailure(
                        "Projection history references an invalid operation status."
                    )
                }
                operationStatus = status
            } else {
                operationStatus = nil
            }
            events.append(
                StoredProjectionEvent(
                    projectionSequence: statement.int64(at: 0),
                    ledgerLocalSequence: statement.int64(at: 1),
                    sourceEventID: try SQLiteValueCodec.uuidV7(statement.text(at: 2)),
                    mutation: ProjectionMutation(
                        entityType: try statement.text(at: 3),
                        entityID: try SQLiteValueCodec.uuidV7(statement.text(at: 4)),
                        revision: Int(statement.int64(at: 5)),
                        mutationType: mutationType,
                        document: try statement.data(at: 7)
                    ),
                    documentSHA256: try statement.text(at: 8),
                    recordedAt: try SQLiteValueCodec.date(statement.text(at: 9)),
                    sourceKind: sourceKind,
                    serverChangeID: statement.optionalText(at: 11).flatMap(Int64.init),
                    originOperationID: try statement.optionalText(at: 12).map(SQLiteValueCodec.uuidV7),
                    operationStatus: operationStatus,
                    operationServerChangeID: statement.optionalText(at: 14).flatMap(Int64.init)
                )
            )
        }
        return events
    }

    static func selectMaterializedProjection(
        from events: [StoredProjectionEvent]
    ) -> StoredProjectionEvent? {
        let latestRemote = events
            .filter { $0.sourceKind == .remote }
            .max { ($0.serverChangeID ?? 0) < ($1.serverChangeID ?? 0) }
        guard let latestRemote else {
            return events.max { $0.ledgerLocalSequence < $1.ledgerLocalSequence }
        }
        let remoteChangeID = latestRemote.serverChangeID ?? 0
        let remoteIsTombstone = latestRemote.mutation.mutationType == .delete
        let localOverlay = events
            .filter { event in
                guard event.sourceKind == .local else {
                    return false
                }
                guard let operationStatus = event.operationStatus else {
                    return event.ledgerLocalSequence > latestRemote.ledgerLocalSequence
                }
                switch operationStatus {
                case .pending, .retry:
                    return !remoteIsTombstone
                case .accepted:
                    return (event.operationServerChangeID ?? 0) > remoteChangeID
                case .rejected, .conflict:
                    return false
                }
            }
            .max { $0.ledgerLocalSequence < $1.ledgerLocalSequence }
        return localOverlay ?? latestRemote
    }

    func materialize(_ event: StoredProjectionEvent) throws {
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

    private func readOperationResultState(
        operationID: UUIDv7
    ) throws -> StoredOperationResultState {
        let statement = try connection.statement(
            """
            SELECT status, canonical_revision, server_change_id,
                   result_code, result_message, result_retryable,
                   merge_result, conflict_id
            FROM sync_operation_state
            WHERE operation_id = ?
            """
        )
        try statement.bind([.text(operationID.description)])
        guard try statement.step() else {
            throw SQLiteLedgerError.invalidSyncResult(
                "The server returned a result for an unknown local operation."
            )
        }
        let statusValue = try statement.text(at: 0)
        guard let status = SyncOperationStatus(rawValue: statusValue) else {
            throw SQLiteLedgerError.integrityFailure(
                "A local operation has an invalid persisted status."
            )
        }
        let conflictID: UUIDv7?
        if let value = statement.optionalText(at: 7) {
            conflictID = try SQLiteValueCodec.uuidV7(value)
        } else {
            conflictID = nil
        }
        return StoredOperationResultState(
            status: status,
            canonicalRevision: statement.optionalText(at: 1).flatMap(Int.init),
            serverChangeID: statement.optionalText(at: 2).flatMap(Int64.init),
            resultCode: statement.optionalText(at: 3),
            resultMessage: statement.optionalText(at: 4),
            resultRetryable: statement.optionalText(at: 5).map { $0 == "1" },
            mergeResult: statement.optionalText(at: 6),
            conflictID: conflictID
        )
    }

    private func readLocalOperationMetadata(
        operationID: UUIDv7
    ) throws -> LocalOperationMetadata? {
        let statement = try connection.statement(
            """
            SELECT entity_type, entity_id, mutation_type
            FROM sync_operations
            WHERE operation_id = ?
            """
        )
        try statement.bind([.text(operationID.description)])
        guard try statement.step() else {
            return nil
        }
        let mutationValue = try statement.text(at: 2)
        guard let mutationType = LedgerMutationType(rawValue: mutationValue) else {
            throw SQLiteLedgerError.integrityFailure(
                "A local operation has an invalid mutation type."
            )
        }
        return LocalOperationMetadata(
            entityType: try statement.text(at: 0),
            entityID: try SQLiteValueCodec.uuidV7(statement.text(at: 1)),
            mutationType: mutationType
        )
    }

    func readRemoteChangeReceipt(
        changeID: Int64
    ) throws -> RemoteChangeReceipt? {
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
            WHERE receipt.change_id = ?
            """
        )
        try statement.bind([.integer(changeID)])
        guard try statement.step() else {
            return nil
        }
        return try Self.decodeRemoteChangeReceipt(statement)
    }

    static func decodeRemoteChangeReceipt(
        _ statement: SQLiteRowStatement
    ) throws -> RemoteChangeReceipt {
        let mutationValue = try statement.text(at: 4)
        let applicationValue = try statement.text(at: 14)
        guard let mutationType = LedgerMutationType(rawValue: mutationValue),
              let applicationKind = RemoteChangeApplicationKind(rawValue: applicationValue)
        else {
            throw SQLiteLedgerError.integrityFailure(
                "A remote receipt has an invalid mutation or application kind."
            )
        }
        return RemoteChangeReceipt(
            change: RemoteSyncChange(
                changeID: statement.int64(at: 0),
                canonicalRevision: Int(statement.int64(at: 1)),
                entityType: try statement.text(at: 2),
                entityID: try SQLiteValueCodec.uuidV7(statement.text(at: 3)),
                mutationType: mutationType,
                payload: try statement.data(at: 5),
                tombstone: statement.int64(at: 7) == 1,
                deletionEpoch: statement.optionalText(at: 8).flatMap(Int64.init),
                mergeResult: try statement.text(at: 9),
                originDeviceID: try SQLiteValueCodec.uuidV7(statement.text(at: 10)),
                originOperationID: try SQLiteValueCodec.uuidV7(statement.text(at: 11)),
                serverReceivedAt: try SQLiteValueCodec.date(statement.text(at: 12))
            ),
            projectionEventSequence: statement.int64(at: 15),
            ledgerEventID: try SQLiteValueCodec.uuidV7(statement.text(at: 16)),
            payloadSHA256: try statement.text(at: 6),
            appliedAt: try SQLiteValueCodec.date(statement.text(at: 13)),
            applicationKind: applicationKind
        )
    }

    private static func receipt(
        _ receipt: RemoteChangeReceipt,
        matches change: RemoteSyncChange
    ) -> Bool {
        receipt.change == change
            && receipt.payloadSHA256 == SHA256Digest.hexDigest(of: change.payload)
    }

    private static func validate(_ batch: SyncPushResultBatch) throws {
        guard isValidCursor(batch.nextServerCursor),
              batch.serverSchemaVersion >= 1,
              batch.completedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SQLiteLedgerError.invalidSyncResult(
                "Push results require a valid cursor, schema version, and completion time."
            )
        }
        let operationIDs = batch.accepted.map(\.operationID)
            + batch.rejected.map(\.operationID)
            + batch.conflicts.map(\.operationID)
        guard Set(operationIDs).count == operationIDs.count else {
            throw SQLiteLedgerError.invalidSyncResult(
                "A push response cannot contain multiple results for one operation."
            )
        }
        for acceptance in batch.accepted {
            guard acceptance.canonicalRevision >= 1,
                  acceptance.serverChangeID >= 1,
                  !acceptance.mergeResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw SQLiteLedgerError.invalidSyncResult(
                    "Accepted operations require positive revisions, change IDs, and merge results."
                )
            }
        }
        for rejection in batch.rejected {
            guard !rejection.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rejection.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rejection.retryable == (rejection.nextAttemptAt != nil),
                  rejection.nextAttemptAt?.timeIntervalSinceReferenceDate.isFinite ?? true
            else {
                throw SQLiteLedgerError.invalidSyncResult(
                    "Retryable rejections require a retry time and all rejections require details."
                )
            }
        }
        for conflict in batch.conflicts {
            guard !conflict.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !conflict.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  conflict.currentRevision.map({ $0 >= 1 }) ?? true
            else {
                throw SQLiteLedgerError.invalidSyncResult(
                    "Conflicts require details and a positive current revision when present."
                )
            }
        }
    }

    private static func validate(_ page: RemoteSyncPage) throws {
        guard isValidCursor(page.nextCursor),
              page.serverSchemaVersion >= 1,
              page.completedAt.timeIntervalSinceReferenceDate.isFinite,
              page.changes.count <= 500
        else {
            throw SQLiteLedgerError.invalidRemoteChange(
                "Pull pages require a valid cursor, schema version, completion time, and batch size."
            )
        }
        let changeIDs = page.changes.map(\.changeID)
        guard changeIDs == changeIDs.sorted(), Set(changeIDs).count == changeIDs.count else {
            throw SQLiteLedgerError.invalidRemoteChange(
                "Remote changes must have unique ascending change identifiers."
            )
        }
        guard let nextCursorValue = cursorValue(page.nextCursor),
              changeIDs.allSatisfy({ $0 <= nextCursorValue })
        else {
            throw SQLiteLedgerError.invalidRemoteChange(
                "A pull cursor cannot precede a change in its response."
            )
        }
        for change in page.changes {
            guard change.changeID >= 1,
                  change.canonicalRevision >= 1,
                  isValidTypeName(change.entityType),
                  change.payload.count <= maximumSyncPayloadBytes,
                  !change.mergeResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  change.mergeResult.count <= 200,
                  change.serverReceivedAt.timeIntervalSinceReferenceDate.isFinite
            else {
                throw SQLiteLedgerError.invalidRemoteChange(
                    "A remote change contains invalid identifiers, metadata, or payload size."
                )
            }
            do {
                let object = try JSONSerialization.jsonObject(with: change.payload)
                guard object is [String: Any] else {
                    throw SQLiteLedgerError.invalidRemoteChange(
                        "Remote change payloads must be JSON objects."
                    )
                }
            } catch let error as SQLiteLedgerError {
                throw error
            } catch {
                throw SQLiteLedgerError.invalidRemoteChange(
                    "Remote change payloads must be valid JSON objects."
                )
            }
            let validDeletion = change.mutationType == .delete
                ? change.tombstone && change.deletionEpoch == change.changeID
                : !change.tombstone && change.deletionEpoch == nil
            guard validDeletion else {
                throw SQLiteLedgerError.invalidRemoteChange(
                    "Remote tombstone metadata must match delete semantics."
                )
            }
        }
    }
}

struct ProjectionIdentity: Hashable {
    let entityType: String
    let entityID: UUIDv7
}

struct StoredProjectionEvent {
    let projectionSequence: Int64
    let ledgerLocalSequence: Int64
    let sourceEventID: UUIDv7
    let mutation: ProjectionMutation
    let documentSHA256: String
    let recordedAt: Date
    let sourceKind: ProjectionSourceKind
    let serverChangeID: Int64?
    let originOperationID: UUIDv7?
    let operationStatus: SyncOperationStatus?
    let operationServerChangeID: Int64?
}

private struct StoredOperationResultState {
    let status: SyncOperationStatus
    let canonicalRevision: Int?
    let serverChangeID: Int64?
    let resultCode: String?
    let resultMessage: String?
    let resultRetryable: Bool?
    let mergeResult: String?
    let conflictID: UUIDv7?
}

private struct LocalOperationMetadata {
    let entityType: String
    let entityID: UUIDv7
    let mutationType: LedgerMutationType
}
