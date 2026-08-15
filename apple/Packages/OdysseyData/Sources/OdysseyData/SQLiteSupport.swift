import CSQLite
import Foundation
import GRDB
import OdysseyDomain

public enum SQLiteLedgerError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidLedgerEntry(String)
    case invalidProjection(String)
    case invalidSyncMutation(String)
    case invalidSyncResult(String)
    case invalidRemoteChange(String)
    case invalidLifeModelCommand(String)
    case unknownLedgerEvent(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case deviceIdentityMismatch(expected: String, found: String)
    case integrityFailure(String)
    case sqlite(code: Int32, message: String)
}

extension SQLiteLedgerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message),
             let .invalidLedgerEntry(message),
             let .invalidProjection(message),
             let .invalidSyncMutation(message),
             let .invalidSyncResult(message),
             let .invalidRemoteChange(message),
             let .invalidLifeModelCommand(message),
             let .integrityFailure(message):
            message
        case let .unknownLedgerEvent(eventID):
            "Ledger event does not exist: \(eventID)"
        case let .unsupportedSchemaVersion(found, supported):
            "Database schema version \(found) is newer than supported version \(supported)."
        case let .deviceIdentityMismatch(expected, found):
            "Database belongs to device \(found), not configured device \(expected)."
        case let .sqlite(code, message):
            "SQLite error \(code): \(message)"
        }
    }
}

enum SQLiteValue {
    case integer(Int64)
    case text(String)
    case blob(Data)
    case null
}

final class SQLiteSession {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message: String
            if let errorPointer {
                message = String(cString: errorPointer)
                sqlite3_free(errorPointer)
            } else {
                message = errorMessage
            }
            throw SQLiteLedgerError.sqlite(code: result, message: message)
        }
    }

    func statement(_ sql: String) throws -> SQLiteRowStatement {
        try SQLiteRowStatement(connection: self, sql: sql)
    }

    func scalarInt(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int64 {
        let statement = try statement(sql)
        try statement.bind(bindings)
        guard try statement.step() else {
            throw SQLiteLedgerError.sqlite(code: SQLITE_NOTFOUND, message: "query returned no rows")
        }
        return statement.int64(at: 0)
    }

    func scalarText(_ sql: String, bindings: [SQLiteValue] = []) throws -> String? {
        let statement = try statement(sql)
        try statement.bind(bindings)
        guard try statement.step() else {
            return nil
        }
        return statement.optionalText(at: 0)
    }

    var lastInsertedRowID: Int64 {
        database.lastInsertedRowID
    }

    var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    func notifyChanges() throws {
        try database.notifyChanges(in: DatabaseRegion.fullDatabase)
    }

    var handle: OpaquePointer {
        guard let handle = database.sqliteConnection else {
            preconditionFailure("GRDB database connection is closed.")
        }
        return handle
    }
}

final class SQLiteRowStatement {
    private unowned let connection: SQLiteSession
    private let handle: OpaquePointer

    init(connection: SQLiteSession, sql: String) throws {
        self.connection = connection
        var preparedHandle: OpaquePointer?
        let result = sqlite3_prepare_v2(connection.handle, sql, -1, &preparedHandle, nil)
        guard result == SQLITE_OK, let preparedHandle else {
            throw SQLiteLedgerError.sqlite(code: result, message: connection.errorMessage)
        }
        handle = preparedHandle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1))
        }
    }

    func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteLedgerError.sqlite(code: result, message: connection.errorMessage)
        }
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func text(at index: Int32) throws -> String {
        guard let text = optionalText(at: index) else {
            throw SQLiteLedgerError.sqlite(code: SQLITE_MISMATCH, message: "unexpected NULL text column")
        }
        return text
    }

    func optionalText(at index: Int32) -> String? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(handle, index)
        else {
            return nil
        }
        return String(cString: pointer)
    }

    func data(at index: Int32) throws -> Data {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else {
            throw SQLiteLedgerError.sqlite(code: SQLITE_MISMATCH, message: "unexpected NULL blob column")
        }
        let count = Int(sqlite3_column_bytes(handle, index))
        guard count > 0 else {
            return Data()
        }
        guard let pointer = sqlite3_column_blob(handle, index) else {
            throw SQLiteLedgerError.sqlite(code: SQLITE_MISMATCH, message: "invalid blob column")
        }
        return Data(bytes: pointer, count: count)
    }

    private func bind(_ value: SQLiteValue, at index: Int32) throws {
        let result: Int32
        switch value {
        case let .integer(integer):
            result = sqlite3_bind_int64(handle, index, integer)
        case let .text(text):
            result = text.withCString { pointer in
                sqlite3_bind_text(handle, index, pointer, -1, sqliteTransient)
            }
        case let .blob(data):
            if data.isEmpty {
                result = sqlite3_bind_zeroblob(handle, index, 0)
            } else {
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            }
        case .null:
            result = sqlite3_bind_null(handle, index)
        }
        guard result == SQLITE_OK else {
            throw SQLiteLedgerError.sqlite(code: result, message: connection.errorMessage)
        }
    }

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}

enum SQLiteValueCodec {
    static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw SQLiteLedgerError.integrityFailure("Invalid stored timestamp: \(value)")
        }
        return date
    }

    static func uuidV7(_ value: String) throws -> UUIDv7 {
        guard let identifier = UUID(uuidString: value) else {
            throw SQLiteLedgerError.integrityFailure("Invalid stored UUID: \(value)")
        }
        do {
            return try UUIDv7(validating: identifier)
        } catch {
            throw SQLiteLedgerError.integrityFailure("Stored UUID is not version 7: \(value)")
        }
    }
}
