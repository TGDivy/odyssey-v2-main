import Foundation

public enum IntegrationLocalStoreError: Error, Equatable, Sendable {
    case invalidStream
    case invalidExternalIdentifier
    case invalidClock
    case invalidDocument
    case invalidCursor
    case duplicateRecord
    case duplicateDeletion
    case recordDeletedInSamePage
}

public struct IntegrationLocalRecord: Codable, Hashable, Sendable {
    public static let maximumDocumentBytes = 1_048_576

    public let connector: IntegrationConnector
    public let stream: String
    public let externalIdentifier: String
    public let sourceTimestamp: Date
    public let document: Data

    public init(
        connector: IntegrationConnector,
        stream: String,
        externalIdentifier: String,
        sourceTimestamp: Date,
        document: Data
    ) throws {
        guard Self.validToken(stream, maximum: 100) else {
            throw IntegrationLocalStoreError.invalidStream
        }
        guard Self.validToken(externalIdentifier, maximum: 200) else {
            throw IntegrationLocalStoreError.invalidExternalIdentifier
        }
        guard sourceTimestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw IntegrationLocalStoreError.invalidClock
        }
        guard !document.isEmpty,
              document.count <= Self.maximumDocumentBytes
        else {
            throw IntegrationLocalStoreError.invalidDocument
        }
        self.connector = connector
        self.stream = stream
        self.externalIdentifier = externalIdentifier
        self.sourceTimestamp = sourceTimestamp
        self.document = document
    }

    fileprivate static func validToken(_ value: String, maximum: Int) -> Bool {
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

public struct IntegrationLocalPage: Hashable, Sendable {
    public static let maximumCursorBytes = 64 * 1_024

    public let connector: IntegrationConnector
    public let stream: String
    public let records: [IntegrationLocalRecord]
    public let deletedExternalIdentifiers: [String]
    public let nextCursor: Data?
    public let appliedAt: Date
    public let allowsUpdates: Bool

    public init(
        connector: IntegrationConnector,
        stream: String,
        records: [IntegrationLocalRecord],
        deletedExternalIdentifiers: [String],
        nextCursor: Data?,
        appliedAt: Date,
        allowsUpdates: Bool
    ) throws {
        guard IntegrationLocalRecord.validToken(stream, maximum: 100) else {
            throw IntegrationLocalStoreError.invalidStream
        }
        guard appliedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw IntegrationLocalStoreError.invalidClock
        }
        guard records.allSatisfy({
            $0.connector == connector && $0.stream == stream
        }) else {
            throw IntegrationLocalStoreError.invalidDocument
        }
        let recordIdentifiers = records.map(\.externalIdentifier)
        guard Set(recordIdentifiers).count == records.count else {
            throw IntegrationLocalStoreError.duplicateRecord
        }
        guard deletedExternalIdentifiers.allSatisfy({
            IntegrationLocalRecord.validToken($0, maximum: 200)
        }) else {
            throw IntegrationLocalStoreError.invalidExternalIdentifier
        }
        let deletionSet = Set(deletedExternalIdentifiers)
        guard deletionSet.count == deletedExternalIdentifiers.count else {
            throw IntegrationLocalStoreError.duplicateDeletion
        }
        guard deletionSet.isDisjoint(with: recordIdentifiers) else {
            throw IntegrationLocalStoreError.recordDeletedInSamePage
        }
        guard nextCursor.map({
            !$0.isEmpty && $0.count <= Self.maximumCursorBytes
        }) ?? true else {
            throw IntegrationLocalStoreError.invalidCursor
        }
        self.connector = connector
        self.stream = stream
        self.records = records.sorted {
            $0.externalIdentifier < $1.externalIdentifier
        }
        self.deletedExternalIdentifiers = deletedExternalIdentifiers.sorted()
        self.nextCursor = nextCursor
        self.appliedAt = appliedAt
        self.allowsUpdates = allowsUpdates
    }
}

public struct IntegrationLocalSnapshot: Sendable {
    public let connector: IntegrationConnector
    public let stream: String
    public let records: [IntegrationLocalRecord]
    public let cursor: Data?

    public init(
        connector: IntegrationConnector,
        stream: String,
        records: [IntegrationLocalRecord],
        cursor: Data?
    ) {
        self.connector = connector
        self.stream = stream
        self.records = records
        self.cursor = cursor
    }
}

public struct IntegrationLocalApplyReceipt: Hashable, Sendable {
    public let insertedCount: Int
    public let updatedCount: Int
    public let deletedCount: Int
    public let duplicateCount: Int
    public let rejectedCount: Int

    public init(
        insertedCount: Int,
        updatedCount: Int,
        deletedCount: Int,
        duplicateCount: Int,
        rejectedCount: Int
    ) {
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.deletedCount = deletedCount
        self.duplicateCount = duplicateCount
        self.rejectedCount = rejectedCount
    }
}

public protocol IntegrationLocalRecordStoring: Sendable {
    func integrationSnapshot(
        connector: IntegrationConnector,
        stream: String
    ) async throws -> IntegrationLocalSnapshot
    func applyIntegrationPage(
        _ page: IntegrationLocalPage
    ) async throws -> IntegrationLocalApplyReceipt
    func clearIntegrationData(
        connector: IntegrationConnector
    ) async throws -> Int
}

public actor SyntheticIntegrationLocalStore: IntegrationLocalRecordStoring {
    private struct StreamKey: Hashable {
        let connector: IntegrationConnector
        let stream: String
    }

    private var records = [StreamKey: [String: IntegrationLocalRecord]]()
    private var cursors = [StreamKey: Data]()

    public init() {}

    public func integrationSnapshot(
        connector: IntegrationConnector,
        stream: String
    ) async throws -> IntegrationLocalSnapshot {
        guard IntegrationLocalRecord.validToken(stream, maximum: 100) else {
            throw IntegrationLocalStoreError.invalidStream
        }
        let key = StreamKey(connector: connector, stream: stream)
        return IntegrationLocalSnapshot(
            connector: connector,
            stream: stream,
            records: (records[key] ?? [:]).values.sorted {
                $0.externalIdentifier < $1.externalIdentifier
            },
            cursor: cursors[key]
        )
    }

    public func applyIntegrationPage(
        _ page: IntegrationLocalPage
    ) async throws -> IntegrationLocalApplyReceipt {
        let key = StreamKey(connector: page.connector, stream: page.stream)
        var streamRecords = records[key] ?? [:]
        var insertedCount = 0
        var updatedCount = 0
        var deletedCount = 0
        var duplicateCount = 0
        var rejectedCount = 0

        for identifier in page.deletedExternalIdentifiers {
            if streamRecords.removeValue(forKey: identifier) != nil {
                deletedCount += 1
            }
        }
        for record in page.records {
            if let existing = streamRecords[record.externalIdentifier] {
                if existing.document == record.document {
                    duplicateCount += 1
                } else if page.allowsUpdates {
                    streamRecords[record.externalIdentifier] = record
                    updatedCount += 1
                } else {
                    rejectedCount += 1
                }
            } else {
                streamRecords[record.externalIdentifier] = record
                insertedCount += 1
            }
        }
        records[key] = streamRecords
        if let nextCursor = page.nextCursor {
            cursors[key] = nextCursor
        }
        return IntegrationLocalApplyReceipt(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            deletedCount: deletedCount,
            duplicateCount: duplicateCount,
            rejectedCount: rejectedCount
        )
    }

    public func clearIntegrationData(
        connector: IntegrationConnector
    ) async throws -> Int {
        let keys = records.keys.filter { $0.connector == connector }
        let removedCount = keys.reduce(0) { count, key in
            count + (records[key]?.count ?? 0)
        }
        for key in keys {
            records.removeValue(forKey: key)
            cursors.removeValue(forKey: key)
        }
        let cursorOnlyKeys = cursors.keys.filter { $0.connector == connector }
        for key in cursorOnlyKeys {
            cursors.removeValue(forKey: key)
        }
        return removedCount
    }
}
