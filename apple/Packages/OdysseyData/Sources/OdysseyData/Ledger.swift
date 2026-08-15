import Foundation
import OdysseyDomain

public struct LedgerEntry: Codable, Hashable, Sendable {
    public let eventID: UUIDv7
    public let eventType: String
    public let aggregateType: String
    public let aggregateID: UUIDv7
    public let occurredAt: Date
    public let recordedAt: Date
    public let payload: Data
    public let provenanceID: UUID

    public init(
        eventID: UUIDv7 = UUIDv7(),
        eventType: String,
        aggregateType: String,
        aggregateID: UUIDv7,
        occurredAt: Date,
        recordedAt: Date,
        payload: Data,
        provenanceID: UUID
    ) {
        self.eventID = eventID
        self.eventType = eventType
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.payload = payload
        self.provenanceID = provenanceID
    }
}

public protocol LedgerStore: Sendable {
    func append(_ entry: LedgerEntry) async throws
    func entries(after eventID: UUIDv7?, limit: Int) async throws -> [LedgerEntry]
}

public protocol ProjectionRebuilder: Sendable {
    func rebuildAll() async throws
    func verifyIntegrity() async throws
}

public protocol OwnerExporter: Sendable {
    func exportAll(to destination: URL) async throws -> URL
}

