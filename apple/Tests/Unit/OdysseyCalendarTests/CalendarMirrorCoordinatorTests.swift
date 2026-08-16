import Foundation
import OdysseyCalendar
import OdysseyDomain
import OdysseyIntegrations
import Testing

private let calendarCoordinatorDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func calendarCoordinatorReconcilesMutableUpdatesCancellationsAndWindowDeletes() async throws {
    let window = try coordinatorWindow()
    let first = try coordinatorItem(identifier: 1, title: "First")
    let removed = try coordinatorItem(identifier: 2, title: "Removed")
    let canceled = try coordinatorItem(
        identifier: 1,
        title: "First revised",
        sourceVersion: calendarCoordinatorDate.addingTimeInterval(1),
        status: .canceled
    )
    let inserted = try coordinatorItem(identifier: 3, title: "Inserted")
    let adapter = SyntheticCalendarAdapter(
        capability: CalendarMirrorCapability(
            availability: .available,
            supportsFullAccessRead: true
        ),
        initialPermission: .authorized,
        authorizationAfterRequest: .authorized,
        pages: [
            SyntheticCalendarPage(
                expectedWindow: window,
                page: try CalendarMirrorPage(
                    window: window,
                    queriedAt: calendarCoordinatorDate,
                    items: [first, removed],
                    outcome: .imported
                )
            ),
            SyntheticCalendarPage(
                expectedWindow: window,
                page: try CalendarMirrorPage(
                    window: window,
                    queriedAt: calendarCoordinatorDate.addingTimeInterval(1),
                    items: [canceled, inserted],
                    outcome: .imported
                )
            ),
            SyntheticCalendarPage(
                expectedWindow: window,
                page: try CalendarMirrorPage(
                    window: window,
                    queriedAt: calendarCoordinatorDate.addingTimeInterval(2),
                    items: [canceled, inserted],
                    outcome: .imported
                )
            ),
        ]
    )
    let store = SyntheticIntegrationLocalStore()
    let coordinator = CalendarMirrorCoordinator(adapter: adapter, store: store)

    let initial = try await coordinator.refresh(window: window)
    let changed = try await coordinator.refresh(window: window)
    let unchanged = try await coordinator.refresh(window: window)
    let snapshot = try await coordinator.localSnapshot()
    let overview = try await coordinator.overview(
        observedAt: calendarCoordinatorDate.addingTimeInterval(3)
    )

    #expect(initial.insertedCount == 2)
    #expect(changed.insertedCount == 1)
    #expect(changed.updatedCount == 1)
    #expect(changed.deletedCount == 1)
    #expect(unchanged.duplicateCount == 2)
    #expect(snapshot.items == [canceled, inserted])
    #expect(snapshot.lastWindow == window)
    #expect(snapshot.lastQueriedAt == calendarCoordinatorDate.addingTimeInterval(2))
    #expect(overview.permission == .authorized)
    #expect(overview.localItemCount == 2)
    #expect(overview.lastSuccessfulRefreshAt == snapshot.lastQueriedAt)
    #expect(overview.newestSourceVersion == canceled.sourceVersion)
}

@Test
func calendarCoordinatorRejectsConflictingOrOutOfWindowRecordsWithoutBlockingCursor() async throws {
    let window = try coordinatorWindow()
    let first = try coordinatorItem(identifier: 1, title: "First")
    let conflict = try coordinatorItem(identifier: 1, title: "Conflict")
    let outside = try coordinatorItem(
        identifier: 2,
        title: "Outside",
        startDate: window.endDate.addingTimeInterval(3_600)
    )
    let adapter = SyntheticCalendarAdapter(
        capability: CalendarMirrorCapability(
            availability: .available,
            supportsFullAccessRead: true
        ),
        initialPermission: .authorized,
        authorizationAfterRequest: .authorized,
        pages: [SyntheticCalendarPage(
            expectedWindow: window,
            page: try CalendarMirrorPage(
                window: window,
                queriedAt: calendarCoordinatorDate,
                items: [first, conflict, outside],
                outcome: .imported,
                rejectedRecordCount: 2
            )
        )]
    )
    let coordinator = CalendarMirrorCoordinator(
        adapter: adapter,
        store: SyntheticIntegrationLocalStore()
    )

    let result = try await coordinator.refresh(window: window)
    let snapshot = try await coordinator.localSnapshot()

    #expect(result.insertedCount == 0)
    #expect(result.rejectedCount == 4)
    #expect(result.cursorAdvanced)
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.lastQueriedAt == calendarCoordinatorDate)
}

@Test
func deniedCalendarRefreshPreservesMirrorUntilExplicitLocalRevocation() async throws {
    let window = try coordinatorWindow()
    let item = try coordinatorItem(identifier: 1, title: "Preserved")
    let store = SyntheticIntegrationLocalStore()
    let authorized = CalendarMirrorCoordinator(
        adapter: SyntheticCalendarAdapter(
            capability: CalendarMirrorCapability(
                availability: .available,
                supportsFullAccessRead: true
            ),
            initialPermission: .authorized,
            authorizationAfterRequest: .authorized,
            pages: [SyntheticCalendarPage(
                expectedWindow: window,
                page: try CalendarMirrorPage(
                    window: window,
                    queriedAt: calendarCoordinatorDate,
                    items: [item],
                    outcome: .imported
                )
            )]
        ),
        store: store
    )
    _ = try await authorized.refresh(window: window)
    let denied = CalendarMirrorCoordinator(
        adapter: SyntheticCalendarAdapter(
            capability: CalendarMirrorCapability(
                availability: .available,
                supportsFullAccessRead: true
            ),
            initialPermission: .denied,
            authorizationAfterRequest: .denied,
            clock: { calendarCoordinatorDate.addingTimeInterval(1) }
        ),
        store: store
    )

    let result = try await denied.refresh(window: window)
    #expect(result.outcome == .permissionDenied)
    #expect(try await denied.localSnapshot().items == [item])
    #expect(try await denied.revokeLocalCalendarData() == 1)
    #expect(try await denied.localSnapshot().items.isEmpty)
}

private func coordinatorItem(
    identifier: Int,
    title: String,
    sourceVersion: Date = calendarCoordinatorDate,
    status: CalendarEventStatus = .confirmed,
    startDate: Date = calendarCoordinatorDate.addingTimeInterval(3_600)
) throws -> CalendarMirrorItem {
    try CalendarMirrorItem(
        identity: CalendarEventIdentity(eventIdentifier: "event-\(identifier)"),
        title: title,
        interval: TemporalInterval(
            start: .instant(startDate),
            end: .instant(startDate.addingTimeInterval(1_800)),
            timeZoneID: "UTC",
            startPrecision: .exact,
            endPrecision: .exact
        ),
        source: CalendarSourceMetadata(
            calendarIdentifier: "calendar-1",
            calendarTitle: "Synthetic Calendar",
            sourceIdentifier: "source-1",
            sourceTitle: "Synthetic Source",
            sourceKind: .local,
            allowsContentModifications: true
        ),
        sourceVersion: sourceVersion,
        status: status,
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

private func coordinatorWindow() throws -> CalendarQueryWindow {
    try CalendarQueryWindow(
        startDate: calendarCoordinatorDate,
        endDate: calendarCoordinatorDate.addingTimeInterval(7 * 24 * 60 * 60),
        timeZoneID: "UTC"
    )
}
