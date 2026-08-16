import Foundation
import OdysseyCalendar
import OdysseyDomain
import OdysseyIntegrations
import Testing

private let calendarContractDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func calendarMirrorPreservesMutableSourceCancellationAndTimeZoneSemantics() throws {
    let item = try calendarItem(status: .canceled)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let roundTrip = try decoder.decode(
        CalendarMirrorItem.self,
        from: encoder.encode(item)
    )

    #expect(roundTrip == item)
    #expect(roundTrip.isCanceled)
    #expect(roundTrip.source.sourceKind == .calDAV)
    #expect(roundTrip.sourceVersion == calendarContractDate)
    #expect(roundTrip.timeZone.timeZoneID == "America/New_York")
    #expect(roundTrip.timeZone.startUTCOffsetSeconds == -14_400)
    #expect(roundTrip.identity.storageIdentifier.hasPrefix("event_"))
    #expect(!roundTrip.identity.storageIdentifier.contains("/"))
}

@Test
func calendarMirrorRetainsExclusiveLocalDateBoundsForAllDayEvents() throws {
    let interval = try TemporalInterval(
        start: .localDate(LocalDate(year: 2026, month: 8, day: 16)),
        end: .localDate(LocalDate(year: 2026, month: 8, day: 18)),
        timeZoneID: "Pacific/Auckland",
        startPrecision: .day,
        endPrecision: .day,
        allDaySemantics: true
    )
    let item = try CalendarMirrorItem(
        identity: CalendarEventIdentity(eventIdentifier: "all-day-1"),
        title: "Synthetic travel block",
        interval: interval,
        source: calendarSource(),
        sourceVersion: calendarContractDate,
        status: .confirmed,
        availability: .busy,
        timeZone: CalendarTimeZoneContext(
            timeZoneID: "Pacific/Auckland",
            source: .event,
            startUTCOffsetSeconds: 43_200,
            endUTCOffsetSeconds: 43_200
        ),
        hasRecurrenceRules: false
    )

    #expect(item.interval.allDaySemantics)
    #expect(item.interval.start == .localDate(LocalDate(
        year: 2026,
        month: 8,
        day: 16
    )))
    #expect(item.interval.end == .localDate(LocalDate(
        year: 2026,
        month: 8,
        day: 18
    )))
    #expect(throws: CalendarMirrorError.invalidWindow) {
        try CalendarQueryWindow(
            startDate: calendarContractDate,
            endDate: calendarContractDate,
            timeZoneID: "UTC"
        )
    }
}

@Test
func syntheticCalendarAdapterMakesDeniedAccessAndBoundedWindowsExplicit() async throws {
    let window = try calendarWindow()
    let denied = SyntheticCalendarAdapter(
        capability: CalendarMirrorCapability(
            availability: .available,
            supportsFullAccessRead: true
        ),
        initialPermission: .denied,
        authorizationAfterRequest: .denied,
        clock: { calendarContractDate }
    )
    let deniedPage = try await denied.events(in: window)
    #expect(deniedPage.outcome == .permissionDenied)

    let page = try CalendarMirrorPage(
        window: window,
        queriedAt: calendarContractDate,
        items: [calendarItem(status: .confirmed)],
        outcome: .imported
    )
    let authorized = SyntheticCalendarAdapter(
        capability: CalendarMirrorCapability(
            availability: .available,
            supportsFullAccessRead: true
        ),
        initialPermission: .notDetermined,
        authorizationAfterRequest: .authorized,
        pages: [SyntheticCalendarPage(expectedWindow: window, page: page)]
    )
    #expect(try await authorized.events(in: window).outcome == .permissionDenied)
    #expect(try await authorized.requestReadAuthorization() == .authorized)
    #expect(try await authorized.events(in: window) == page)
}

private func calendarItem(
    status: CalendarEventStatus
) throws -> CalendarMirrorItem {
    try CalendarMirrorItem(
        identity: CalendarEventIdentity(
            eventIdentifier: "event-00000000-0000-4000-8000-000000000001",
            calendarItemExternalIdentifier: "provider-event-1"
        ),
        title: "Synthetic planning block",
        interval: TemporalInterval(
            start: .instant(calendarContractDate.addingTimeInterval(3_600)),
            end: .instant(calendarContractDate.addingTimeInterval(7_200)),
            timeZoneID: "America/New_York",
            startPrecision: .exact,
            endPrecision: .exact
        ),
        source: calendarSource(),
        sourceVersion: calendarContractDate,
        status: status,
        availability: .busy,
        timeZone: CalendarTimeZoneContext(
            timeZoneID: "America/New_York",
            source: .event,
            startUTCOffsetSeconds: -14_400,
            endUTCOffsetSeconds: -14_400
        ),
        hasRecurrenceRules: true
    )
}

private func calendarSource() throws -> CalendarSourceMetadata {
    try CalendarSourceMetadata(
        calendarIdentifier: "calendar-1",
        calendarTitle: "Synthetic Calendar",
        sourceIdentifier: "source-1",
        sourceTitle: "Synthetic Account",
        sourceKind: .calDAV,
        allowsContentModifications: true
    )
}

private func calendarWindow() throws -> CalendarQueryWindow {
    try CalendarQueryWindow(
        startDate: calendarContractDate,
        endDate: calendarContractDate.addingTimeInterval(7 * 24 * 60 * 60),
        timeZoneID: "UTC"
    )
}
