import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public actor InMemoryLedgerStore: LedgerStore {
    private var storedEntries: [LedgerEntry] = []

    public init() {}

    public func append(_ entry: LedgerEntry) async throws {
        if !storedEntries.contains(where: { $0.eventID == entry.eventID }) {
            storedEntries.append(entry)
        }
    }

    public func entries(after eventID: UUIDv7?, limit: Int) async throws -> [LedgerEntry] {
        let startIndex: Int
        if let eventID, let index = storedEntries.firstIndex(where: { $0.eventID == eventID }) {
            startIndex = storedEntries.index(after: index)
        } else {
            startIndex = storedEntries.startIndex
        }
        return Array(storedEntries[startIndex...].prefix(limit))
    }
}

public struct SyntheticClock: Sendable {
    public let now: Date

    public init(now: Date) {
        self.now = now
    }
}

