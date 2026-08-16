import Foundation
import OdysseyDomain
import OdysseyTelemetry

public enum ProductTelemetryPersistenceError: Error, Equatable, Sendable {
    case invalidClock
    case invalidRange
    case invalidLimit
    case deviceMismatch
    case uploadNotSupported
    case eventTooLarge
    case conflictingEvent
}

extension SQLiteLedgerStore: ProductTelemetryStoring {
    public func productTelemetryPreferences() throws -> ProductTelemetryPreferences {
        try withRead {
            try readProductTelemetryPreferences()
        }
    }

    public func putProductTelemetryPreferences(
        _ preferences: ProductTelemetryPreferences,
        updatedAt: Date
    ) throws {
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ProductTelemetryPersistenceError.invalidClock
        }
        let document = try ProductTelemetryCoding.makeEncoder().encode(preferences)
        guard document.count <= 65_536 else {
            throw ProductTelemetryPersistenceError.eventTooLarge
        }
        try withWrite {
            let existing = try readProductTelemetryPreferenceRecord()
            guard existing.map({ updatedAt >= $0.updatedAt }) ?? true else {
                throw ProductTelemetryPersistenceError.invalidClock
            }
            let statement = try connection.statement(
                """
                INSERT INTO product_telemetry_preferences (
                    singleton, document, document_sha256, updated_at
                ) VALUES (1, ?, ?, ?)
                ON CONFLICT (singleton) DO UPDATE SET
                    document = excluded.document,
                    document_sha256 = excluded.document_sha256,
                    updated_at = excluded.updated_at
                """
            )
            try statement.bind([
                .blob(document),
                .text(SHA256Digest.hexDigest(of: document)),
                .text(SQLiteValueCodec.dateString(updatedAt)),
            ])
            _ = try statement.step()
            _ = try pruneProductTelemetryInCurrentTransaction(
                at: updatedAt,
                preferences: preferences
            )
        }
    }

    @discardableResult
    public func appendProductTelemetryEvent(_ event: ProductTelemetryEvent) throws -> Bool {
        guard event.deviceID == configuration.deviceID else {
            throw ProductTelemetryPersistenceError.deviceMismatch
        }
        guard event.localOnly else {
            throw ProductTelemetryPersistenceError.uploadNotSupported
        }
        let definition = ProductTelemetryRegistry.definition(for: event.eventName)
        let document = try ProductTelemetryCoding.makeEncoder().encode(event)
        guard document.count <= 16_384 else {
            throw ProductTelemetryPersistenceError.eventTooLarge
        }
        let documentHash = SHA256Digest.hexDigest(of: document)
        return try withWrite {
            let preferences = try readProductTelemetryPreferences()
            _ = try pruneProductTelemetryInCurrentTransaction(
                at: event.receivedAt,
                preferences: preferences
            )
            guard preferences.enables(definition.questionID) else { return false }
            let retentionDays = min(preferences.retentionDays, definition.retentionDays)
            let expiresAt = event.occurredAt.addingTimeInterval(
                TimeInterval(retentionDays * 86_400)
            )
            guard expiresAt > event.receivedAt else { return false }

            let existing = try connection.statement(
                """
                SELECT document, document_sha256
                FROM product_telemetry_events
                WHERE event_id = ?
                """
            )
            try existing.bind([.text(event.eventID.description)])
            if try existing.step() {
                let existingDocument = try existing.data(at: 0)
                let existingHash = try existing.text(at: 1)
                guard SHA256Digest.hexDigest(of: existingDocument) == existingHash else {
                    throw SQLiteLedgerError.integrityFailure(
                        "Stored product telemetry event failed digest verification."
                    )
                }
                guard existingHash == documentHash, existingDocument == document else {
                    throw ProductTelemetryPersistenceError.conflictingEvent
                }
                return false
            }

            let statement = try connection.statement(
                """
                INSERT INTO product_telemetry_events (
                    event_id, occurred_at, received_at, event_name, question_id,
                    document, document_sha256, expires_at, local_only
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                """
            )
            try statement.bind([
                .text(event.eventID.description),
                .text(SQLiteValueCodec.dateString(event.occurredAt)),
                .text(SQLiteValueCodec.dateString(event.receivedAt)),
                .text(event.eventName.rawValue),
                .text(definition.questionID.rawValue),
                .blob(document),
                .text(documentHash),
                .text(SQLiteValueCodec.dateString(expiresAt)),
            ])
            _ = try statement.step()
            return true
        }
    }

    public func productTelemetryEvents(
        from: Date,
        to: Date,
        limit: Int
    ) throws -> [ProductTelemetryEvent] {
        guard from.timeIntervalSinceReferenceDate.isFinite,
              to.timeIntervalSinceReferenceDate.isFinite,
              from < to
        else {
            throw ProductTelemetryPersistenceError.invalidRange
        }
        guard (1 ... 5_000).contains(limit) else {
            throw ProductTelemetryPersistenceError.invalidLimit
        }
        return try withRead {
            let now = configuration.clock()
            guard now.timeIntervalSinceReferenceDate.isFinite else {
                throw ProductTelemetryPersistenceError.invalidClock
            }
            let preferences = try readProductTelemetryPreferences()
            let retentionCutoff = now.addingTimeInterval(
                -TimeInterval(preferences.retentionDays * 86_400)
            )
            let effectiveStart = max(from, retentionCutoff)
            let statement = try connection.statement(
                """
                SELECT event_id, occurred_at, received_at, event_name, question_id,
                       document, document_sha256, expires_at, local_only
                FROM product_telemetry_events
                WHERE occurred_at >= ? AND occurred_at < ? AND expires_at > ?
                ORDER BY occurred_at, event_id
                LIMIT ?
                """
            )
            try statement.bind([
                .text(SQLiteValueCodec.dateString(effectiveStart)),
                .text(SQLiteValueCodec.dateString(to)),
                .text(SQLiteValueCodec.dateString(now)),
                .integer(Int64(limit)),
            ])
            var events: [ProductTelemetryEvent] = []
            while try statement.step() {
                events.append(try decodeProductTelemetryEvent(statement))
            }
            return events
        }
    }

    public func productTelemetrySummary(at generatedAt: Date) throws -> ProductTelemetrySummary {
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ProductTelemetryPersistenceError.invalidClock
        }
        return try withRead {
            let preferences = try readProductTelemetryPreferences()
            let retentionCutoff = generatedAt.addingTimeInterval(
                -TimeInterval(preferences.retentionDays * 86_400)
            )
            let statement = try connection.statement(
                """
                SELECT COUNT(*), MIN(occurred_at), MAX(occurred_at), MIN(expires_at)
                FROM product_telemetry_events
                WHERE occurred_at >= ? AND expires_at > ?
                """
            )
            try statement.bind([
                .text(SQLiteValueCodec.dateString(retentionCutoff)),
                .text(SQLiteValueCodec.dateString(generatedAt)),
            ])
            guard try statement.step() else {
                throw SQLiteLedgerError.integrityFailure(
                    "Product telemetry summary returned no aggregate row."
                )
            }
            return try ProductTelemetrySummary(
                preferences: preferences,
                retainedEventCount: Int(statement.int64(at: 0)),
                oldestEventAt: try statement.optionalText(at: 1).map(SQLiteValueCodec.date),
                newestEventAt: try statement.optionalText(at: 2).map(SQLiteValueCodec.date),
                nextExpiryAt: try statement.optionalText(at: 3).map(SQLiteValueCodec.date),
                generatedAt: generatedAt
            )
        }
    }

    @discardableResult
    public func pruneProductTelemetry(at date: Date) throws -> Int {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ProductTelemetryPersistenceError.invalidClock
        }
        return try withWrite {
            try pruneProductTelemetryInCurrentTransaction(
                at: date,
                preferences: readProductTelemetryPreferences()
            )
        }
    }

    @discardableResult
    public func deleteAllProductTelemetry() throws -> Int {
        try withWrite {
            try connection.execute("DELETE FROM product_telemetry_events")
            return Int(try connection.scalarInt("SELECT changes()"))
        }
    }

    func verifyProductTelemetryStorage() throws {
        _ = try readProductTelemetryPreferences()
        let statement = try connection.statement(
            """
            SELECT event_id, occurred_at, received_at, event_name, question_id,
                   document, document_sha256, expires_at, local_only
            FROM product_telemetry_events
            ORDER BY occurred_at, event_id
            """
        )
        while try statement.step() {
            _ = try decodeProductTelemetryEvent(statement)
        }
    }

    private func readProductTelemetryPreferences() throws -> ProductTelemetryPreferences {
        try readProductTelemetryPreferenceRecord()?.preferences ?? .disabled
    }

    private func readProductTelemetryPreferenceRecord() throws -> (
        preferences: ProductTelemetryPreferences,
        updatedAt: Date
    )? {
        let statement = try connection.statement(
            """
            SELECT document, document_sha256, updated_at
            FROM product_telemetry_preferences
            WHERE singleton = 1
            """
        )
        guard try statement.step() else { return nil }
        let document = try statement.data(at: 0)
        let expectedHash = try statement.text(at: 1)
        guard SHA256Digest.hexDigest(of: document) == expectedHash else {
            throw SQLiteLedgerError.integrityFailure(
                "Product telemetry preferences failed digest verification."
            )
        }
        do {
            return (
                try ProductTelemetryCoding.makeDecoder().decode(
                    ProductTelemetryPreferences.self,
                    from: document
                ),
                try SQLiteValueCodec.date(statement.text(at: 2))
            )
        } catch let error as SQLiteLedgerError {
            throw error
        } catch {
            throw SQLiteLedgerError.integrityFailure(
                "Product telemetry preferences could not be decoded."
            )
        }
    }

    private func decodeProductTelemetryEvent(
        _ statement: SQLiteRowStatement
    ) throws -> ProductTelemetryEvent {
        let eventID = try statement.text(at: 0)
        let occurredAt = try SQLiteValueCodec.date(statement.text(at: 1))
        let receivedAt = try SQLiteValueCodec.date(statement.text(at: 2))
        let eventName = try statement.text(at: 3)
        let questionID = try statement.text(at: 4)
        let document = try statement.data(at: 5)
        let expectedHash = try statement.text(at: 6)
        let expiresAt = try SQLiteValueCodec.date(statement.text(at: 7))
        let localOnly = statement.int64(at: 8) == 1
        guard SHA256Digest.hexDigest(of: document) == expectedHash else {
            throw SQLiteLedgerError.integrityFailure(
                "Product telemetry event \(eventID) failed digest verification."
            )
        }
        let event: ProductTelemetryEvent
        do {
            event = try ProductTelemetryCoding.makeDecoder().decode(
                ProductTelemetryEvent.self,
                from: document
            )
        } catch {
            throw SQLiteLedgerError.integrityFailure(
                "Product telemetry event \(eventID) could not be decoded."
            )
        }
        let definition = ProductTelemetryRegistry.definition(for: event.eventName)
        let maximumExpiry = event.occurredAt.addingTimeInterval(
            TimeInterval(definition.retentionDays * 86_400)
        )
        guard event.eventID.description == eventID,
              event.deviceID == configuration.deviceID,
              event.occurredAt == occurredAt,
              event.receivedAt == receivedAt,
              event.eventName.rawValue == eventName,
              definition.questionID.rawValue == questionID,
              event.localOnly,
              localOnly,
              expiresAt > event.occurredAt,
              expiresAt <= maximumExpiry
        else {
            throw SQLiteLedgerError.integrityFailure(
                "Product telemetry event \(eventID) metadata diverged from its document."
            )
        }
        return event
    }

    private func pruneProductTelemetryInCurrentTransaction(
        at date: Date,
        preferences: ProductTelemetryPreferences
    ) throws -> Int {
        let retentionCutoff = date.addingTimeInterval(
            -TimeInterval(preferences.retentionDays * 86_400)
        )
        let statement = try connection.statement(
            """
            DELETE FROM product_telemetry_events
            WHERE expires_at <= ? OR occurred_at < ?
            """
        )
        try statement.bind([
            .text(SQLiteValueCodec.dateString(date)),
            .text(SQLiteValueCodec.dateString(retentionCutoff)),
        ])
        _ = try statement.step()
        return Int(try connection.scalarInt("SELECT changes()"))
    }
}
