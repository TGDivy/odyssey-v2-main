#if canImport(EventKit)
@preconcurrency import EventKit
import Foundation
import OdysseyDomain
import OdysseyIntegrations

public actor EventKitCalendarAdapter: CalendarContextProviding {
    private let eventStore: EKEventStore
    private let clock: @Sendable () -> Date

    public init(
        eventStore: EKEventStore = EKEventStore(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.eventStore = eventStore
        self.clock = clock
    }

    public func capability() async -> CalendarMirrorCapability {
        CalendarMirrorCapability(
            availability: .available,
            supportsFullAccessRead: true
        )
    }

    public func authorizationState() async -> IntegrationPermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .fullAccess, .authorized:
            .authorized
        case .writeOnly:
            .partial
        @unknown default:
            .unavailable
        }
    }

    public func requestReadAuthorization() async throws -> IntegrationPermissionState {
        let current = await authorizationState()
        switch current {
        case .authorized:
            return .authorized
        case .denied, .restricted, .unavailable:
            return current
        case .notDetermined, .notRequired, .partial:
            break
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            eventStore.requestFullAccessToEvents { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return await authorizationState()
    }

    public func events(
        in window: CalendarQueryWindow
    ) async throws -> CalendarMirrorPage {
        let permission = await authorizationState()
        guard permission == .authorized else {
            return try unavailablePage(
                window: window,
                permission: permission
            )
        }
        let predicate = eventStore.predicateForEvents(
            withStart: window.startDate,
            end: window.endDate,
            calendars: nil
        )
        let matched = eventStore.events(matching: predicate)
        var rejectedCount = 0
        var items = [CalendarMirrorItem]()
        for event in matched {
            do {
                items.append(try Self.mirrorItem(
                    event,
                    queryTimeZoneID: window.timeZoneID
                ))
            } catch {
                rejectedCount += 1
            }
        }
        items.sort {
            if $0.interval.start != $1.interval.start {
                return Self.boundaryIsBefore(
                    $0.interval.start,
                    $1.interval.start
                )
            }
            return $0.identity.storageIdentifier
                < $1.identity.storageIdentifier
        }
        return try CalendarMirrorPage(
            window: window,
            queriedAt: clock(),
            items: items,
            outcome: .imported,
            rejectedRecordCount: rejectedCount
        )
    }

    private func unavailablePage(
        window: CalendarQueryWindow,
        permission: IntegrationPermissionState
    ) throws -> CalendarMirrorPage {
        let outcome: CalendarMirrorOutcome = switch permission {
        case .restricted:
            .restricted
        case .unavailable:
            .unavailable
        default:
            .permissionDenied
        }
        return try CalendarMirrorPage(
            window: window,
            queriedAt: clock(),
            items: [],
            outcome: outcome
        )
    }

    private static func mirrorItem(
        _ event: EKEvent,
        queryTimeZoneID: String
    ) throws -> CalendarMirrorItem {
        guard let startDate = event.startDate,
              let endDate = event.endDate,
              let calendar = event.calendar
        else {
            throw CalendarMirrorError.invalidInterval
        }
        let identifier = try CalendarEventIdentity(
            eventIdentifier: event.eventIdentifier
                ?? event.calendarItemIdentifier,
            calendarItemExternalIdentifier: normalizedOptionalText(
                event.calendarItemExternalIdentifier
            )
        )
        let zoneSelection = try selectedTimeZone(
            event.timeZone,
            queryTimeZoneID: queryTimeZoneID
        )
        let interval: TemporalInterval
        if event.isAllDay {
            interval = try TemporalInterval(
                start: .localDate(try localDate(startDate, in: zoneSelection.zone)),
                end: .localDate(try localDate(endDate, in: zoneSelection.zone)),
                timeZoneID: zoneSelection.zone.identifier,
                startPrecision: .day,
                endPrecision: .day,
                allDaySemantics: true
            )
        } else {
            interval = try TemporalInterval(
                start: .instant(startDate),
                end: .instant(endDate),
                timeZoneID: zoneSelection.zone.identifier,
                startPrecision: .exact,
                endPrecision: .exact
            )
        }
        let source = calendar.source
        return try CalendarMirrorItem(
            identity: identifier,
            title: normalizedOptionalText(event.title),
            interval: interval,
            source: CalendarSourceMetadata(
                calendarIdentifier: calendar.calendarIdentifier,
                calendarTitle: normalizedOptionalText(calendar.title),
                sourceIdentifier: source.sourceIdentifier,
                sourceTitle: normalizedOptionalText(source.title),
                sourceKind: sourceKind(source.sourceType),
                allowsContentModifications: calendar.allowsContentModifications
            ),
            sourceVersion: event.lastModifiedDate,
            status: status(event.status),
            availability: availability(event.availability),
            timeZone: CalendarTimeZoneContext(
                timeZoneID: zoneSelection.zone.identifier,
                source: zoneSelection.source,
                startUTCOffsetSeconds: zoneSelection.zone.secondsFromGMT(
                    for: startDate
                ),
                endUTCOffsetSeconds: zoneSelection.zone.secondsFromGMT(
                    for: endDate
                )
            ),
            hasRecurrenceRules: !(event.recurrenceRules?.isEmpty ?? true)
        )
    }

    private static func selectedTimeZone(
        _ eventTimeZone: TimeZone?,
        queryTimeZoneID: String
    ) throws -> (zone: TimeZone, source: CalendarTimeZoneSource) {
        if let eventTimeZone,
           TimeZone(identifier: eventTimeZone.identifier) != nil
        {
            return (eventTimeZone, .event)
        }
        guard let queryZone = TimeZone(identifier: queryTimeZoneID) else {
            throw CalendarMirrorError.invalidTimeZone
        }
        return (queryZone, .queryDefault)
    }

    private static func localDate(
        _ date: Date,
        in timeZone: TimeZone
    ) throws -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            throw CalendarMirrorError.invalidClock
        }
        return LocalDate(year: year, month: month, day: day)
    }

    private static func status(_ status: EKEventStatus) -> CalendarEventStatus {
        switch status {
        case .none:
            .none
        case .confirmed:
            .confirmed
        case .tentative:
            .tentative
        case .canceled:
            .canceled
        @unknown default:
            .none
        }
    }

    private static func availability(
        _ availability: EKEventAvailability
    ) -> CalendarEventAvailability {
        switch availability {
        case .notSupported:
            .unsupported
        case .busy:
            .busy
        case .free:
            .free
        case .tentative:
            .tentative
        case .unavailable:
            .unavailable
        @unknown default:
            .unsupported
        }
    }

    private static func sourceKind(_ type: EKSourceType) -> CalendarSourceKind {
        switch type {
        case .local:
            .local
        case .exchange:
            .exchange
        case .calDAV:
            .calDAV
        case .mobileMe:
            .mobileMe
        case .subscribed:
            .subscribed
        case .birthdays:
            .birthdays
        @unknown default:
            .unknown
        }
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func boundaryIsBefore(
        _ left: TemporalBoundary?,
        _ right: TemporalBoundary?
    ) -> Bool {
        switch (left, right) {
        case let (.instant(leftDate), .instant(rightDate)):
            return leftDate < rightDate
        case let (.localDate(leftDate), .localDate(rightDate)):
            return leftDate < rightDate
        case (.instant, .localDate), (.instant, nil), (.localDate, nil):
            return true
        case (.localDate, .instant), (nil, .instant), (nil, .localDate), (nil, nil):
            return false
        }
    }
}
#endif
