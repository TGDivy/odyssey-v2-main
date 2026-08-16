import Dispatch
import Foundation

public enum WarmPathWorkflow: String, Codable, Hashable, Sendable {
    case foodQuickLog = "food_quick_log"
}

public enum WarmPathSurface: String, Codable, Hashable, Sendable {
    case iPhone
    case appIntent = "app_intent"
    case widget
    case control
    case watch
}

public enum WarmPathOutcome: String, Codable, Hashable, Sendable {
    case committed
    case failed
    case abandoned
}

public enum WarmPathTimingError: Error, Equatable, Sendable {
    case invalidInteractionCount
    case invalidClock
}

public struct WarmPathTimingToken: Hashable, Sendable {
    public let correlationID: UUID
    public let workflow: WarmPathWorkflow
    public let surface: WarmPathSurface
    fileprivate let startedAtUptimeNanoseconds: UInt64
    fileprivate let initialInteractionCount: Int

    fileprivate init(
        correlationID: UUID,
        workflow: WarmPathWorkflow,
        surface: WarmPathSurface,
        startedAtUptimeNanoseconds: UInt64,
        initialInteractionCount: Int
    ) {
        self.correlationID = correlationID
        self.workflow = workflow
        self.surface = surface
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        self.initialInteractionCount = initialInteractionCount
    }
}

public struct WarmPathMeasurement: Hashable, Sendable {
    public static let targetDurationMilliseconds = 5_000.0
    public static let targetInteractionRange = 2 ... 3

    public let correlationID: UUID
    public let workflow: WarmPathWorkflow
    public let surface: WarmPathSurface
    public let outcome: WarmPathOutcome
    public let durationMilliseconds: Double
    public let interactionCount: Int
    public let finishedAt: Date

    public var meetsTarget: Bool {
        outcome == .committed
            && Self.targetInteractionRange.contains(interactionCount)
            && durationMilliseconds < Self.targetDurationMilliseconds
    }

    public var technicalSignal: TechnicalSignal {
        TechnicalSignal(
            name: "warm_path_timing",
            occurredAt: finishedAt,
            correlationID: correlationID,
            dimensions: [
                "workflow": workflow.rawValue,
                "surface": surface.rawValue,
                "outcome": outcome.rawValue,
                "interaction_count": String(interactionCount),
                "duration_bucket": durationBucket,
                "met_target": String(meetsTarget),
            ]
        )
    }

    private var durationBucket: String {
        switch durationMilliseconds {
        case ..<1_000:
            "under_1s"
        case ..<2_000:
            "1_to_2s"
        case ..<3_000:
            "2_to_3s"
        case ..<5_000:
            "3_to_5s"
        case ..<10_000:
            "5_to_10s"
        default:
            "10s_or_more"
        }
    }
}

public enum WarmPathTimer {
    public static func start(
        workflow: WarmPathWorkflow,
        surface: WarmPathSurface,
        initialInteractionCount: Int = 1,
        correlationID: UUID = UUID(),
        uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> WarmPathTimingToken {
        guard (0 ... 20).contains(initialInteractionCount) else {
            throw WarmPathTimingError.invalidInteractionCount
        }
        return WarmPathTimingToken(
            correlationID: correlationID,
            workflow: workflow,
            surface: surface,
            startedAtUptimeNanoseconds: uptimeNanoseconds,
            initialInteractionCount: initialInteractionCount
        )
    }

    public static func finish(
        _ token: WarmPathTimingToken,
        outcome: WarmPathOutcome,
        additionalInteractionCount: Int,
        finishedAt: Date = Date(),
        uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> WarmPathMeasurement {
        guard (0 ... 20).contains(additionalInteractionCount),
              token.initialInteractionCount + additionalInteractionCount <= 20
        else {
            throw WarmPathTimingError.invalidInteractionCount
        }
        guard finishedAt.timeIntervalSinceReferenceDate.isFinite,
              uptimeNanoseconds >= token.startedAtUptimeNanoseconds
        else {
            throw WarmPathTimingError.invalidClock
        }
        let duration = Double(
            uptimeNanoseconds - token.startedAtUptimeNanoseconds
        ) / 1_000_000
        guard duration.isFinite else {
            throw WarmPathTimingError.invalidClock
        }
        return WarmPathMeasurement(
            correlationID: token.correlationID,
            workflow: token.workflow,
            surface: token.surface,
            outcome: outcome,
            durationMilliseconds: duration,
            interactionCount: token.initialInteractionCount + additionalInteractionCount,
            finishedAt: finishedAt
        )
    }
}
