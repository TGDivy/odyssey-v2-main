import Foundation
import GRDB
import OdysseyDomain

extension SQLiteLedgerStore {
    public func projectedEntities(
        entityType: String,
        limit: Int = 50
    ) throws -> [ProjectedEntity] {
        guard Self.isValidTypeName(entityType), (1 ... 500).contains(limit) else {
            throw SQLiteLedgerError.invalidConfiguration(
                "Projection pages require a valid entity type and 1 through 500 rows."
            )
        }
        return try withRead {
            let statement = try connection.statement(
                """
                SELECT entity_type, entity_id, revision, document, tombstone,
                       source_event_id, updated_at
                FROM entity_projections
                WHERE entity_type = ? AND tombstone = 0
                ORDER BY updated_at DESC, entity_id DESC
                LIMIT ?
                """
            )
            try statement.bind([.text(entityType), .integer(Int64(limit))])
            var entities: [ProjectedEntity] = []
            while try statement.step() {
                entities.append(try Self.decodeProjectedEntity(statement))
            }
            return entities
        }
    }

    public func projectionHistory(
        entityType: String,
        entityID: UUIDv7,
        limit: Int = 200
    ) throws -> [ProjectedEntity] {
        guard Self.isValidTypeName(entityType), (1 ... 1_000).contains(limit) else {
            throw SQLiteLedgerError.invalidConfiguration(
                "Projection history requires a valid entity type and 1 through 1,000 rows."
            )
        }
        return try withRead {
            let statement = try connection.statement(
                """
                SELECT event.entity_type, event.entity_id, event.revision,
                       event.document, event.mutation_type,
                       ledger.event_id, event.recorded_at
                FROM projection_events AS event
                JOIN ledger_entries AS ledger
                  ON ledger.local_sequence = event.ledger_local_sequence
                WHERE event.entity_type = ? AND event.entity_id = ?
                ORDER BY event.revision DESC
                LIMIT ?
                """
            )
            try statement.bind([
                .text(entityType),
                .text(entityID.description),
                .integer(Int64(limit)),
            ])
            var revisions: [ProjectedEntity] = []
            while try statement.step() {
                revisions.append(
                    ProjectedEntity(
                        entityType: try statement.text(at: 0),
                        entityID: try SQLiteValueCodec.uuidV7(statement.text(at: 1)),
                        revision: Int(statement.int64(at: 2)),
                        document: try statement.data(at: 3),
                        tombstone: try statement.text(at: 4) == LedgerMutationType.delete.rawValue,
                        sourceEventID: try SQLiteValueCodec.uuidV7(statement.text(at: 5)),
                        updatedAt: try SQLiteValueCodec.date(statement.text(at: 6))
                    )
                )
            }
            return revisions
        }
    }

    public func searchProjections(
        matching query: String,
        entityType: String? = nil,
        limit: Int = 50
    ) throws -> [ProjectionSearchResult] {
        guard (1 ... 100).contains(limit) else {
            throw SQLiteLedgerError.invalidConfiguration(
                "Projection search limit must be between 1 and 100."
            )
        }
        let matchQuery = try Self.ftsMatchQuery(query)
        return try withRead {
            let statement = try connection.statement(
                """
                SELECT projection.entity_type, projection.entity_id,
                       projection.revision, projection.document, projection.tombstone,
                       projection.source_event_id, projection.updated_at,
                       snippet(projection_search, 2, '[', ']', ' … ', 16),
                       bm25(projection_search)
                FROM projection_search
                JOIN entity_projections AS projection
                  ON projection.entity_type = projection_search.entity_type
                 AND projection.entity_id = projection_search.entity_id
                WHERE projection_search MATCH ?
                  AND (? IS NULL OR projection.entity_type = ?)
                ORDER BY bm25(projection_search), projection.updated_at DESC
                LIMIT ?
                """
            )
            try statement.bind([
                .text(matchQuery),
                entityType.map(SQLiteValue.text) ?? .null,
                entityType.map(SQLiteValue.text) ?? .null,
                .integer(Int64(limit)),
            ])
            var results: [ProjectionSearchResult] = []
            while try statement.step() {
                results.append(
                    ProjectionSearchResult(
                        entity: try Self.decodeProjectedEntity(statement),
                        snippet: try statement.text(at: 7),
                        rank: statement.double(at: 8)
                    )
                )
            }
            return results
        }
    }

    public func observeProjections(
        entityType: String? = nil
    ) -> AsyncThrowingStream<[ProjectedEntity], Error> {
        let observation = ValueObservation.tracking { database in
            try database.registerAccess(to: Table("entity_projections"))
            return try Self.readProjectedEntities(
                from: SQLiteSession(database: database),
                entityType: entityType
            )
        }
        let values = observation.values(
            in: databasePool,
            bufferingPolicy: .bufferingNewest(1)
        )
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await value in values {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func readProjectedEntities(
        from connection: SQLiteSession,
        entityType: String?
    ) throws -> [ProjectedEntity] {
        let statement = try connection.statement(
            """
            SELECT entity_type, entity_id, revision, document, tombstone,
                   source_event_id, updated_at
            FROM entity_projections
            WHERE (? IS NULL OR entity_type = ?)
            ORDER BY entity_type, entity_id
            """
        )
        try statement.bind([
            entityType.map(SQLiteValue.text) ?? .null,
            entityType.map(SQLiteValue.text) ?? .null,
        ])
        var entities: [ProjectedEntity] = []
        while try statement.step() {
            entities.append(try decodeProjectedEntity(statement))
        }
        return entities
    }

    private static func ftsMatchQuery(_ query: String) throws -> String {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            throw SQLiteLedgerError.invalidConfiguration(
                "Projection search requires at least one non-whitespace term."
            )
        }
        return terms
            .map { term in
                let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            .joined(separator: " AND ")
    }
}
