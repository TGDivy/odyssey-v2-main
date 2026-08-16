import Foundation
import OdysseyApplication
import OdysseyCalendar
import OdysseyDomain
import OdysseyIntegrations
import OdysseyIntelligence
import OdysseyLocation
import Testing

private let nativeNowDate = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func nativeNowContextUsesCalendarForPreparationAndTomorrowShape() throws {
    let currentPreparation = try nativeCalendarItem(
        identifier: "preparation",
        start: nativeNowDate.addingTimeInterval(90 * 60),
        end: nativeNowDate.addingTimeInterval(150 * 60)
    )
    let tomorrowStart = try nativeDate(
        year: 2026,
        month: 8,
        day: 17,
        hour: 9
    )
    let tomorrow = try nativeCalendarItem(
        identifier: "tomorrow",
        start: tomorrowStart,
        end: tomorrowStart.addingTimeInterval(60 * 60)
    )
    let projection = try NativeNowContextProjector().project(
        NativeNowContextInput(
            generatedAt: nativeNowDate,
            deviceTimeZoneID: "UTC",
            calendarSnapshot: CalendarLocalSnapshot(
                items: [currentPreparation, tomorrow],
                lastWindow: try nativeCalendarWindow(),
                lastQueriedAt: nativeNowDate
            ),
            calendarOverview: try nativeCalendarOverview(
                permission: .authorized,
                itemCount: 2
            )
        )
    )

    #expect(projection.now.state == .preparation)
    #expect(projection.now.nextTransition?.label == "Synthetic preparation")
    #expect(projection.tomorrow.transitions.map(\.identifier)
        == [tomorrow.identity.storageIdentifier])
    #expect(projection.tomorrow.hasEnoughContext)
}

@Test
func nativeNowContextSelectsChoiceForOverlapsAndOpenForKnownSlack() throws {
    let first = try nativeCalendarItem(
        identifier: "first",
        start: nativeNowDate.addingTimeInterval(-600),
        end: nativeNowDate.addingTimeInterval(3_600)
    )
    let second = try nativeCalendarItem(
        identifier: "second",
        start: nativeNowDate.addingTimeInterval(-300),
        end: nativeNowDate.addingTimeInterval(1_800)
    )
    let overview = try nativeCalendarOverview(permission: .authorized, itemCount: 2)
    let choice = try NativeNowContextProjector().project(NativeNowContextInput(
        generatedAt: nativeNowDate,
        deviceTimeZoneID: "UTC",
        calendarSnapshot: CalendarLocalSnapshot(
            items: [first, second],
            lastWindow: try nativeCalendarWindow(),
            lastQueriedAt: nativeNowDate
        ),
        calendarOverview: overview
    ))
    let open = try NativeNowContextProjector().project(NativeNowContextInput(
        generatedAt: nativeNowDate,
        deviceTimeZoneID: "UTC",
        calendarSnapshot: CalendarLocalSnapshot(
            items: [],
            lastWindow: try nativeCalendarWindow(),
            lastQueriedAt: nativeNowDate
        ),
        calendarOverview: try nativeCalendarOverview(
            permission: .authorized,
            itemCount: 0
        )
    ))

    #expect(choice.now.state == .choice)
    #expect(open.now.state == .open)
    #expect(open.tomorrow.isIntentionallyOpen)
}

@Test
func nativeNowContextTreatsFreshCrossZonePlaceAsDisruption() throws {
    let place = try BroadLocationContext(
        placeIdentifier: "synthetic_tokyo",
        displayName: "Synthetic Tokyo",
        timeZoneID: "Asia/Tokyo",
        capturedAt: nativeNowDate.addingTimeInterval(-60),
        expiresAt: nativeNowDate.addingTimeInterval(3_600),
        precision: .locality
    )
    let location = try LocationContextOverview(
        observedAt: nativeNowDate,
        capability: LocationContextCapability(
            availability: .available,
            supportsForegroundBroadPlace: true,
            supportsSignificantChanges: false
        ),
        permission: .authorized,
        cachedPlace: place,
        cacheIsFresh: true,
        lastAttemptAt: nativeNowDate,
        lastSuccessfulRefreshAt: nativeNowDate,
        lastOutcome: .acquired,
        rejectedRecordCount: 0
    )
    let projection = try NativeNowContextProjector().project(NativeNowContextInput(
        generatedAt: nativeNowDate,
        deviceTimeZoneID: "UTC",
        locationOverview: location
    ))

    #expect(projection.now.state == .disrupted)
    #expect(projection.now.timeZoneID == "Asia/Tokyo")
    #expect(projection.now.localDay == LocalDate(year: 2026, month: 8, day: 16))
}

@Test
func nativeNowContextDoesNotCallDeniedCalendarSilenceOpen() throws {
    let projection = try NativeNowContextProjector().project(NativeNowContextInput(
        generatedAt: nativeNowDate,
        deviceTimeZoneID: "UTC",
        calendarOverview: try nativeCalendarOverview(
            permission: .denied,
            itemCount: 0
        )
    ))

    #expect(projection.now.state == .clear)
    #expect(!projection.now.isIntentionallySilent)
    #expect(projection.now.sources.first(where: { $0.source == .calendar })?.state
        == .denied)
    #expect(!projection.tomorrow.hasEnoughContext)
    #expect(!projection.tomorrow.isIntentionallyOpen)
}

private func nativeCalendarOverview(
    permission: IntegrationPermissionState,
    itemCount: Int
) throws -> CalendarMirrorOverview {
    try CalendarMirrorOverview(
        observedAt: nativeNowDate,
        capability: CalendarMirrorCapability(
            availability: .available,
            supportsFullAccessRead: true
        ),
        permission: permission,
        localItemCount: itemCount,
        lastSuccessfulRefreshAt: permission == .authorized ? nativeNowDate : nil,
        newestSourceVersion: permission == .authorized ? nativeNowDate : nil,
        lastWindow: permission == .authorized ? nativeCalendarWindow() : nil
    )
}

private func nativeCalendarWindow() throws -> CalendarQueryWindow {
    try CalendarQueryWindow(
        startDate: nativeNowDate.addingTimeInterval(-24 * 60 * 60),
        endDate: nativeNowDate.addingTimeInterval(7 * 24 * 60 * 60),
        timeZoneID: "UTC"
    )
}

private func nativeCalendarItem(
    identifier: String,
    start: Date,
    end: Date
) throws -> CalendarMirrorItem {
    try CalendarMirrorItem(
        identity: CalendarEventIdentity(eventIdentifier: identifier),
        title: "Synthetic preparation",
        interval: TemporalInterval(
            start: .instant(start),
            end: .instant(end),
            timeZoneID: "UTC",
            startPrecision: .exact,
            endPrecision: .exact
        ),
        source: CalendarSourceMetadata(
            calendarIdentifier: "synthetic",
            calendarTitle: "Synthetic",
            sourceIdentifier: "synthetic",
            sourceTitle: "Synthetic",
            sourceKind: .local,
            allowsContentModifications: true
        ),
        sourceVersion: nativeNowDate,
        status: .confirmed,
        availability: .busy,
        timeZone: CalendarTimeZoneContext(
            timeZoneID: "UTC",
            source: .event,
            startUTCOffsetSeconds: 0,
            endUTCOffsetSeconds: 0
        ),
        hasRecurrenceRules: false
    )
}

private func nativeDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int
) throws -> Date {
    let zone = TimeZone(identifier: "UTC")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return try #require(calendar.date(from: DateComponents(
        timeZone: zone,
        year: year,
        month: month,
        day: day,
        hour: hour
    )))
}
