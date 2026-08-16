import Foundation
import OdysseyDomain

public enum LocalApplicationStateError: Error, Equatable, Sendable {
    case invalidKey
    case invalidSchemaVersion
    case invalidDocument
    case invalidClock
}

public struct LocalApplicationStateRecord: Hashable, Sendable {
    public let key: String
    public let schemaVersion: Int
    public let document: Data
    public let documentSHA256: String
    public let updatedAt: Date

    public init(
        key: String,
        schemaVersion: Int,
        document: Data,
        updatedAt: Date
    ) throws {
        try Self.validate(
            key: key,
            schemaVersion: schemaVersion,
            document: document,
            updatedAt: updatedAt
        )
        self.key = key
        self.schemaVersion = schemaVersion
        self.document = document
        documentSHA256 = SHA256Digest.hexDigest(of: document)
        self.updatedAt = updatedAt
    }

    init(
        key: String,
        schemaVersion: Int,
        document: Data,
        documentSHA256: String,
        updatedAt: Date
    ) throws {
        try Self.validate(
            key: key,
            schemaVersion: schemaVersion,
            document: document,
            updatedAt: updatedAt
        )
        guard SHA256Digest.hexDigest(of: document) == documentSHA256 else {
            throw SQLiteLedgerError.integrityFailure(
                "A local application-state document failed hash verification."
            )
        }
        self.key = key
        self.schemaVersion = schemaVersion
        self.document = document
        self.documentSHA256 = documentSHA256
        self.updatedAt = updatedAt
    }

    private static func validate(
        key: String,
        schemaVersion: Int,
        document: Data,
        updatedAt: Date
    ) throws {
        guard validKey(key) else { throw LocalApplicationStateError.invalidKey }
        guard schemaVersion >= 1 else {
            throw LocalApplicationStateError.invalidSchemaVersion
        }
        guard (1 ... 65_536).contains(document.count) else {
            throw LocalApplicationStateError.invalidDocument
        }
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LocalApplicationStateError.invalidClock
        }
    }

    static func validKey(_ value: String) -> Bool {
        (1 ... 100).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.allSatisfy {
                (48 ... 57).contains($0)
                    || (65 ... 90).contains($0)
                    || (97 ... 122).contains($0)
                    || [45, 46, 95].contains($0)
            }
    }
}

public protocol LocalApplicationStateStoring: Sendable {
    func localApplicationState(
        for key: String
    ) throws -> LocalApplicationStateRecord?
    @discardableResult
    func putLocalApplicationState(
        key: String,
        schemaVersion: Int,
        document: Data,
        updatedAt: Date
    ) throws -> LocalApplicationStateRecord
    @discardableResult
    func removeLocalApplicationState(for key: String) throws -> Bool
}

extension SQLiteLedgerStore: LocalApplicationStateStoring {
    public func localApplicationState(
        for key: String
    ) throws -> LocalApplicationStateRecord? {
        guard LocalApplicationStateRecord.validKey(key) else {
            throw LocalApplicationStateError.invalidKey
        }
        return try withRead {
            let statement = try connection.statement(
                """
                SELECT schema_version, document, document_sha256, updated_at
                FROM local_application_state
                WHERE state_key = ?
                """
            )
            try statement.bind([.text(key)])
            guard try statement.step() else { return nil }
            return try LocalApplicationStateRecord(
                key: key,
                schemaVersion: Int(statement.int64(at: 0)),
                document: statement.data(at: 1),
                documentSHA256: statement.text(at: 2),
                updatedAt: SQLiteValueCodec.date(statement.text(at: 3))
            )
        }
    }

    @discardableResult
    public func putLocalApplicationState(
        key: String,
        schemaVersion: Int,
        document: Data,
        updatedAt: Date
    ) throws -> LocalApplicationStateRecord {
        let record = try LocalApplicationStateRecord(
            key: key,
            schemaVersion: schemaVersion,
            document: document,
            updatedAt: updatedAt
        )
        return try withWrite {
            let statement = try connection.statement(
                """
                INSERT INTO local_application_state (
                    state_key, schema_version, document, document_sha256, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (state_key) DO UPDATE SET
                    schema_version = excluded.schema_version,
                    document = excluded.document,
                    document_sha256 = excluded.document_sha256,
                    updated_at = excluded.updated_at
                """
            )
            try statement.bind([
                .text(record.key),
                .integer(Int64(record.schemaVersion)),
                .blob(record.document),
                .text(record.documentSHA256),
                .text(SQLiteValueCodec.dateString(record.updatedAt)),
            ])
            _ = try statement.step()
            return record
        }
    }

    @discardableResult
    public func removeLocalApplicationState(for key: String) throws -> Bool {
        guard LocalApplicationStateRecord.validKey(key) else {
            throw LocalApplicationStateError.invalidKey
        }
        return try withWrite {
            let statement = try connection.statement(
                "DELETE FROM local_application_state WHERE state_key = ?"
            )
            try statement.bind([.text(key)])
            _ = try statement.step()
            return try connection.scalarInt("SELECT changes()") == 1
        }
    }

    func verifyLocalApplicationState() throws {
        let statement = try connection.statement(
            """
            SELECT state_key, schema_version, document, document_sha256, updated_at
            FROM local_application_state
            ORDER BY state_key
            """
        )
        while try statement.step() {
            _ = try LocalApplicationStateRecord(
                key: statement.text(at: 0),
                schemaVersion: Int(statement.int64(at: 1)),
                document: statement.data(at: 2),
                documentSHA256: statement.text(at: 3),
                updatedAt: SQLiteValueCodec.date(statement.text(at: 4))
            )
        }
    }
}
