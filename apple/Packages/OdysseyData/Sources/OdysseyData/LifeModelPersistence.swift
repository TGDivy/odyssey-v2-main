import Foundation
import OdysseyDomain

public enum LifeModelDeliveryStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case retry
    case accepted
    case conflict
    case rejected
}

public struct LifeModelAcceptanceCommand: Codable, Hashable, Sendable {
    public let eventID: UUIDv7
    public let kind: LifeModelKind
    public let versionID: UUIDv7
    public let logicalID: UUIDv7
    public let versionNumber: Int
    public let expectedCurrentVersionID: UUIDv7?
    public let acceptanceMethod: LifeModelAcceptanceMethod
    public let acceptedAt: Date
    public let requestBody: Data
    public let document: Data
    public let createdAt: Date

    public init(
        eventID: UUIDv7 = UUIDv7(),
        kind: LifeModelKind,
        versionID: UUIDv7,
        logicalID: UUIDv7,
        versionNumber: Int,
        expectedCurrentVersionID: UUIDv7?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        acceptedAt: Date,
        requestBody: Data,
        document: Data,
        createdAt: Date
    ) throws {
        guard versionNumber >= 1,
              !requestBody.isEmpty,
              requestBody.count <= 1_024 * 1_024,
              !document.isEmpty,
              document.count <= 768 * 1_024,
              acceptedAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SQLiteLedgerError.invalidLifeModelCommand(
                "Life-model commands require positive versions, finite times, and bounded JSON bodies."
            )
        }
        self.eventID = eventID
        self.kind = kind
        self.versionID = versionID
        self.logicalID = logicalID
        self.versionNumber = versionNumber
        self.expectedCurrentVersionID = expectedCurrentVersionID
        self.acceptanceMethod = acceptanceMethod
        self.acceptedAt = acceptedAt
        self.requestBody = requestBody
        self.document = document
        self.createdAt = createdAt
    }
}

public struct StoredLifeModelAcceptance: Codable, Hashable, Sendable {
    public let localSequence: Int64
    public let command: LifeModelAcceptanceCommand
    public let requestSHA256: String
    public let documentSHA256: String
    public let deliveryStatus: LifeModelDeliveryStatus
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let lastErrorCode: String?
    public let lastErrorMessage: String?
    public let actualCurrentVersionID: UUIDv7?
    public let completedAt: Date?
    public let updatedAt: Date

    public init(
        localSequence: Int64,
        command: LifeModelAcceptanceCommand,
        requestSHA256: String,
        documentSHA256: String,
        deliveryStatus: LifeModelDeliveryStatus,
        attemptCount: Int,
        nextAttemptAt: Date?,
        lastErrorCode: String?,
        lastErrorMessage: String?,
        actualCurrentVersionID: UUIDv7?,
        completedAt: Date?,
        updatedAt: Date
    ) {
        self.localSequence = localSequence
        self.command = command
        self.requestSHA256 = requestSHA256
        self.documentSHA256 = documentSHA256
        self.deliveryStatus = deliveryStatus
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
        self.actualCurrentVersionID = actualCurrentVersionID
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

public struct CachedLifeModelVersion: Codable, Hashable, Sendable {
    public let kind: LifeModelKind
    public let versionID: UUIDv7
    public let logicalID: UUIDv7
    public let versionNumber: Int
    public let acceptanceSequence: Int
    public let supersedesVersionID: UUIDv7?
    public let status: String?
    public let acceptanceMethod: LifeModelAcceptanceMethod
    public let acceptedAt: Date
    public let contentHash: String
    public let document: Data
    public let eventID: UUIDv7
    public let ledgerSequence: Int64
    public let policyVersion: String
    public let cachedAt: Date

    public init(
        kind: LifeModelKind,
        versionID: UUIDv7,
        logicalID: UUIDv7,
        versionNumber: Int,
        acceptanceSequence: Int,
        supersedesVersionID: UUIDv7?,
        status: String?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        acceptedAt: Date,
        contentHash: String,
        document: Data,
        eventID: UUIDv7,
        ledgerSequence: Int64,
        policyVersion: String,
        cachedAt: Date
    ) throws {
        guard versionNumber >= 1,
              acceptanceSequence >= 1,
              ledgerSequence >= 1,
              contentHash.count == 64,
              contentHash.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
              !document.isEmpty,
              document.count <= 768 * 1_024,
              !policyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SQLiteLedgerError.invalidLifeModelCommand(
                "Cached life-model versions require valid sequences, hashes, documents, and policy provenance."
            )
        }
        self.kind = kind
        self.versionID = versionID
        self.logicalID = logicalID
        self.versionNumber = versionNumber
        self.acceptanceSequence = acceptanceSequence
        self.supersedesVersionID = supersedesVersionID
        self.status = status
        self.acceptanceMethod = acceptanceMethod
        self.acceptedAt = acceptedAt
        self.contentHash = contentHash
        self.document = document
        self.eventID = eventID
        self.ledgerSequence = ledgerSequence
        self.policyVersion = policyVersion
        self.cachedAt = cachedAt
    }
}

public struct LifeModelQueueDiagnostics: Codable, Hashable, Sendable {
    public let queuedCount: Int
    public let conflictCount: Int
    public let rejectedCount: Int
    public let oldestQueuedAt: Date?

    public init(
        queuedCount: Int,
        conflictCount: Int,
        rejectedCount: Int,
        oldestQueuedAt: Date?
    ) {
        self.queuedCount = queuedCount
        self.conflictCount = conflictCount
        self.rejectedCount = rejectedCount
        self.oldestQueuedAt = oldestQueuedAt
    }
}

extension SQLiteLedgerStore {
    public func enqueueLifeModelAcceptance(
        _ command: LifeModelAcceptanceCommand
    ) throws -> StoredLifeModelAcceptance {
        try withWrite {
            let requestHash = SHA256Digest.hexDigest(of: command.requestBody)
            let documentHash = SHA256Digest.hexDigest(of: command.document)
            if let existing = try readLifeModelAcceptance(eventID: command.eventID) {
                guard existing.requestSHA256 == requestHash,
                      existing.documentSHA256 == documentHash,
                      existing.command.kind == command.kind,
                      existing.command.versionID == command.versionID,
                      existing.command.logicalID == command.logicalID,
                      existing.command.versionNumber == command.versionNumber,
                      existing.command.expectedCurrentVersionID == command.expectedCurrentVersionID,
                      existing.command.acceptanceMethod == command.acceptanceMethod,
                      existing.command.acceptedAt == command.acceptedAt
                else {
                    throw SQLiteLedgerError.invalidLifeModelCommand(
                        "A life-model event ID cannot be reused for different content."
                    )
                }
                return existing
            }
            guard try connection.scalarInt(
                "SELECT COUNT(*) FROM life_model_acceptance_commands WHERE version_id = ?",
                bindings: [.text(command.versionID.description)]
            ) == 0 else {
                throw SQLiteLedgerError.invalidLifeModelCommand(
                    "A life-model version ID cannot be reused."
                )
            }
            let insert = try connection.statement(
                """
                INSERT INTO life_model_acceptance_commands (
                    event_id, kind, version_id, logical_id, version_number,
                    expected_current_version_id, acceptance_method, accepted_at,
                    request_body, request_sha256, document, document_sha256, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            try insert.bind([
                .text(command.eventID.description),
                .text(command.kind.rawValue),
                .text(command.versionID.description),
                .text(command.logicalID.description),
                .integer(Int64(command.versionNumber)),
                command.expectedCurrentVersionID.map { .text($0.description) } ?? .null,
                .text(command.acceptanceMethod.rawValue),
                .text(SQLiteValueCodec.dateString(command.acceptedAt)),
                .blob(command.requestBody),
                .text(requestHash),
                .blob(command.document),
                .text(documentHash),
                .text(SQLiteValueCodec.dateString(command.createdAt)),
            ])
            _ = try insert.step()
            let state = try connection.statement(
                """
                INSERT INTO life_model_acceptance_state (
                    event_id, delivery_status, attempt_count, updated_at
                ) VALUES (?, 'pending', 0, ?)
                """
            )
            try state.bind([
                .text(command.eventID.description),
                .text(SQLiteValueCodec.dateString(command.createdAt)),
            ])
            _ = try state.step()
            guard let stored = try readLifeModelAcceptance(eventID: command.eventID) else {
                throw SQLiteLedgerError.integrityFailure(
                    "A queued life-model command could not be read after insertion."
                )
            }
            return stored
        }
    }

    public func pendingLifeModelAcceptances(
        limit: Int = 50,
        readyAt: Date
    ) throws -> [StoredLifeModelAcceptance] {
        guard (1 ... 200).contains(limit) else {
            throw SQLiteLedgerError.invalidLifeModelCommand(
                "Life-model queue limits must be between 1 and 200."
            )
        }
        return try withRead {
            let statement = try connection.statement(
                """
                \(lifeModelAcceptanceSelect)
                WHERE state.delivery_status IN ('pending', 'retry')
                  AND (state.next_attempt_at IS NULL OR state.next_attempt_at <= ?)
                ORDER BY command.local_sequence
                LIMIT ?
                """
            )
            try statement.bind([
                .text(SQLiteValueCodec.dateString(readyAt)),
                .integer(Int64(limit)),
            ])
            return try readLifeModelAcceptances(statement)
        }
    }

    public func lifeModelAcceptances(
        kind: LifeModelKind? = nil,
        limit: Int = 200
    ) throws -> [StoredLifeModelAcceptance] {
        guard (1 ... 1_000).contains(limit) else {
            throw SQLiteLedgerError.invalidLifeModelCommand(
                "Life-model history limits must be between 1 and 1,000."
            )
        }
        return try withRead {
            let clause = kind == nil ? "" : "WHERE command.kind = ?"
            let statement = try connection.statement(
                """
                \(lifeModelAcceptanceSelect)
                \(clause)
                ORDER BY command.local_sequence DESC
                LIMIT ?
                """
            )
            var bindings: [SQLiteValue] = []
            if let kind {
                bindings.append(.text(kind.rawValue))
            }
            bindings.append(.integer(Int64(limit)))
            try statement.bind(bindings)
            return try readLifeModelAcceptances(statement)
        }
    }

    public func recordLifeModelRetry(
        eventID: UUIDv7,
        errorCode: String,
        message: String,
        nextAttemptAt: Date,
        updatedAt: Date
    ) throws {
        try updateLifeModelDelivery(
            eventID: eventID,
            status: .retry,
            errorCode: errorCode,
            message: message,
            actualCurrentVersionID: nil,
            nextAttemptAt: nextAttemptAt,
            completedAt: nil,
            updatedAt: updatedAt
        )
    }

    public func recordLifeModelConflict(
        eventID: UUIDv7,
        errorCode: String,
        message: String,
        actualCurrentVersionID: UUIDv7?,
        completedAt: Date
    ) throws {
        try updateLifeModelDelivery(
            eventID: eventID,
            status: .conflict,
            errorCode: errorCode,
            message: message,
            actualCurrentVersionID: actualCurrentVersionID,
            nextAttemptAt: nil,
            completedAt: completedAt,
            updatedAt: completedAt
        )
    }

    public func recordLifeModelRejected(
        eventID: UUIDv7,
        errorCode: String,
        message: String,
        completedAt: Date
    ) throws {
        try updateLifeModelDelivery(
            eventID: eventID,
            status: .rejected,
            errorCode: errorCode,
            message: message,
            actualCurrentVersionID: nil,
            nextAttemptAt: nil,
            completedAt: completedAt,
            updatedAt: completedAt
        )
    }

    public func recordLifeModelAccepted(
        eventID: UUIDv7,
        version: CachedLifeModelVersion,
        completedAt: Date
    ) throws {
        try withWrite {
            guard let command = try readLifeModelAcceptance(eventID: eventID),
                  command.command.kind == version.kind,
                  command.command.versionID == version.versionID,
                  command.command.logicalID == version.logicalID,
                  command.command.versionNumber == version.versionNumber,
                  command.command.expectedCurrentVersionID == version.supersedesVersionID,
                  command.command.acceptanceMethod == version.acceptanceMethod,
                  command.command.acceptedAt == version.acceptedAt,
                  version.eventID == eventID
            else {
                throw SQLiteLedgerError.invalidLifeModelCommand(
                    "A server receipt must match the queued life-model command."
                )
            }
            try insertCachedLifeModelVersion(version)
            if command.deliveryStatus == .accepted {
                return
            }
            try updateLifeModelDeliveryInCurrentTransaction(
                eventID: eventID,
                status: .accepted,
                errorCode: nil,
                message: nil,
                actualCurrentVersionID: nil,
                nextAttemptAt: nil,
                completedAt: completedAt,
                updatedAt: completedAt
            )
        }
    }

    public func cacheLifeModelVersion(_ version: CachedLifeModelVersion) throws {
        try withWrite {
            try insertCachedLifeModelVersion(version)
        }
    }

    public func cachedLifeModelVersions(
        kind: LifeModelKind,
        limit: Int = 200
    ) throws -> [CachedLifeModelVersion] {
        guard (1 ... 1_000).contains(limit) else {
            throw SQLiteLedgerError.invalidLifeModelCommand(
                "Cached life-model history limits must be between 1 and 1,000."
            )
        }
        return try withRead {
            let statement = try connection.statement(
                """
                SELECT kind, version_id, logical_id, version_number, acceptance_sequence,
                       supersedes_version_id, status, acceptance_method, accepted_at,
                       content_hash, document, event_id, ledger_sequence, policy_version, cached_at
                FROM life_model_remote_versions
                WHERE kind = ?
                ORDER BY acceptance_sequence DESC
                LIMIT ?
                """
            )
            try statement.bind([.text(kind.rawValue), .integer(Int64(limit))])
            var versions: [CachedLifeModelVersion] = []
            while try statement.step() {
                versions.append(try decodeCachedLifeModelVersion(statement))
            }
            return versions
        }
    }

    public func lifeModelQueueDiagnostics() throws -> LifeModelQueueDiagnostics {
        try withRead {
            let queued = Int(try connection.scalarInt(
                "SELECT COUNT(*) FROM life_model_acceptance_state WHERE delivery_status IN ('pending', 'retry')"
            ))
            let conflicts = Int(try connection.scalarInt(
                "SELECT COUNT(*) FROM life_model_acceptance_state WHERE delivery_status = 'conflict'"
            ))
            let rejected = Int(try connection.scalarInt(
                "SELECT COUNT(*) FROM life_model_acceptance_state WHERE delivery_status = 'rejected'"
            ))
            let oldest = try connection.scalarText(
                """
                SELECT MIN(command.created_at)
                FROM life_model_acceptance_commands AS command
                JOIN life_model_acceptance_state AS state ON state.event_id = command.event_id
                WHERE state.delivery_status IN ('pending', 'retry')
                """
            )
            return LifeModelQueueDiagnostics(
                queuedCount: queued,
                conflictCount: conflicts,
                rejectedCount: rejected,
                oldestQueuedAt: try oldest.map(SQLiteValueCodec.date)
            )
        }
    }

    func allLifeModelAcceptancesInCurrentTransaction() throws -> [StoredLifeModelAcceptance] {
        let statement = try connection.statement(
            """
            \(lifeModelAcceptanceSelect)
            ORDER BY command.local_sequence
            """
        )
        return try readLifeModelAcceptances(statement)
    }

    func allCachedLifeModelVersionsInCurrentTransaction() throws -> [CachedLifeModelVersion] {
        let statement = try connection.statement(
            """
            SELECT kind, version_id, logical_id, version_number, acceptance_sequence,
                   supersedes_version_id, status, acceptance_method, accepted_at,
                   content_hash, document, event_id, ledger_sequence, policy_version, cached_at
            FROM life_model_remote_versions
            ORDER BY kind, acceptance_sequence
            """
        )
        var versions: [CachedLifeModelVersion] = []
        while try statement.step() {
            versions.append(try decodeCachedLifeModelVersion(statement))
        }
        return versions
    }

    private var lifeModelAcceptanceSelect: String {
        """
        SELECT command.local_sequence, command.event_id, command.kind, command.version_id,
               command.logical_id, command.version_number, command.expected_current_version_id,
               command.acceptance_method, command.accepted_at, command.request_body,
               command.request_sha256, command.document, command.document_sha256,
               command.created_at, state.delivery_status, state.attempt_count,
               state.next_attempt_at, state.last_error_code, state.last_error_message,
               state.actual_current_version_id, state.completed_at, state.updated_at
        FROM life_model_acceptance_commands AS command
        JOIN life_model_acceptance_state AS state ON state.event_id = command.event_id
        """
    }

    private func readLifeModelAcceptance(
        eventID: UUIDv7
    ) throws -> StoredLifeModelAcceptance? {
        let statement = try connection.statement(
            """
            \(lifeModelAcceptanceSelect)
            WHERE command.event_id = ?
            """
        )
        try statement.bind([.text(eventID.description)])
        guard try statement.step() else { return nil }
        return try decodeLifeModelAcceptance(statement)
    }

    private func readLifeModelAcceptances(
        _ statement: SQLiteRowStatement
    ) throws -> [StoredLifeModelAcceptance] {
        var commands: [StoredLifeModelAcceptance] = []
        while try statement.step() {
            commands.append(try decodeLifeModelAcceptance(statement))
        }
        return commands
    }

    private func decodeLifeModelAcceptance(
        _ statement: SQLiteRowStatement
    ) throws -> StoredLifeModelAcceptance {
        guard let kind = LifeModelKind(rawValue: try statement.text(at: 2)),
              let acceptanceMethod = LifeModelAcceptanceMethod(
                  rawValue: try statement.text(at: 7)
              ),
              let deliveryStatus = LifeModelDeliveryStatus(rawValue: try statement.text(at: 14))
        else {
            throw SQLiteLedgerError.integrityFailure(
                "Stored life-model command contains an unsupported enum value."
            )
        }
        let command = try LifeModelAcceptanceCommand(
            eventID: SQLiteValueCodec.uuidV7(try statement.text(at: 1)),
            kind: kind,
            versionID: SQLiteValueCodec.uuidV7(try statement.text(at: 3)),
            logicalID: SQLiteValueCodec.uuidV7(try statement.text(at: 4)),
            versionNumber: Int(statement.int64(at: 5)),
            expectedCurrentVersionID: try statement.optionalText(at: 6).map(
                SQLiteValueCodec.uuidV7
            ),
            acceptanceMethod: acceptanceMethod,
            acceptedAt: try SQLiteValueCodec.date(statement.text(at: 8)),
            requestBody: try statement.data(at: 9),
            document: try statement.data(at: 11),
            createdAt: try SQLiteValueCodec.date(statement.text(at: 13))
        )
        let requestHash = try statement.text(at: 10)
        let documentHash = try statement.text(at: 12)
        guard SHA256Digest.hexDigest(of: command.requestBody) == requestHash,
              SHA256Digest.hexDigest(of: command.document) == documentHash
        else {
            throw SQLiteLedgerError.integrityFailure(
                "Stored life-model command hash verification failed."
            )
        }
        return StoredLifeModelAcceptance(
            localSequence: statement.int64(at: 0),
            command: command,
            requestSHA256: requestHash,
            documentSHA256: documentHash,
            deliveryStatus: deliveryStatus,
            attemptCount: Int(statement.int64(at: 15)),
            nextAttemptAt: try statement.optionalText(at: 16).map(SQLiteValueCodec.date),
            lastErrorCode: statement.optionalText(at: 17),
            lastErrorMessage: statement.optionalText(at: 18),
            actualCurrentVersionID: try statement.optionalText(at: 19).map(
                SQLiteValueCodec.uuidV7
            ),
            completedAt: try statement.optionalText(at: 20).map(SQLiteValueCodec.date),
            updatedAt: try SQLiteValueCodec.date(statement.text(at: 21))
        )
    }

    private func updateLifeModelDelivery(
        eventID: UUIDv7,
        status: LifeModelDeliveryStatus,
        errorCode: String?,
        message: String?,
        actualCurrentVersionID: UUIDv7?,
        nextAttemptAt: Date?,
        completedAt: Date?,
        updatedAt: Date
    ) throws {
        try withWrite {
            try updateLifeModelDeliveryInCurrentTransaction(
                eventID: eventID,
                status: status,
                errorCode: errorCode,
                message: message,
                actualCurrentVersionID: actualCurrentVersionID,
                nextAttemptAt: nextAttemptAt,
                completedAt: completedAt,
                updatedAt: updatedAt
            )
        }
    }

    private func updateLifeModelDeliveryInCurrentTransaction(
        eventID: UUIDv7,
        status: LifeModelDeliveryStatus,
        errorCode: String?,
        message: String?,
        actualCurrentVersionID: UUIDv7?,
        nextAttemptAt: Date?,
        completedAt: Date?,
        updatedAt: Date
    ) throws {
        let statement = try connection.statement(
            """
            UPDATE life_model_acceptance_state
            SET delivery_status = ?, attempt_count = attempt_count + 1,
                next_attempt_at = ?, last_error_code = ?, last_error_message = ?,
                actual_current_version_id = ?, completed_at = ?, updated_at = ?
            WHERE event_id = ? AND delivery_status IN ('pending', 'retry')
            """
        )
        try statement.bind([
            .text(status.rawValue),
            nextAttemptAt.map { .text(SQLiteValueCodec.dateString($0)) } ?? .null,
            errorCode.map(SQLiteValue.text) ?? .null,
            message.map(SQLiteValue.text) ?? .null,
            actualCurrentVersionID.map { .text($0.description) } ?? .null,
            completedAt.map { .text(SQLiteValueCodec.dateString($0)) } ?? .null,
            .text(SQLiteValueCodec.dateString(updatedAt)),
            .text(eventID.description),
        ])
        _ = try statement.step()
        guard try connection.scalarInt("SELECT changes()") == 1 else {
            throw SQLiteLedgerError.invalidLifeModelCommand(
                "Only queued life-model commands can change delivery state."
            )
        }
    }

    private func insertCachedLifeModelVersion(_ version: CachedLifeModelVersion) throws {
        let localDocumentHash = SHA256Digest.hexDigest(of: version.document)
        let existing = try connection.statement(
            """
            SELECT content_hash, document_sha256, acceptance_sequence
            FROM life_model_remote_versions
            WHERE version_id = ?
            """
        )
        try existing.bind([.text(version.versionID.description)])
        if try existing.step() {
            guard try existing.text(at: 0) == version.contentHash,
                  try existing.text(at: 1) == localDocumentHash,
                  Int(existing.int64(at: 2)) == version.acceptanceSequence
            else {
                throw SQLiteLedgerError.invalidLifeModelCommand(
                    "A cached life-model version cannot change immutable content."
                )
            }
            return
        }
        let statement = try connection.statement(
            """
            INSERT INTO life_model_remote_versions (
                version_id, kind, logical_id, version_number, acceptance_sequence,
                supersedes_version_id, status, acceptance_method, accepted_at,
                content_hash, document, document_sha256, event_id, ledger_sequence,
                policy_version, cached_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind([
            .text(version.versionID.description),
            .text(version.kind.rawValue),
            .text(version.logicalID.description),
            .integer(Int64(version.versionNumber)),
            .integer(Int64(version.acceptanceSequence)),
            version.supersedesVersionID.map { .text($0.description) } ?? .null,
            version.status.map(SQLiteValue.text) ?? .null,
            .text(version.acceptanceMethod.rawValue),
            .text(SQLiteValueCodec.dateString(version.acceptedAt)),
            .text(version.contentHash),
            .blob(version.document),
            .text(localDocumentHash),
            .text(version.eventID.description),
            .integer(version.ledgerSequence),
            .text(version.policyVersion),
            .text(SQLiteValueCodec.dateString(version.cachedAt)),
        ])
        _ = try statement.step()
    }

    private func decodeCachedLifeModelVersion(
        _ statement: SQLiteRowStatement
    ) throws -> CachedLifeModelVersion {
        guard let kind = LifeModelKind(rawValue: try statement.text(at: 0)),
              let method = LifeModelAcceptanceMethod(rawValue: try statement.text(at: 7))
        else {
            throw SQLiteLedgerError.integrityFailure(
                "Cached life-model version contains an unsupported enum value."
            )
        }
        return try CachedLifeModelVersion(
            kind: kind,
            versionID: SQLiteValueCodec.uuidV7(try statement.text(at: 1)),
            logicalID: SQLiteValueCodec.uuidV7(try statement.text(at: 2)),
            versionNumber: Int(statement.int64(at: 3)),
            acceptanceSequence: Int(statement.int64(at: 4)),
            supersedesVersionID: try statement.optionalText(at: 5).map(
                SQLiteValueCodec.uuidV7
            ),
            status: statement.optionalText(at: 6),
            acceptanceMethod: method,
            acceptedAt: try SQLiteValueCodec.date(statement.text(at: 8)),
            contentHash: try statement.text(at: 9),
            document: try statement.data(at: 10),
            eventID: SQLiteValueCodec.uuidV7(try statement.text(at: 11)),
            ledgerSequence: statement.int64(at: 12),
            policyVersion: try statement.text(at: 13),
            cachedAt: try SQLiteValueCodec.date(statement.text(at: 14))
        )
    }
}
