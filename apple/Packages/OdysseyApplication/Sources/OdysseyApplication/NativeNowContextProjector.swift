import Foundation
import OdysseyCalendar
import OdysseyDomain
import OdysseyHealth
import OdysseyIntelligence
import OdysseyIntegrations
import OdysseyLocation
import OdysseyWeather

public enum NativeNowContextError: Error, Equatable, Sendable {
    case invalidClock
    case invalidTimeZone
    case invalidSignalCount
    case invalidCalendarItem
}

public struct NativeNowContextInput: Sendable {
    public let generatedAt: Date
    public let deviceTimeZoneID: String
    public let unresolvedDecisionCount: Int
    public let materialHealthConstraintCount: Int
    public let calendarSnapshot: CalendarLocalSnapshot?
    public let calendarOverview: CalendarMirrorOverview?
    public let healthOverview: HealthImportOverview?
    public let healthLastSuccessfulImportAt: Date?
    public let weatherOverview: WeatherMirrorOverview?
    public let locationOverview: LocationContextOverview?
    public let season: Season?
    public let correction: NowStateCorrection?

    public init(
        generatedAt: Date,
        deviceTimeZoneID: String,
        unresolvedDecisionCount: Int = 0,
        materialHealthConstraintCount: Int = 0,
        calendarSnapshot: CalendarLocalSnapshot? = nil,
        calendarOverview: CalendarMirrorOverview? = nil,
        healthOverview: HealthImportOverview? = nil,
        healthLastSuccessfulImportAt: Date? = nil,
        weatherOverview: WeatherMirrorOverview? = nil,
        locationOverview: LocationContextOverview? = nil,
        season: Season? = nil,
        correction: NowStateCorrection? = nil
    ) throws {
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite,
              healthLastSuccessfulImportAt?.timeIntervalSinceReferenceDate.isFinite
                ?? true
        else {
            throw NativeNowContextError.invalidClock
        }
        guard TimeZone(identifier: deviceTimeZoneID) != nil else {
            throw NativeNowContextError.invalidTimeZone
        }
        guard unresolvedDecisionCount >= 0,
              materialHealthConstraintCount >= 0
        else {
            throw NativeNowContextError.invalidSignalCount
        }
        self.generatedAt = generatedAt
        self.deviceTimeZoneID = deviceTimeZoneID
        self.unresolvedDecisionCount = unresolvedDecisionCount
        self.materialHealthConstraintCount = materialHealthConstraintCount
        self.calendarSnapshot = calendarSnapshot
        self.calendarOverview = calendarOverview
        self.healthOverview = healthOverview
        self.healthLastSuccessfulImportAt = healthLastSuccessfulImportAt
        self.weatherOverview = weatherOverview
        self.locationOverview = locationOverview
        self.season = season
        self.correction = correction
    }
}

public struct NativeNowContextProjection: Hashable, Sendable {
    public let now: NowContextProjection
    public let tomorrow: TomorrowMapProjection

    public init(
        now: NowContextProjection,
        tomorrow: TomorrowMapProjection
    ) {
        self.now = now
        self.tomorrow = tomorrow
    }
}

public struct NativeNowContextProjector: Sendable {
    public static let preparationHorizon: TimeInterval = 3 * 60 * 60
    public static let calendarFreshnessLifetime: TimeInterval = 24 * 60 * 60

    public init() {}

    public func project(
        _ input: NativeNowContextInput
    ) throws -> NativeNowContextProjection {
        let contextTimeZoneID = input.locationOverview.flatMap {
            $0.cacheIsFresh ? $0.cachedPlace?.timeZoneID : nil
        } ?? input.deviceTimeZoneID
        let currentDay = try LocalDate(
            containing: input.generatedAt,
            in: contextTimeZoneID
        )
        let tomorrowDay = try nextLocalDay(
            after: currentDay,
            timeZoneID: contextTimeZoneID
        )
        let calendarState = calendarState(
            overview: input.calendarOverview,
            snapshot: input.calendarSnapshot,
            at: input.generatedAt
        )
        let calendarItems = try input.calendarSnapshot?.items.map {
            (item: $0, bounds: try absoluteBounds($0))
        } ?? []
        let busyItems = calendarItems.filter { isBusy($0.item) }
        let activeItems = busyItems.filter {
            $0.bounds.start <= input.generatedAt
                && $0.bounds.end > input.generatedAt
        }
        let preparationLimit = input.generatedAt.addingTimeInterval(
            Self.preparationHorizon
        )
        let upcomingItems = busyItems.filter {
            $0.bounds.start > input.generatedAt
                && $0.bounds.start <= preparationLimit
        }.sorted(by: itemOrder)
        let nextItem = busyItems.filter {
            $0.bounds.start > input.generatedAt
        }.sorted(by: itemOrder).first
        let travelDisruption = input.locationOverview.map {
            $0.cacheIsFresh
                && $0.cachedPlace?.timeZoneID != nil
                && $0.cachedPlace?.timeZoneID != input.deviceTimeZoneID
        } ?? false
        let inferredDecisionCount = input.unresolvedDecisionCount
            + max(0, activeItems.count - 1)
        let signals = DeterministicContextInput(
            unresolvedDecisionCount: inferredDecisionCount,
            preparationDeadlineCount: upcomingItems.isEmpty ? 0 : 1,
            materialHealthConstraintCount: input.materialHealthConstraintCount,
            disruptionCount: travelDisruption ? 1 : 0,
            explicitlyOpen: calendarState == .fresh
                && activeItems.isEmpty
                && upcomingItems.isEmpty
        )
        let transition = try nextItem.map {
            try NowTransition(
                startsAt: $0.bounds.start,
                label: $0.item.title,
                isTentative: isTentative($0.item)
            )
        }
        let currentThread = seasonThread(input.season)
        let nowInput = try NowContextInput(
            generatedAt: input.generatedAt,
            localDay: currentDay,
            timeZoneID: contextTimeZoneID,
            signals: signals,
            currentThread: currentThread,
            nextTransition: transition,
            sources: try sourceSnapshots(input, calendarState: calendarState),
            hasEnoughContextForSilence: calendarState == .fresh
        )
        let tomorrowCommitments = try busyItems.map {
            try TomorrowCommitment(
                identifier: $0.item.identity.storageIdentifier,
                title: $0.item.title,
                startsAt: $0.bounds.start,
                endsAt: $0.bounds.end,
                status: isTentative($0.item) ? .tentative : .confirmed,
                isAllDay: $0.item.interval.allDaySemantics
            )
        }
        let tomorrow = try TomorrowMapProjector().project(TomorrowMapInput(
            generatedAt: input.generatedAt,
            localDay: tomorrowDay,
            timeZoneID: contextTimeZoneID,
            calendarState: tomorrowCalendarState(calendarState),
            commitments: tomorrowCommitments,
            currentSeasonThread: currentThread
        ))
        return NativeNowContextProjection(
            now: NowContextProjector().project(
                nowInput,
                correction: input.correction
            ),
            tomorrow: tomorrow
        )
    }

    private func calendarState(
        overview: CalendarMirrorOverview?,
        snapshot: CalendarLocalSnapshot?,
        at date: Date
    ) -> CurrentContextSourceState {
        guard let overview else { return .missing }
        guard overview.capability.availability == .available,
              overview.capability.supportsFullAccessRead
        else {
            return .unavailable
        }
        switch overview.permission {
        case .denied, .restricted, .partial:
            return .denied
        case .unavailable:
            return .unavailable
        case .notDetermined, .notRequired:
            return .missing
        case .authorized:
            break
        }
        guard let queriedAt = snapshot?.lastQueriedAt else { return .missing }
        let age = date.timeIntervalSince(queriedAt)
        return age >= -60 && age <= Self.calendarFreshnessLifetime
            ? .fresh
            : .stale
    }

    private func sourceSnapshots(
        _ input: NativeNowContextInput,
        calendarState: CurrentContextSourceState
    ) throws -> [CurrentContextSourceSnapshot] {
        [
            try CurrentContextSourceSnapshot(
                source: .season,
                state: seasonSourceState(input.season),
                observedAt: input.season?.metadata.lastRevisedAt
            ),
            try CurrentContextSourceSnapshot(
                source: .calendar,
                state: calendarState,
                observedAt: input.calendarSnapshot?.lastQueriedAt
            ),
            try CurrentContextSourceSnapshot(
                source: .health,
                state: healthSourceState(input),
                observedAt: input.healthLastSuccessfulImportAt
            ),
            try CurrentContextSourceSnapshot(
                source: .weather,
                state: weatherSourceState(input.weatherOverview),
                observedAt: input.weatherOverview?.lastSuccessfulRefreshAt
            ),
            try CurrentContextSourceSnapshot(
                source: .location,
                state: locationSourceState(input.locationOverview),
                observedAt: input.locationOverview?.lastSuccessfulRefreshAt
            ),
        ]
    }

    private func seasonSourceState(_ season: Season?) -> CurrentContextSourceState {
        guard let season else { return .missing }
        switch season.status {
        case .active, .calibration, .transitioning:
            return .fresh
        case .complete, .abandoned, .draft:
            return .stale
        }
    }

    private func healthSourceState(
        _ input: NativeNowContextInput
    ) -> CurrentContextSourceState {
        guard let overview = input.healthOverview else { return .missing }
        guard overview.capability.availability == .available else {
            return .unavailable
        }
        switch overview.permission {
        case .denied, .restricted:
            return .denied
        case .unavailable:
            return .unavailable
        case .notDetermined, .notRequired:
            return .missing
        case .authorized, .partial:
            break
        }
        guard let importedAt = input.healthLastSuccessfulImportAt else {
            return .missing
        }
        let age = input.generatedAt.timeIntervalSince(importedAt)
        return age >= -60 && age <= Self.calendarFreshnessLifetime
            ? .fresh
            : .stale
    }

    private func weatherSourceState(
        _ overview: WeatherMirrorOverview?
    ) -> CurrentContextSourceState {
        guard let overview else { return .missing }
        guard overview.capability.availability == .available else {
            return .unavailable
        }
        switch overview.permission {
        case .denied, .restricted:
            return .denied
        case .unavailable:
            return .unavailable
        case .notDetermined:
            return .missing
        case .notRequired, .authorized, .partial:
            break
        }
        guard overview.cachedPlace != nil else { return .missing }
        return overview.cacheIsFresh ? .fresh : .stale
    }

    private func locationSourceState(
        _ overview: LocationContextOverview?
    ) -> CurrentContextSourceState {
        guard let overview else { return .missing }
        guard overview.capability.availability == .available,
              overview.capability.supportsForegroundBroadPlace
        else {
            return .unavailable
        }
        switch overview.permission {
        case .denied, .restricted:
            return .denied
        case .unavailable:
            return .unavailable
        case .notDetermined, .notRequired:
            return .missing
        case .authorized, .partial:
            break
        }
        guard overview.cachedPlace != nil else { return .missing }
        return overview.cacheIsFresh ? .fresh : .stale
    }

    private func tomorrowCalendarState(
        _ state: CurrentContextSourceState
    ) -> TomorrowCalendarState {
        switch state {
        case .fresh:
            .fresh
        case .stale:
            .stale
        case .missing:
            .missing
        case .denied:
            .denied
        case .unavailable:
            .unavailable
        }
    }

    private func seasonThread(_ season: Season?) -> String? {
        guard let season,
              season.status == .active
                || season.status == .calibration
                || season.status == .transitioning
        else {
            return nil
        }
        let preferred = season.portfolioItems.first { $0.role == .primary }
            ?? season.portfolioItems.first { $0.role == .foundation }
        let value = preferred?.minimumViableCommitment
            ?? preferred?.successSignals.first
            ?? season.goodWeekDescription
        return bounded(value, maximum: 500)
    }

    private func bounded(_ value: String, maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum - 1)) + "…"
    }

    private func isBusy(_ item: CalendarMirrorItem) -> Bool {
        guard item.status != .canceled else { return false }
        return item.availability != .free && item.availability != .unavailable
    }

    private func isTentative(_ item: CalendarMirrorItem) -> Bool {
        item.status == .tentative || item.availability == .tentative
    }

    private func itemOrder(
        _ left: (item: CalendarMirrorItem, bounds: (start: Date, end: Date)),
        _ right: (item: CalendarMirrorItem, bounds: (start: Date, end: Date))
    ) -> Bool {
        if left.bounds.start != right.bounds.start {
            return left.bounds.start < right.bounds.start
        }
        return left.item.identity.storageIdentifier
            < right.item.identity.storageIdentifier
    }

    private func absoluteBounds(
        _ item: CalendarMirrorItem
    ) throws -> (start: Date, end: Date) {
        switch (item.interval.start, item.interval.end) {
        case let (.instant(start), .instant(end)):
            return (start, end)
        case let (.localDate(start), .localDate(end)):
            guard let zone = TimeZone(identifier: item.timeZone.timeZoneID) else {
                throw NativeNowContextError.invalidTimeZone
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
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
            )), endDate > startDate else {
                throw NativeNowContextError.invalidCalendarItem
            }
            return (startDate, endDate)
        default:
            throw NativeNowContextError.invalidCalendarItem
        }
    }

    private func nextLocalDay(
        after day: LocalDate,
        timeZoneID: String
    ) throws -> LocalDate {
        guard let zone = TimeZone(identifier: timeZoneID) else {
            throw NativeNowContextError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = zone
        guard let start = calendar.date(from: DateComponents(
            timeZone: zone,
            year: day.year,
            month: day.month,
            day: day.day
        )), let next = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw NativeNowContextError.invalidClock
        }
        return try LocalDate(containing: next, in: timeZoneID)
    }
}
