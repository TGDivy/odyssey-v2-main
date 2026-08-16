import Foundation
import OdysseyIntegrations

extension SQLiteLedgerStore: IntegrationLocalRecordStoring {
    public func integrationSnapshot(
        connector: IntegrationConnector,
        stream: String
    ) async throws -> IntegrationLocalSnapshot {
        guard Self.validIntegrationToken(stream, maximum: 100) else {
            throw IntegrationLocalStoreError.invalidStream
        }
        return try withRead {
            let statement = try connection.statement(
                """
                SELECT external_identifier, source_timestamp, document,
                       document_sha256
                FROM integration_records
                WHERE connector = ? AND stream = ?
                ORDER BY external_identifier
                """
            )
            try statement.bind([
                .text(connector.rawValue),
                .text(stream),
            ])
            var records = [IntegrationLocalRecord]()
            while try statement.step() {
                let document = try statement.data(at: 2)
                let expectedHash = try statement.text(at: 3)
                guard SHA256Digest.hexDigest(of: document) == expectedHash else {
                    throw SQLiteLedgerError.integrityFailure(
                        "A local integration record failed hash verification."
                    )
                }
                records.append(try IntegrationLocalRecord(
                    connector: connector,
                    stream: stream,
                    externalIdentifier: statement.text(at: 0),
                    sourceTimestamp: SQLiteValueCodec.date(statement.text(at: 1)),
                    document: document
                ))
            }
            let cursor = try readIntegrationCursor(
                connector: connector,
                stream: stream
            )
            return IntegrationLocalSnapshot(
                connector: connector,
                stream: stream,
                records: records,
                cursor: cursor
            )
        }
    }

    public func applyIntegrationPage(
        _ page: IntegrationLocalPage
    ) async throws -> IntegrationLocalApplyReceipt {
        try withWrite {
            var insertedCount = 0
            var updatedCount = 0
            var deletedCount = 0
            var duplicateCount = 0
            var rejectedCount = 0

            for identifier in page.deletedExternalIdentifiers {
                let deletion = try connection.statement(
                    """
                    DELETE FROM integration_records
                    WHERE connector = ? AND stream = ? AND external_identifier = ?
                    """
                )
                try deletion.bind([
                    .text(page.connector.rawValue),
                    .text(page.stream),
                    .text(identifier),
                ])
                _ = try deletion.step()
                deletedCount += Int(try connection.scalarInt("SELECT changes()"))
            }

            for record in page.records {
                let lookup = try connection.statement(
                    """
                    SELECT document, document_sha256
                    FROM integration_records
                    WHERE connector = ? AND stream = ? AND external_identifier = ?
                    """
                )
                try lookup.bind([
                    .text(page.connector.rawValue),
                    .text(page.stream),
                    .text(record.externalIdentifier),
                ])
                let documentHash = SHA256Digest.hexDigest(of: record.document)
                if try lookup.step() {
                    let existingDocument = try lookup.data(at: 0)
                    let existingHash = try lookup.text(at: 1)
                    guard SHA256Digest.hexDigest(of: existingDocument) == existingHash else {
                        throw SQLiteLedgerError.integrityFailure(
                            "A local integration record failed hash verification."
                        )
                    }
                    if existingHash == documentHash,
                       existingDocument == record.document
                    {
                        duplicateCount += 1
                    } else if page.allowsUpdates {
                        let update = try connection.statement(
                            """
                            UPDATE integration_records
                            SET source_timestamp = ?, document = ?, document_sha256 = ?,
                                imported_at = ?
                            WHERE connector = ? AND stream = ?
                              AND external_identifier = ?
                            """
                        )
                        try update.bind([
                            .text(SQLiteValueCodec.dateString(record.sourceTimestamp)),
                            .blob(record.document),
                            .text(documentHash),
                            .text(SQLiteValueCodec.dateString(page.appliedAt)),
                            .text(page.connector.rawValue),
                            .text(page.stream),
                            .text(record.externalIdentifier),
                        ])
                        _ = try update.step()
                        guard try connection.scalarInt("SELECT changes()") == 1 else {
                            throw SQLiteLedgerError.integrityFailure(
                                "A local integration update did not affect one record."
                            )
                        }
                        updatedCount += 1
                    } else {
                        rejectedCount += 1
                    }
                } else {
                    let insertion = try connection.statement(
                        """
                        INSERT INTO integration_records (
                            connector, stream, external_identifier, source_timestamp,
                            document, document_sha256, imported_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """
                    )
                    try insertion.bind([
                        .text(page.connector.rawValue),
                        .text(page.stream),
                        .text(record.externalIdentifier),
                        .text(SQLiteValueCodec.dateString(record.sourceTimestamp)),
                        .blob(record.document),
                        .text(documentHash),
                        .text(SQLiteValueCodec.dateString(page.appliedAt)),
                    ])
                    _ = try insertion.step()
                    insertedCount += 1
                }
            }

            if let nextCursor = page.nextCursor {
                let cursor = try connection.statement(
                    """
                    INSERT INTO integration_cursors (
                        connector, stream, cursor, updated_at
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT (connector, stream) DO UPDATE SET
                        cursor = excluded.cursor,
                        updated_at = excluded.updated_at
                    """
                )
                try cursor.bind([
                    .text(page.connector.rawValue),
                    .text(page.stream),
                    .blob(nextCursor),
                    .text(SQLiteValueCodec.dateString(page.appliedAt)),
                ])
                _ = try cursor.step()
            }
            return IntegrationLocalApplyReceipt(
                insertedCount: insertedCount,
                updatedCount: updatedCount,
                deletedCount: deletedCount,
                duplicateCount: duplicateCount,
                rejectedCount: rejectedCount
            )
        }
    }

    public func clearIntegrationData(
        connector: IntegrationConnector
    ) async throws -> Int {
        try withWrite {
            let records = try connection.statement(
                "DELETE FROM integration_records WHERE connector = ?"
            )
            try records.bind([.text(connector.rawValue)])
            _ = try records.step()
            let removedCount = Int(try connection.scalarInt("SELECT changes()"))
            let cursors = try connection.statement(
                "DELETE FROM integration_cursors WHERE connector = ?"
            )
            try cursors.bind([.text(connector.rawValue)])
            _ = try cursors.step()
            return removedCount
        }
    }

    private func readIntegrationCursor(
        connector: IntegrationConnector,
        stream: String
    ) throws -> Data? {
        let statement = try connection.statement(
            """
            SELECT cursor
            FROM integration_cursors
            WHERE connector = ? AND stream = ?
            """
        )
        try statement.bind([
            .text(connector.rawValue),
            .text(stream),
        ])
        guard try statement.step() else { return nil }
        return try statement.data(at: 0)
    }

    private static func validIntegrationToken(
        _ value: String,
        maximum: Int
    ) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.allSatisfy {
                (48 ... 57).contains($0)
                    || (65 ... 90).contains($0)
                    || (97 ... 122).contains($0)
                    || [45, 46, 58, 95].contains($0)
            }
    }
}
