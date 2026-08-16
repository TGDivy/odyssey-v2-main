import Foundation
import OdysseyDomain
import OdysseyIntegrations

public enum CalendarMirrorCoordinatorError: Error, Equatable, Sendable {
    case unexpectedPageWindow
    case invalidStoredDocument
    case invalidStoredCursor
}

public struct CalendarMirrorRunReceipt: Hashable, Sendable {
    public let outcome: CalendarMirrorOutcome
    public let queriedAt: Date
    public let insertedCount: Int
    public let updatedCount: Int
    public let deletedCount: Int
    public let duplicateCount: Int
    public let rejectedCount: Int
    public let cursorAdvanced: Bool

    public init(
        outcome: CalendarMirrorOutcome,
        queriedAt: Date,
        insertedCount: Int,
        updatedCount: Int,
        deletedCount: Int,
        duplicateCount: Int,
        rejectedCount: Int,
        cursorAdvanced: Bool
    ) {
        self.outcome = outcome
        self.queriedAt = queriedAt
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.deletedCount = deletedCount
        self.duplicateCount = duplicateCount
        self.rejectedCount = rejectedCount
        self.cursorAdvanced = cursorAdvanced
    }
}

public struct CalendarLocalSnapshot: Sendable {
    public let items: [CalendarMirrorItem]
    public let lastWindow: CalendarQueryWindow?
    public let lastQueriedAt: Date?

    public init(
        items: [CalendarMirrorItem],
        lastWindow: CalendarQueryWindow?,
        lastQueriedAt: Date?
    ) {
        self.items = items
        self.lastWindow = lastWindow
        self.lastQueriedAt = lastQueriedAt
    }
}

public actor CalendarMirrorCoordinator {
    public static let stream = "events"

    private let adapter: any CalendarContextProviding
    private let store: any IntegrationLocalRecordStoring

    public init(
        adapter: any CalendarContextProviding,
        store: any IntegrationLocalRecordStoring
    ) {
        self.adapter = adapter
        self.store = store
    }

    public func capability() async -> CalendarMirrorCapability {
        await adapter.capability()
    }

    public func authorizationState() async -> IntegrationPermissionState {
        await adapter.authorizationState()
    }

    public func requestReadAuthorization() async throws -> IntegrationPermissionState {
        try await adapter.requestReadAuthorization()
    }

    public func refresh(
        window: CalendarQueryWindow
    ) async throws -> CalendarMirrorRunReceipt {
        let stored = try await store.integrationSnapshot(
            connector: .calendar,
            stream: Self.stream
        )
        let page = try await adapter.events(in: window)
        guard page.window == window else {
            throw CalendarMirrorCoordinatorError.unexpectedPageWindow
        }
        guard page.outcome == .imported else {
            return CalendarMirrorRunReceipt(
                outcome: page.outcome,
                queriedAt: page.queriedAt,
                insertedCount: 0,
                updatedCount: 0,
                deletedCount: 0,
                duplicateCount: 0,
                rejectedCount: page.rejectedRecordCount,
                cursorAdvanced: false
            )
        }

        let existing = try stored.records.map(Self.decodeRecord)
        let normalized = try Self.normalizedItems(
            page.items,
            window: window
        )
        let incomingIdentifiers = Set(normalized.items.map {
            $0.identity.storageIdentifier
        })
        let deletedIdentifiers: [String] = try existing.compactMap { record in
            guard try Self.intersects(record.item, window: window),
                  !incomingIdentifiers.contains(record.storageIdentifier)
            else {
                return nil
            }
            return record.storageIdentifier
        }
        let records = try normalized.items.map { item in
            try IntegrationLocalRecord(
                connector: .calendar,
                stream: Self.stream,
                externalIdentifier: item.identity.storageIdentifier,
                sourceTimestamp: try Self.sourceTimestamp(item),
                document: try Self.encode(CalendarLocalDocument(
                    schemaVersion: 1,
                    item: item
                ))
            )
        }
        let cursor = try Self.encode(CalendarMirrorCursor(
            schemaVersion: 1,
            window: window,
            queriedAt: page.queriedAt
        ))
        let receipt = try await store.applyIntegrationPage(IntegrationLocalPage(
            connector: .calendar,
            stream: Self.stream,
            records: records,
            deletedExternalIdentifiers: deletedIdentifiers,
            nextCursor: cursor,
            appliedAt: page.queriedAt,
            allowsUpdates: true
        ))
        return CalendarMirrorRunReceipt(
            outcome: page.outcome,
            queriedAt: page.queriedAt,
            insertedCount: receipt.insertedCount,
            updatedCount: receipt.updatedCount,
            deletedCount: receipt.deletedCount,
            duplicateCount: normalized.duplicateCount + receipt.duplicateCount,
            rejectedCount: page.rejectedRecordCount
                + normalized.rejectedCount
                + receipt.rejectedCount,
            cursorAdvanced: stored.cursor != cursor
        )
    }

    public func localSnapshot() async throws -> CalendarLocalSnapshot {
        let stored = try await store.integrationSnapshot(
            connector: .calendar,
            stream: Self.stream
        )
        let items = try stored.records.map(Self.decodeRecord).map(\.item).sorted {
            let left = try? Self.absoluteBounds($0).start
            let right = try? Self.absoluteBounds($1).start
            if left != right {
                return (left ?? .distantFuture) < (right ?? .distantFuture)
            }
            return $0.identity.storageIdentifier < $1.identity.storageIdentifier
        }
        let cursor: CalendarMirrorCursor?
        if let storedCursor = stored.cursor {
            do {
                cursor = try Self.decode(
                    CalendarMirrorCursor.self,
                    from: storedCursor
                )
            } catch {
                throw CalendarMirrorCoordinatorError.invalidStoredCursor
            }
            guard cursor?.schemaVersion == 1 else {
                throw CalendarMirrorCoordinatorError.invalidStoredCursor
            }
        } else {
            cursor = nil
        }
        return CalendarLocalSnapshot(
            items: items,
            lastWindow: cursor?.window,
            lastQueriedAt: cursor?.queriedAt
        )
    }

    public func revokeLocalCalendarData() async throws -> Int {
        try await store.clearIntegrationData(connector: .calendar)
    }

    private static func normalizedItems(
        _ items: [CalendarMirrorItem],
        window: CalendarQueryWindow
    ) throws -> NormalizedCalendarItems {
        var accepted = [String: CalendarMirrorItem]()
        var conflicted = Set<String>()
        var duplicateCount = 0
        var rejectedCount = 0
        for item in items {
            guard try intersects(item, window: window) else {
                rejectedCount += 1
                continue
            }
            let identifier = item.identity.storageIdentifier
            guard !conflicted.contains(identifier) else {
                rejectedCount += 1
                continue
            }
            if let prior = accepted[identifier] {
                if prior == item {
                    duplicateCount += 1
                } else {
                    accepted.removeValue(forKey: identifier)
                    conflicted.insert(identifier)
                    rejectedCount += 1
                }
            } else {
                accepted[identifier] = item
            }
        }
        return NormalizedCalendarItems(
            items: Array(accepted.values),
            duplicateCount: duplicateCount,
            rejectedCount: rejectedCount
        )
    }

    private static func decodeRecord(
        _ record: IntegrationLocalRecord
    ) throws -> StoredCalendarRecord {
        let document: CalendarLocalDocument
        do {
            document = try decode(CalendarLocalDocument.self, from: record.document)
        } catch {
            throw CalendarMirrorCoordinatorError.invalidStoredDocument
        }
        guard document.schemaVersion == 1,
              record.connector == .calendar,
              record.stream == Self.stream,
              document.item.identity.storageIdentifier == record.externalIdentifier
        else {
            throw CalendarMirrorCoordinatorError.invalidStoredDocument
        }
        return StoredCalendarRecord(
            storageIdentifier: record.externalIdentifier,
            item: document.item
        )
    }

    private static func intersects(
        _ item: CalendarMirrorItem,
        window: CalendarQueryWindow
    ) throws -> Bool {
        let bounds = try absoluteBounds(item)
        if bounds.start == bounds.end {
            return bounds.start >= window.startDate
                && bounds.start < window.endDate
        }
        return bounds.start < window.endDate
            && bounds.end > window.startDate
    }

    private static func sourceTimestamp(
        _ item: CalendarMirrorItem
    ) throws -> Date {
        if let sourceVersion = item.sourceVersion {
            return sourceVersion
        }
        return try absoluteBounds(item).start
    }

    private static func absoluteBounds(
        _ item: CalendarMirrorItem
    ) throws -> (start: Date, end: Date) {
        switch (item.interval.start, item.interval.end) {
        case let (.instant(start), .instant(end)):
            return (start, end)
        case let (.localDate(start), .localDate(end)):
            guard let zone = TimeZone(identifier: item.timeZone.timeZoneID) else {
                throw CalendarMirrorError.invalidTimeZone
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            guard let startDate = calendar.date(from: DateComponents(
                timeZone: zone,
                year: start.year,
                month: start.month,
                day: start.day
            )), let endDate = calendar.date(from: DateComponents(
                timeZone: zone,
                year: end.year,
                month: end.month,
                day: end.day
            )) else {
                throw CalendarMirrorError.invalidInterval
            }
            return (startDate, endDate)
        default:
            throw CalendarMirrorError.invalidInterval
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

private struct CalendarLocalDocument: Codable {
    let schemaVersion: Int
    let item: CalendarMirrorItem
}

private struct CalendarMirrorCursor: Codable {
    let schemaVersion: Int
    let window: CalendarQueryWindow
    let queriedAt: Date
}

private struct StoredCalendarRecord {
    let storageIdentifier: String
    let item: CalendarMirrorItem
}

private struct NormalizedCalendarItems {
    let items: [CalendarMirrorItem]
    let duplicateCount: Int
    let rejectedCount: Int
}
