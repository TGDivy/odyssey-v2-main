import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let fixtureDate = Date(timeIntervalSince1970: 1_786_752_000.125)

@Test
func cursorRequiresCanonicalWireFormat() throws {
    #expect(try SyncCursor("c_0").value == 0)
    #expect(try SyncCursor("c_42").description == "c_42")
    #expect(throws: SyncContractError.invalidCursor("c_01")) {
        try SyncCursor("c_01")
    }
    #expect(throws: SyncContractError.invalidCursor("42")) {
        try SyncCursor("42")
    }
    #expect(throws: SyncContractError.invalidCursor("c_-1")) {
        try SyncCursor("c_-1")
    }
}

@Test
func pendingOperationMapsToBackendPushShape() throws {
    let operationID = try identifier(1)
    let entityID = try identifier(2)
    let eventID = try identifier(3)
    let payload = Data(#"{"schema_version":1,"text":"offline capture"}"#.utf8)
    let pending = PendingSyncOperation(
        operationID: operationID,
        deviceSequence: 7,
        entityType: "capture",
        entityID: entityID,
        mutationType: .create,
        baseRevision: nil,
        payload: payload,
        payloadSHA256: SHA256Digest.hexDigest(of: payload),
        createdAt: fixtureDate,
        idempotencyKey: operationID.description,
        sensitivityClass: .private,
        sourceEventID: eventID,
        status: .pending,
        attemptCount: 0,
        nextAttemptAt: nil,
        lastError: nil
    )
    let operation = try SyncOperation(pending: pending)
    let request = try SyncPushRequest(
        deviceID: try identifier(4),
        baseCursor: try SyncCursor("c_6"),
        operations: [operation]
    )
    let deviceID = try identifier(4)

    let encoded = try SyncJSONCoding.makeEncoder().encode(request)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["device_id"] as? String == deviceID.description)
    #expect(object["client_schema_version"] as? Int == 1)
    #expect(object["base_cursor"] as? String == "c_6")
    let operations = try #require(object["operations"] as? [[String: Any]])
    #expect(operations[0]["operation_id"] as? String == operationID.description)
    #expect(operations[0]["device_sequence"] as? Int == 7)
    #expect(operations[0]["mutation_type"] as? String == "create")
    #expect(operations[0]["idempotency_key"] as? String == operationID.description)
    let encodedPayload = try #require(operations[0]["payload"] as? [String: Any])
    #expect(encodedPayload["schema_version"] as? Int == 1)
    #expect(encodedPayload["text"] as? String == "offline capture")
}

@Test
func pushResponseDecodesBackendFixture() throws {
    let response = try SyncJSONCoding.makeDecoder().decode(
        SyncPushResponse.self,
        from: Data(
            """
            {
              "accepted": [{
                "operation_id": "018f0000-0000-7000-8000-000000000001",
                "canonical_revision": 2,
                "server_change_id": 41,
                "merge_result": "updated"
              }],
              "rejected": [{
                "operation_id": "018f0000-0000-7000-8000-000000000002",
                "code": "VALIDATION_FAILED",
                "message": "Synthetic rejection",
                "retryable": false
              }],
              "conflicts": [{
                "conflict_id": "018f0000-0000-7000-8000-000000000003",
                "operation_id": "018f0000-0000-7000-8000-000000000004",
                "entity_type": "season",
                "entity_id": "018f0000-0000-7000-8000-000000000005",
                "code": "REVISION_CONFLICT",
                "current_revision": 3,
                "conflicting_fields": ["title"]
              }],
              "next_cursor": "c_41",
              "server_time": "2026-08-15T00:00:00.125Z",
              "server_schema_version": 1,
              "minimum_client_schema_version": 1
            }
            """.utf8
        )
    )

    #expect(response.accepted[0].serverChangeID == 41)
    #expect(response.rejected[0].retryable == false)
    #expect(response.conflicts[0].conflictingFields == ["title"])
    #expect(response.nextCursor.description == "c_41")
    #expect(response.serverSchemaVersion == 1)
}

@Test
func pullResponsePreservesTombstoneAndOrigin() throws {
    let response = try SyncJSONCoding.makeDecoder().decode(
        SyncPullResponse.self,
        from: Data(
            """
            {
              "changes": [{
                "change_id": 42,
                "canonical_revision": 4,
                "entity_type": "capture",
                "entity_id": "018f0000-0000-7000-8000-000000000010",
                "mutation_type": "delete",
                "payload": {},
                "tombstone": true,
                "deletion_epoch": 1,
                "merge_result": "deleted",
                "origin_device_id": "018f0000-0000-7000-8000-000000000011",
                "origin_operation_id": "018f0000-0000-7000-8000-000000000012",
                "server_received_at": "2026-08-15T00:00:00Z"
              }],
              "next_cursor": "c_42",
              "has_more": false,
              "server_time": "2026-08-15T00:00:01Z",
              "server_schema_version": 1,
              "minimum_client_schema_version": 1
            }
            """.utf8
        )
    )

    let change = response.changes[0]
    let originOperationID = try identifier(0x12)
    #expect(change.changeID == 42)
    #expect(change.mutationType == .delete)
    #expect(change.payload.isEmpty)
    #expect(change.tombstone)
    #expect(change.deletionEpoch == 1)
    #expect(change.originOperationID == originOperationID)
    #expect(response.hasMore == false)
}

@Test
func diagnosticsAndConflictFixturesDecode() throws {
    let diagnostics = try SyncJSONCoding.makeDecoder().decode(
        SyncDiagnosticsResponse.self,
        from: Data(
            """
            {
              "server_time": "2026-08-15T00:00:00Z",
              "server_cursor": "c_50",
              "server_schema_version": 1,
              "minimum_client_schema_version": 1,
              "pending_conflicts": 1,
              "pending_attachment_uploads": 0,
              "pending_outbox_jobs": 2,
              "sync_push_enabled": true,
              "sync_pull_enabled": true,
              "devices": [{
                "device_id": "018f0000-0000-7000-8000-000000000020",
                "client_schema_version": 1,
                "schema_compatibility": "compatible",
                "last_successful_push_at": null,
                "last_successful_pull_at": null,
                "operations_queued": 1,
                "oldest_unsynced_operation_at": "2026-08-15T00:00:00Z",
                "attachment_backlog": 0,
                "last_device_sequence": 7,
                "device_cursor": "c_49",
                "server_cursor": "c_50",
                "clock_skew_seconds": null,
                "diagnostics_reported_at": null,
                "diagnostics_stale": true
              }],
              "repair": {
                "projection_rebuild_available": true,
                "projection_rebuild_command": "rebuild",
                "integrity_check_command": "check"
              }
            }
            """.utf8
        )
    )
    #expect(diagnostics.devices[0].schemaCompatibility == .compatible)
    #expect(diagnostics.repair.projectionRebuildAvailable)

    let conflicts = try SyncJSONCoding.makeDecoder().decode(
        SyncConflictListResponse.self,
        from: Data(
            """
            {
              "conflicts": [{
                "conflict_id": "018f0000-0000-7000-8000-000000000021",
                "operation_id": "018f0000-0000-7000-8000-000000000022",
                "originating_device_id": "018f0000-0000-7000-8000-000000000023",
                "entity_type": "season",
                "entity_id": "018f0000-0000-7000-8000-000000000024",
                "code": "REVISION_CONFLICT",
                "base_revision": 1,
                "current_revision": 2,
                "current_document": {"title": "Current"},
                "incoming_document": {"title": "Incoming"},
                "conflicting_fields": ["title"],
                "status": "pending",
                "created_at": "2026-08-15T00:00:00Z",
                "resolved_at": null,
                "explanation": "Both devices changed title.",
                "allowed_strategies": ["keep_current", "accept_incoming", "merge"]
              }],
              "pending_count": 1,
              "server_time": "2026-08-15T00:00:01Z"
            }
            """.utf8
        )
    )
    #expect(conflicts.pendingCount == 1)
    #expect(conflicts.conflicts[0].allowedStrategies == [.keepCurrent, .acceptIncoming, .merge])
    #expect(conflicts.conflicts[0].incomingDocument["title"] == .string("Incoming"))
}

@Test
func requestValidationMatchesBackendRules() throws {
    let operation = try SyncOperation(
        operationID: try identifier(31),
        deviceSequence: 2,
        entityType: "capture",
        entityID: try identifier(32),
        mutationType: .create,
        payload: [:],
        createdAt: fixtureDate
    )
    #expect(throws: SyncContractError.invalidBatch(
        "Push operations must have unique ascending device sequences."
    )) {
        try SyncPushRequest(
            deviceID: identifier(33),
            baseCursor: SyncCursor("c_0"),
            operations: [operation, operation]
        )
    }
    #expect(throws: SyncContractError.invalidDiagnostics(
        "Oldest unsynced time must be present exactly when the queue is nonempty."
    )) {
        try SyncDeviceDiagnosticsInput(
            deviceCursor: SyncCursor("c_0"),
            operationsQueued: 1,
            oldestUnsyncedOperationAt: nil,
            attachmentBacklog: 0
        )
    }
    #expect(throws: SyncContractError.invalidConflictResolution(
        "Only merge resolution requires a merged document."
    )) {
        try SyncConflictResolutionRequest(
            operationID: identifier(34),
            deviceID: identifier(35),
            deviceSequence: 3,
            expectedCurrentRevision: 2,
            strategy: .merge,
            mergedDocument: nil,
            createdAt: fixtureDate
        )
    }
}

private func identifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
