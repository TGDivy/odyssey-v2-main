import Foundation
import OdysseyDomain

public struct CalendarMirrorItem: Codable, Hashable, Sendable {
    public let externalIdentifier: String
    public let title: String
    public let interval: TemporalInterval
    public let calendarIdentifier: String
    public let lastModifiedAt: Date?
}

public protocol CalendarContextProviding: Sendable {
    func requestIncrementalAuthorization() async throws
    func events(in interval: TemporalInterval) async throws -> [CalendarMirrorItem]
}

#if canImport(EventKit)
import EventKit

public actor EventKitAdapter: CalendarContextProviding {
    private let eventStore: EKEventStore

    public init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    public func requestIncrementalAuthorization() async throws {}

    public func events(in _: TemporalInterval) async throws -> [CalendarMirrorItem] { [] }
}
#endif

