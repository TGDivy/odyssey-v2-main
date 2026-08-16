import Foundation
import OdysseyDomain

public enum CurrentContextError: Error, Equatable, Sendable {
    case invalidClock
    case invalidTimeZone
    case invalidText
    case invalidSources
    case invalidCorrection
}

public enum NowState: String, Codable, CaseIterable, Hashable, Sendable {
    case clear
    case choice
    case preparation
    case recovery
    case open
    case disrupted
}

public struct DeterministicContextInput: Codable, Hashable, Sendable {
    public let unresolvedDecisionCount: Int
    public let preparationDeadlineCount: Int
    public let materialHealthConstraintCount: Int
    public let disruptionCount: Int
    public let explicitlyOpen: Bool

    public init(
        unresolvedDecisionCount: Int,
        preparationDeadlineCount: Int,
        materialHealthConstraintCount: Int,
        disruptionCount: Int,
        explicitlyOpen: Bool
    ) {
        self.unresolvedDecisionCount = unresolvedDecisionCount
        self.preparationDeadlineCount = preparationDeadlineCount
        self.materialHealthConstraintCount = materialHealthConstraintCount
        self.disruptionCount = disruptionCount
        self.explicitlyOpen = explicitlyOpen
    }
}

public struct DeterministicContextProjector: Sendable {
    public init() {}

    public func project(_ input: DeterministicContextInput) -> NowState {
        if input.disruptionCount > 0 { return .disrupted }
        if input.materialHealthConstraintCount > 0 { return .recovery }
        if input.preparationDeadlineCount > 0 { return .preparation }
        if input.unresolvedDecisionCount > 0 { return .choice }
        if input.explicitlyOpen { return .open }
        return .clear
    }
}

public enum CurrentContextSource: String, Codable, CaseIterable, Hashable, Sendable {
    case season
    case calendar
    case health
    case weather
    case location
}

public enum CurrentContextSourceState: String, Codable, Hashable, Sendable {
    case fresh
    case stale
    case missing
    case denied
    case unavailable
}

public struct CurrentContextSourceSnapshot: Codable, Hashable, Sendable {
    public let source: CurrentContextSource
    public let state: CurrentContextSourceState
    public let observedAt: Date?

    public init(
        source: CurrentContextSource,
        state: CurrentContextSourceState,
        observedAt: Date? = nil
    ) throws {
        guard observedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw CurrentContextError.invalidClock
        }
        self.source = source
        self.state = state
        self.observedAt = observedAt
    }
}

public struct NowTransition: Codable, Hashable, Sendable {
    public let startsAt: Date
    public let label: String?
    public let isTentative: Bool

    public init(
        startsAt: Date,
        label: String? = nil,
        isTentative: Bool = false
    ) throws {
        guard startsAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CurrentContextError.invalidClock
        }
        guard Self.validOptionalText(label, maximum: 500) else {
            throw CurrentContextError.invalidText
        }
        self.startsAt = startsAt
        self.label = label
        self.isTentative = isTentative
    }

    private static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return true }
        return (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum NowStateCorrectionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case situationChanged = "situation_changed"
    case capacityChanged = "capacity_changed"
    case planChanged = "plan_changed"
    case ownerRequestedQuiet = "owner_requested_quiet"
    case other
}

public struct NowStateCorrection: Codable, Hashable, Sendable {
    public static let maximumLifetime: TimeInterval = 48 * 60 * 60

    public let state: NowState
    public let reason: NowStateCorrectionReason
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        state: NowState,
        reason: NowStateCorrectionReason,
        createdAt: Date,
        expiresAt: Date
    ) throws {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= Self.maximumLifetime
        else {
            throw CurrentContextError.invalidCorrection
        }
        self.state = state
        self.reason = reason
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            state: values.decode(NowState.self, forKey: .state),
            reason: values.decode(NowStateCorrectionReason.self, forKey: .reason),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            expiresAt: values.decode(Date.self, forKey: .expiresAt)
        )
    }

    public func isActive(at date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && date >= createdAt.addingTimeInterval(-60)
            && date < expiresAt
    }
}

public struct NowContextInput: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let localDay: LocalDate
    public let timeZoneID: String
    public let signals: DeterministicContextInput
    public let currentThread: String?
    public let nextTransition: NowTransition?
    public let sources: [CurrentContextSourceSnapshot]
    public let hasEnoughContextForSilence: Bool

    public init(
        generatedAt: Date,
        localDay: LocalDate,
        timeZoneID: String,
        signals: DeterministicContextInput,
        currentThread: String? = nil,
        nextTransition: NowTransition? = nil,
        sources: [CurrentContextSourceSnapshot] = [],
        hasEnoughContextForSilence: Bool = false
    ) throws {
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CurrentContextError.invalidClock
        }
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw CurrentContextError.invalidTimeZone
        }
        guard Self.validOptionalText(currentThread, maximum: 500) else {
            throw CurrentContextError.invalidText
        }
        guard sources.count <= CurrentContextSource.allCases.count,
              Set(sources.map(\.source)).count == sources.count
        else {
            throw CurrentContextError.invalidSources
        }
        self.generatedAt = generatedAt
        self.localDay = localDay
        self.timeZoneID = timeZoneID
        self.signals = signals
        self.currentThread = currentThread
        self.nextTransition = nextTransition
        self.sources = sources.sorted { $0.source.rawValue < $1.source.rawValue }
        self.hasEnoughContextForSilence = hasEnoughContextForSilence
    }

    private static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return true }
        return (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct NowContextProjection: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let localDay: LocalDate
    public let timeZoneID: String
    public let inferredState: NowState
    public let state: NowState
    public let summary: String
    public let currentThread: String?
    public let nextTransition: NowTransition?
    public let sources: [CurrentContextSourceSnapshot]
    public let correction: NowStateCorrection?
    public let isIntentionallySilent: Bool
    public let hasEnoughContextForSilence: Bool
}

public struct NowContextProjector: Sendable {
    public init() {}

    public func project(
        _ input: NowContextInput,
        correction: NowStateCorrection? = nil
    ) -> NowContextProjection {
        let inferredState = DeterministicContextProjector().project(input.signals)
        let activeCorrection = correction.flatMap {
            $0.isActive(at: input.generatedAt) ? $0 : nil
        }
        let ownerRequestedQuiet = activeCorrection?.reason == .ownerRequestedQuiet
        let state = activeCorrection?.state ?? inferredState
        return NowContextProjection(
            generatedAt: input.generatedAt,
            localDay: input.localDay,
            timeZoneID: input.timeZoneID,
            inferredState: inferredState,
            state: state,
            summary: summary(
                for: state,
                hasEnoughContextForSilence: input.hasEnoughContextForSilence,
                ownerRequestedQuiet: ownerRequestedQuiet
            ),
            currentThread: input.currentThread,
            nextTransition: input.nextTransition,
            sources: input.sources,
            correction: activeCorrection,
            isIntentionallySilent: state == .clear
                && (input.hasEnoughContextForSilence || ownerRequestedQuiet),
            hasEnoughContextForSilence: input.hasEnoughContextForSilence
        )
    }

    private func summary(
        for state: NowState,
        hasEnoughContextForSilence: Bool,
        ownerRequestedQuiet: Bool
    ) -> String {
        switch state {
        case .clear:
            if ownerRequestedQuiet {
                "You asked Odyssey to stay quiet for now."
            } else if hasEnoughContextForSilence {
                "Nothing requires attention. The known shape of the day is coherent."
            } else {
                "No current attention claim is available from the context Odyssey can inspect."
            }
        case .choice:
            "One live trade-off needs attention; the rest can stay quiet."
        case .preparation:
            "A known future commitment makes a small preparation step valuable now."
        case .recovery:
            "Capacity is the binding constraint. Protect recovery before adding demand."
        case .open:
            "Unstructured time is available. It does not need to be filled."
        case .disrupted:
            "Normal expectations may not fit the current situation. Reorient first."
        }
    }
}

public protocol StructuredSynthesisProviding: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    func synthesize(_ input: Input) async throws -> Output
}
