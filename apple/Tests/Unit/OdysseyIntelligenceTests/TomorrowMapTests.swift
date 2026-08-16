import Foundation
import OdysseyDomain
import OdysseyIntelligence
import Testing

private let tomorrowMapDate = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func tomorrowMapRepresentsKnownSilenceAsProtectedOpenTime() throws {
    let projection = try TomorrowMapProjector().project(TomorrowMapInput(
        generatedAt: tomorrowMapDate,
        localDay: LocalDate(year: 2026, month: 8, day: 16),
        timeZoneID: "America/New_York",
        calendarState: .fresh,
        commitments: [],
        currentSeasonThread: "Keep foundations intact"
    ))

    #expect(projection.isIntentionallyOpen)
    #expect(projection.hasEnoughContext)
    #expect(projection.pressurePoint == nil)
    #expect(projection.preparationAction == nil)
    #expect(projection.protectedOpenPeriod != nil)
    #expect(projection.shape == "Tomorrow is intentionally open in the known calendar.")
}

@Test
func tomorrowMapFindsOverlapPreparationAndBoundedTransitions() throws {
    let zone = TimeZone(identifier: "America/New_York")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            timeZone: zone,
            year: 2026,
            month: 8,
            day: 16,
            hour: hour,
            minute: minute
        ))!
    }
    let commitments = try [
        TomorrowCommitment(
            identifier: "first",
            title: "Synthetic interview",
            startsAt: date(hour: 9),
            endsAt: date(hour: 10, minute: 30),
            status: .confirmed,
            isAllDay: false
        ),
        TomorrowCommitment(
            identifier: "overlap",
            startsAt: date(hour: 10),
            endsAt: date(hour: 11),
            status: .tentative,
            isAllDay: false
        ),
        TomorrowCommitment(
            identifier: "third",
            startsAt: date(hour: 14),
            endsAt: date(hour: 15),
            status: .confirmed,
            isAllDay: false
        ),
        TomorrowCommitment(
            identifier: "not-rendered",
            startsAt: date(hour: 18),
            endsAt: date(hour: 19),
            status: .confirmed,
            isAllDay: false
        ),
    ]
    let projection = try TomorrowMapProjector().project(TomorrowMapInput(
        generatedAt: tomorrowMapDate,
        localDay: LocalDate(year: 2026, month: 8, day: 16),
        timeZoneID: zone.identifier,
        calendarState: .fresh,
        commitments: commitments
    ))

    #expect(projection.pressurePoint == "Known commitments overlap.")
    #expect(projection.preparationAction
        == "Resolve the pressure point before tomorrow begins.")
    #expect(projection.transitions.map(\.identifier) == ["first", "overlap", "third"])
    #expect(projection.protectedOpenPeriod != nil)
}

@Test
func tomorrowMapUsesNamedZoneDayAcrossDSTAndFailsClosedWithoutCalendar() throws {
    let denied = try TomorrowMapProjector().project(TomorrowMapInput(
        generatedAt: tomorrowMapDate,
        localDay: LocalDate(year: 2026, month: 3, day: 8),
        timeZoneID: "America/New_York",
        calendarState: .denied,
        commitments: []
    ))
    #expect(!denied.hasEnoughContext)
    #expect(!denied.isIntentionallyOpen)
    #expect(denied.transitions.isEmpty)

    let open = try TomorrowMapProjector().project(TomorrowMapInput(
        generatedAt: tomorrowMapDate,
        localDay: LocalDate(year: 2026, month: 3, day: 8),
        timeZoneID: "America/New_York",
        calendarState: .fresh,
        commitments: []
    ))
    let duration = try #require(open.protectedOpenPeriod).endsAt.timeIntervalSince(
        try #require(open.protectedOpenPeriod).startsAt
    )
    #expect(duration == 13 * 60 * 60)
}
