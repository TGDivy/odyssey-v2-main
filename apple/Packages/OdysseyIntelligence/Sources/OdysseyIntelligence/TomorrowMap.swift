import Foundation
import OdysseyDomain

public enum TomorrowMapError: Error, Equatable, Sendable {
    case invalidClock
    case invalidTimeZone
    case invalidCommitment
    case invalidText
    case tooManyCommitments
}

public enum TomorrowCalendarState: String, Codable, Hashable, Sendable {
    case fresh
    case stale
    case missing
    case denied
    case unavailable
}

public enum TomorrowCommitmentStatus: String, Codable, Hashable, Sendable {
    case confirmed
    case tentative
}

public struct TomorrowCommitment: Codable, Hashable, Sendable {
    public static let maximumDuration: TimeInterval = 7 * 24 * 60 * 60

    public let identifier: String
    public let title: String?
    public let startsAt: Date
    public let endsAt: Date
    public let status: TomorrowCommitmentStatus
    public let isAllDay: Bool

    public init(
        identifier: String,
        title: String? = nil,
        startsAt: Date,
        endsAt: Date,
        status: TomorrowCommitmentStatus,
        isAllDay: Bool
    ) throws {
        guard Self.validText(identifier, maximum: 500),
              Self.validOptionalText(title, maximum: 500)
        else {
            throw TomorrowMapError.invalidText
        }
        guard startsAt.timeIntervalSinceReferenceDate.isFinite,
              endsAt.timeIntervalSinceReferenceDate.isFinite,
              endsAt > startsAt,
              endsAt.timeIntervalSince(startsAt) <= Self.maximumDuration
        else {
            throw TomorrowMapError.invalidCommitment
        }
        self.identifier = identifier
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.status = status
        self.isAllDay = isAllDay
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return true }
        return validText(value, maximum: maximum)
    }
}

public struct TomorrowMapInput: Codable, Hashable, Sendable {
    public static let maximumCommitmentCount = 200

    public let generatedAt: Date
    public let localDay: LocalDate
    public let timeZoneID: String
    public let calendarState: TomorrowCalendarState
    public let commitments: [TomorrowCommitment]
    public let currentSeasonThread: String?

    public init(
        generatedAt: Date,
        localDay: LocalDate,
        timeZoneID: String,
        calendarState: TomorrowCalendarState,
        commitments: [TomorrowCommitment],
        currentSeasonThread: String? = nil
    ) throws {
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw TomorrowMapError.invalidClock
        }
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw TomorrowMapError.invalidTimeZone
        }
        guard commitments.count <= Self.maximumCommitmentCount else {
            throw TomorrowMapError.tooManyCommitments
        }
        guard Self.validOptionalText(currentSeasonThread, maximum: 500) else {
            throw TomorrowMapError.invalidText
        }
        self.generatedAt = generatedAt
        self.localDay = localDay
        self.timeZoneID = timeZoneID
        self.calendarState = calendarState
        self.commitments = commitments
        self.currentSeasonThread = currentSeasonThread
    }

    private static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return true }
        return (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TomorrowTransition: Codable, Hashable, Sendable {
    public let identifier: String
    public let title: String?
    public let startsAt: Date
    public let endsAt: Date
    public let isTentative: Bool
    public let isAllDay: Bool
}

public struct TomorrowOpenPeriod: Codable, Hashable, Sendable {
    public let startsAt: Date
    public let endsAt: Date
}

public struct TomorrowMapProjection: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let localDay: LocalDate
    public let timeZoneID: String
    public let calendarState: TomorrowCalendarState
    public let shape: String
    public let pressurePoint: String?
    public let preparationAction: String?
    public let protectedOpenPeriod: TomorrowOpenPeriod?
    public let transitions: [TomorrowTransition]
    public let currentSeasonThread: String?
    public let isIntentionallyOpen: Bool
    public let hasEnoughContext: Bool
}

public struct TomorrowMapProjector: Sendable {
    private static let maximumRenderedTransitions = 3
    private static let minimumProtectedOpenDuration: TimeInterval = 90 * 60

    public init() {}

    public func project(_ input: TomorrowMapInput) throws -> TomorrowMapProjection {
        let bounds = try dayBounds(input.localDay, timeZoneID: input.timeZoneID)
        guard input.calendarState == .fresh || input.calendarState == .stale else {
            return unavailableProjection(input, shape: unavailableShape(input.calendarState))
        }
        let commitments = input.commitments.filter {
            $0.startsAt < bounds.end && $0.endsAt > bounds.start
        }.sorted {
            if $0.startsAt != $1.startsAt { return $0.startsAt < $1.startsAt }
            if $0.endsAt != $1.endsAt { return $0.endsAt < $1.endsAt }
            return $0.identifier < $1.identifier
        }
        let clipped = commitments.map {
            DateInterval(
                start: max($0.startsAt, bounds.start),
                end: min($0.endsAt, bounds.end)
            )
        }
        let merged = mergedIntervals(clipped)
        let pressure = pressurePoint(commitments: commitments, merged: merged)
        let protectedOpen = protectedOpenPeriod(
            merged: merged,
            day: input.localDay,
            timeZoneID: input.timeZoneID
        )
        let transitions = commitments.prefix(Self.maximumRenderedTransitions).map {
            TomorrowTransition(
                identifier: $0.identifier,
                title: $0.title,
                startsAt: $0.startsAt,
                endsAt: $0.endsAt,
                isTentative: $0.status == .tentative,
                isAllDay: $0.isAllDay
            )
        }
        return TomorrowMapProjection(
            generatedAt: input.generatedAt,
            localDay: input.localDay,
            timeZoneID: input.timeZoneID,
            calendarState: input.calendarState,
            shape: shape(
                commitments: commitments,
                protectedOpenPeriod: protectedOpen,
                stale: input.calendarState == .stale
            ),
            pressurePoint: pressure,
            preparationAction: preparationAction(
                commitments: commitments,
                pressurePoint: pressure,
                localDay: input.localDay,
                timeZoneID: input.timeZoneID
            ),
            protectedOpenPeriod: protectedOpen,
            transitions: transitions,
            currentSeasonThread: input.currentSeasonThread,
            isIntentionallyOpen: commitments.isEmpty,
            hasEnoughContext: true
        )
    }

    private func unavailableProjection(
        _ input: TomorrowMapInput,
        shape: String
    ) -> TomorrowMapProjection {
        TomorrowMapProjection(
            generatedAt: input.generatedAt,
            localDay: input.localDay,
            timeZoneID: input.timeZoneID,
            calendarState: input.calendarState,
            shape: shape,
            pressurePoint: nil,
            preparationAction: nil,
            protectedOpenPeriod: nil,
            transitions: [],
            currentSeasonThread: input.currentSeasonThread,
            isIntentionallyOpen: false,
            hasEnoughContext: false
        )
    }

    private func unavailableShape(_ state: TomorrowCalendarState) -> String {
        switch state {
        case .missing:
            "Tomorrow is not mapped because no local Calendar context exists."
        case .denied:
            "Tomorrow is not mapped because Calendar access is denied."
        case .unavailable:
            "Tomorrow is not mapped because Calendar context is unavailable."
        case .fresh, .stale:
            "Tomorrow is not mapped."
        }
    }

    private func shape(
        commitments: [TomorrowCommitment],
        protectedOpenPeriod: TomorrowOpenPeriod?,
        stale: Bool
    ) -> String {
        let prefix = stale ? "The cached map shows" : "Tomorrow has"
        guard !commitments.isEmpty else {
            return stale
                ? "The cached calendar leaves tomorrow intentionally open."
                : "Tomorrow is intentionally open in the known calendar."
        }
        let tentativeCount = commitments.count { $0.status == .tentative }
        let noun = commitments.count == 1 ? "commitment" : "commitments"
        let certainty = tentativeCount == commitments.count ? " tentative" : " known"
        let openness = protectedOpenPeriod == nil ? "." : " with protected open time."
        return "\(prefix) \(commitments.count)\(certainty) \(noun)\(openness)"
    }

    private func pressurePoint(
        commitments: [TomorrowCommitment],
        merged: [DateInterval]
    ) -> String? {
        guard !commitments.isEmpty else { return nil }
        var furthestEnd = commitments[0].endsAt
        for commitment in commitments.dropFirst() {
            if commitment.startsAt < furthestEnd {
                return "Known commitments overlap."
            }
            furthestEnd = max(furthestEnd, commitment.endsAt)
        }
        for pair in zip(merged, merged.dropFirst()) {
            let margin = pair.1.start.timeIntervalSince(pair.0.end)
            if margin >= 0, margin < 30 * 60 {
                return "A transition leaves less than 30 minutes of margin."
            }
        }
        let busyDuration = merged.reduce(0) { $0 + $1.duration }
        if commitments.count >= 5 || busyDuration >= 8 * 60 * 60 {
            return "The known schedule leaves limited unstructured margin."
        }
        if commitments.count(where: { $0.status == .tentative }) >= 2 {
            return "Several commitments remain tentative."
        }
        return nil
    }

    private func preparationAction(
        commitments: [TomorrowCommitment],
        pressurePoint: String?,
        localDay: LocalDate,
        timeZoneID: String
    ) -> String? {
        guard let first = commitments.first else { return nil }
        if pressurePoint != nil {
            return "Resolve the pressure point before tomorrow begins."
        }
        guard !first.isAllDay,
              let noon = try? date(
                  localDay,
                  hour: 12,
                  timeZoneID: timeZoneID
              ),
              first.startsAt < noon
        else {
            return nil
        }
        return "Review what the first commitment requires before its start."
    }

    private func protectedOpenPeriod(
        merged: [DateInterval],
        day: LocalDate,
        timeZoneID: String
    ) -> TomorrowOpenPeriod? {
        guard let start = try? date(day, hour: 8, timeZoneID: timeZoneID),
              let end = try? date(day, hour: 21, timeZoneID: timeZoneID),
              end > start
        else {
            return nil
        }
        let window = DateInterval(start: start, end: end)
        let occupied = merged.compactMap { interval -> DateInterval? in
            guard interval.intersects(window) else { return nil }
            return DateInterval(
                start: max(interval.start, window.start),
                end: min(interval.end, window.end)
            )
        }
        var gaps = [DateInterval]()
        var cursor = window.start
        for interval in occupied {
            if interval.start > cursor {
                gaps.append(DateInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if cursor < window.end {
            gaps.append(DateInterval(start: cursor, end: window.end))
        }
        guard let largest = gaps.filter({
            $0.duration >= Self.minimumProtectedOpenDuration
        }).max(by: {
            if $0.duration != $1.duration { return $0.duration < $1.duration }
            return $0.start > $1.start
        }) else {
            return nil
        }
        return TomorrowOpenPeriod(startsAt: largest.start, endsAt: largest.end)
    }

    private func mergedIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        var result = [DateInterval]()
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            guard let last = result.last, interval.start <= last.end else {
                result.append(interval)
                continue
            }
            result[result.count - 1] = DateInterval(
                start: last.start,
                end: max(last.end, interval.end)
            )
        }
        return result
    }

    private func dayBounds(
        _ day: LocalDate,
        timeZoneID: String
    ) throws -> (start: Date, end: Date) {
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw TomorrowMapError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        guard let start = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: day.year,
            month: day.month,
            day: day.day
        )), let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw TomorrowMapError.invalidClock
        }
        return (start, end)
    }

    private func date(
        _ day: LocalDate,
        hour: Int,
        timeZoneID: String
    ) throws -> Date {
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw TomorrowMapError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: day.year,
            month: day.month,
            day: day.day,
            hour: hour
        )) else {
            throw TomorrowMapError.invalidClock
        }
        return date
    }
}
