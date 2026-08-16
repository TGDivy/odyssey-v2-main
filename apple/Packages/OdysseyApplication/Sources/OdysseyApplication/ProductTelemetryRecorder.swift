import Foundation
import OdysseyDomain
import OdysseyIntelligence
import OdysseyTelemetry

public enum ProductTelemetryRecorderConfigurationError: Error, Equatable, Sendable {
    case invalidAppBuild
}

public enum ProductTelemetryRecorderFailure: String, Codable, Hashable, Sendable {
    case featureConfiguration
    case eventConstruction
    case persistence
}

public enum ProductTelemetryRecordingDisposition: Hashable, Sendable {
    case recorded
    case skippedByPreference
    case skippedByFeatureFlag
    case skippedByStorage
    case unsupportedContext
    case failed(ProductTelemetryRecorderFailure)
}

public struct ProductTelemetryRecorderDiagnostics: Hashable, Sendable {
    public let attemptedEventCount: Int
    public let recordedEventCount: Int
    public let preferenceSkippedEventCount: Int
    public let featureFlagSkippedEventCount: Int
    public let storageSkippedEventCount: Int
    public let unsupportedContextEventCount: Int
    public let failedEventCount: Int
    public let lastFailure: ProductTelemetryRecorderFailure?
    public let lastFailureAt: Date?
}

public enum CaptureProductTelemetryOutcome: String, Codable, CaseIterable, Sendable {
    case committed
    case failed
    case abandoned
}

public enum CaptureProductTelemetryExitStage: String, Codable, CaseIterable, Sendable {
    case entry
    case selection
    case saving
    case localCommit = "local_commit"
}

public enum ProductTelemetryDurationBucket: String, Codable, CaseIterable, Sendable {
    case underOneSecond = "under_1s"
    case oneToThreeSeconds = "1_to_3s"
    case threeToFiveSeconds = "3_to_5s"
    case fiveToTenSeconds = "5_to_10s"
    case tenToThirtySeconds = "10_to_30s"
    case thirtySecondsOrMore = "30s_or_more"

    fileprivate static func elapsed(from startedAt: Date, to finishedAt: Date) -> Self? {
        let duration = finishedAt.timeIntervalSince(startedAt)
        guard duration.isFinite, duration >= 0 else { return nil }
        switch duration {
        case ..<1:
            return .underOneSecond
        case ..<3:
            return .oneToThreeSeconds
        case ..<5:
            return .threeToFiveSeconds
        case ..<10:
            return .fiveToTenSeconds
        case ..<30:
            return .tenToThirtySeconds
        default:
            return .thirtySecondsOrMore
        }
    }
}

public enum CaptureProductTelemetryFeedbackRating: String, Codable, CaseIterable, Sendable {
    case useful
    case neutral
    case addedFriction = "added_friction"
}

public enum CaptureProductTelemetryFeedbackReason: String, Codable, CaseIterable, Sendable {
    case fast
    case tooManySteps = "too_many_steps"
    case wrongContext = "wrong_context"
    case badTiming = "bad_timing"
    case unclear
    case other
}

public enum TomorrowMapProductTelemetryEntryPoint: String, Codable, CaseIterable, Sendable {
    case automaticNow = "automatic_now"
    case notification
    case widget
}

public enum TomorrowMapProductTelemetrySessionOutcome: String, Codable, CaseIterable, Sendable {
    case dismissed
    case feedback
    case backgrounded
}

public enum TomorrowMapProductTelemetryFeedbackRating: String, Codable, CaseIterable, Sendable {
    case useful
    case notUseful = "not_useful"
    case addedFriction = "added_friction"
}

public enum TomorrowMapProductTelemetryFeedbackReason: String, Codable, CaseIterable, Sendable {
    case wrongContext = "wrong_context"
    case badTiming = "bad_timing"
    case alreadyHandled = "already_handled"
    case tooIntrusive = "too_intrusive"
    case reasoningWrong = "reasoning_wrong"
    case factWrong = "fact_wrong"
    case preferenceChanged = "preference_changed"
    case showLess = "show_less"
    case other
}

public enum TomorrowMapProductTelemetryPlanDeviation: String, Codable, CaseIterable, Sendable {
    case none
    case minor
    case material
    case unknown
}

public enum TomorrowMapProductTelemetryInfluence: String, Codable, CaseIterable, Sendable {
    case helped
    case noEffect = "no_effect"
    case addedBurden = "added_burden"
    case uncertain
}

public struct CaptureProductTelemetryWorkflow: Hashable, Sendable {
    fileprivate let sessionID: UUIDv7
    fileprivate let startEventID: UUIDv7
    fileprivate let startedAt: Date
    fileprivate let captureKind: String
    fileprivate let invokingSurface: String
}

public struct TomorrowMapProductTelemetrySession: Hashable, Sendable {
    fileprivate let sessionID: UUIDv7
    fileprivate let startEventID: UUIDv7
    fileprivate let startedAt: Date
}

public actor ProductTelemetryRecorder {
    private static let contextVersion = "product_telemetry_registry_v1"

    private let store: any ProductTelemetryStoring
    private let deviceID: UUIDv7
    private let appBuild: String
    private let featureAssignments: @Sendable () throws -> [FeatureFlagKey: String]
    private let clock: @Sendable () -> Date
    private let identifier: @Sendable () -> UUIDv7
    private var attemptedEventCount = 0
    private var recordedEventCount = 0
    private var preferenceSkippedEventCount = 0
    private var featureFlagSkippedEventCount = 0
    private var storageSkippedEventCount = 0
    private var unsupportedContextEventCount = 0
    private var failedEventCount = 0
    private var lastFailure: ProductTelemetryRecorderFailure?
    private var lastFailureAt: Date?

    public init(
        store: any ProductTelemetryStoring,
        deviceID: UUIDv7,
        appBuild: String,
        featureAssignments: @escaping @Sendable () throws -> [FeatureFlagKey: String],
        clock: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> UUIDv7 = UUIDv7.init
    ) throws {
        guard (1 ... 100).contains(appBuild.count),
              appBuild == appBuild.trimmingCharacters(in: .whitespacesAndNewlines),
              appBuild.utf8.allSatisfy({ (32 ... 126).contains($0) })
        else {
            throw ProductTelemetryRecorderConfigurationError.invalidAppBuild
        }
        self.store = store
        self.deviceID = deviceID
        self.appBuild = appBuild
        self.featureAssignments = featureAssignments
        self.clock = clock
        self.identifier = identifier
    }

    public func beginCaptureWorkflow(
        kind: CapturePayloadKind,
        invokingSurface: CaptureInvokingSurface,
        at startedAt: Date? = nil
    ) -> CaptureProductTelemetryWorkflow? {
        guard let captureKind = Self.captureKind(kind),
              let surface = Self.captureSurface(invokingSurface)
        else {
            recordUnsupportedContext()
            return nil
        }
        let occurredAt = startedAt ?? clock()
        let sessionID = identifier()
        let startEventID = identifier()
        let disposition = record(
            eventID: startEventID,
            occurredAt: occurredAt,
            sessionID: sessionID,
            surface: surface,
            eventName: .captureWorkflowStarted,
            properties: [
                "capture_kind": .string(captureKind),
                "invoking_surface": .string(surface),
            ]
        )
        guard disposition == .recorded else { return nil }
        return CaptureProductTelemetryWorkflow(
            sessionID: sessionID,
            startEventID: startEventID,
            startedAt: occurredAt,
            captureKind: captureKind,
            invokingSurface: surface
        )
    }

    @discardableResult
    public func finishCaptureWorkflow(
        _ workflow: CaptureProductTelemetryWorkflow,
        outcome: CaptureProductTelemetryOutcome,
        exitStage: CaptureProductTelemetryExitStage,
        at finishedAt: Date? = nil
    ) -> ProductTelemetryRecordingDisposition {
        let occurredAt = finishedAt ?? clock()
        guard let durationBucket = ProductTelemetryDurationBucket.elapsed(
            from: workflow.startedAt,
            to: occurredAt
        ) else {
            recordUnsupportedContext()
            return .unsupportedContext
        }
        return record(
            occurredAt: occurredAt,
            sessionID: workflow.sessionID,
            surface: workflow.invokingSurface,
            eventName: .captureWorkflowFinished,
            properties: [
                "capture_kind": .string(workflow.captureKind),
                "invoking_surface": .string(workflow.invokingSurface),
                "outcome": .string(outcome.rawValue),
                "exit_stage": .string(exitStage.rawValue),
                "duration_bucket": .string(durationBucket.rawValue),
            ],
            causalParentEventID: workflow.startEventID
        )
    }

    @discardableResult
    public func recordCaptureFeedback(
        rating: CaptureProductTelemetryFeedbackRating,
        reason: CaptureProductTelemetryFeedbackReason? = nil,
        workflow: CaptureProductTelemetryWorkflow? = nil,
        at occurredAt: Date? = nil
    ) -> ProductTelemetryRecordingDisposition {
        var properties: [String: ProductTelemetryPropertyValue] = [
            "rating": .string(rating.rawValue),
        ]
        if let reason {
            properties["reason"] = .string(reason.rawValue)
        }
        return record(
            occurredAt: occurredAt ?? clock(),
            sessionID: workflow?.sessionID,
            surface: workflow?.invokingSurface ?? "iphone_now",
            eventName: .captureFeedbackRecorded,
            properties: properties,
            causalParentEventID: workflow?.startEventID
        )
    }

    @discardableResult
    public func recordTomorrowMapAvailability(
        _ projection: TomorrowMapProjection
    ) -> ProductTelemetryRecordingDisposition {
        record(
            occurredAt: projection.generatedAt,
            surface: "iphone_now",
            eventName: .tomorrowMapAvailabilityEvaluated,
            properties: [
                "calendar_state": .string(projection.calendarState.rawValue),
                "intentionally_absent": .boolean(projection.isIntentionallyOpen),
                "transition_count": .integer(projection.transitions.count),
                "pressure_present": .boolean(projection.pressurePoint != nil),
                "protected_open_present": .boolean(projection.protectedOpenPeriod != nil),
            ]
        )
    }

    public func beginTomorrowMapSession(
        calendarState: TomorrowCalendarState,
        entryPoint: TomorrowMapProductTelemetryEntryPoint,
        at startedAt: Date? = nil
    ) -> TomorrowMapProductTelemetrySession? {
        let occurredAt = startedAt ?? clock()
        let sessionID = identifier()
        let startEventID = identifier()
        let disposition = record(
            eventID: startEventID,
            occurredAt: occurredAt,
            sessionID: sessionID,
            surface: "iphone_now",
            eventName: .tomorrowMapViewed,
            properties: [
                "calendar_state": .string(calendarState.rawValue),
                "entry_point": .string(entryPoint.rawValue),
            ]
        )
        guard disposition == .recorded else { return nil }
        return TomorrowMapProductTelemetrySession(
            sessionID: sessionID,
            startEventID: startEventID,
            startedAt: occurredAt
        )
    }

    @discardableResult
    public func finishTomorrowMapSession(
        _ session: TomorrowMapProductTelemetrySession,
        outcome: TomorrowMapProductTelemetrySessionOutcome,
        at finishedAt: Date? = nil
    ) -> ProductTelemetryRecordingDisposition {
        let occurredAt = finishedAt ?? clock()
        guard let durationBucket = ProductTelemetryDurationBucket.elapsed(
            from: session.startedAt,
            to: occurredAt
        ) else {
            recordUnsupportedContext()
            return .unsupportedContext
        }
        return record(
            occurredAt: occurredAt,
            sessionID: session.sessionID,
            surface: "iphone_now",
            eventName: .tomorrowMapSessionFinished,
            properties: [
                "duration_bucket": .string(durationBucket.rawValue),
                "outcome": .string(outcome.rawValue),
            ],
            causalParentEventID: session.startEventID
        )
    }

    @discardableResult
    public func recordTomorrowMapFeedback(
        rating: TomorrowMapProductTelemetryFeedbackRating,
        reason: TomorrowMapProductTelemetryFeedbackReason? = nil,
        session: TomorrowMapProductTelemetrySession? = nil,
        at occurredAt: Date? = nil
    ) -> ProductTelemetryRecordingDisposition {
        var properties: [String: ProductTelemetryPropertyValue] = [
            "rating": .string(rating.rawValue),
        ]
        if let reason {
            properties["reason"] = .string(reason.rawValue)
        }
        return record(
            occurredAt: occurredAt ?? clock(),
            sessionID: session?.sessionID,
            surface: "iphone_now",
            eventName: .tomorrowMapFeedbackRecorded,
            properties: properties,
            causalParentEventID: session?.startEventID
        )
    }

    @discardableResult
    public func recordTomorrowMapPlanDeviation(
        deviation: TomorrowMapProductTelemetryPlanDeviation,
        influence: TomorrowMapProductTelemetryInfluence,
        at occurredAt: Date? = nil
    ) -> ProductTelemetryRecordingDisposition {
        record(
            occurredAt: occurredAt ?? clock(),
            surface: "iphone_now",
            eventName: .tomorrowMapPlanDeviationRecorded,
            properties: [
                "deviation": .string(deviation.rawValue),
                "map_influence": .string(influence.rawValue),
            ]
        )
    }

    public func diagnostics() -> ProductTelemetryRecorderDiagnostics {
        ProductTelemetryRecorderDiagnostics(
            attemptedEventCount: attemptedEventCount,
            recordedEventCount: recordedEventCount,
            preferenceSkippedEventCount: preferenceSkippedEventCount,
            featureFlagSkippedEventCount: featureFlagSkippedEventCount,
            storageSkippedEventCount: storageSkippedEventCount,
            unsupportedContextEventCount: unsupportedContextEventCount,
            failedEventCount: failedEventCount,
            lastFailure: lastFailure,
            lastFailureAt: lastFailureAt
        )
    }

    private func record(
        eventID: UUIDv7? = nil,
        occurredAt: Date,
        sessionID: UUIDv7? = nil,
        surface: String,
        eventName: ProductTelemetryEventName,
        properties: [String: ProductTelemetryPropertyValue],
        causalParentEventID: UUIDv7? = nil
    ) -> ProductTelemetryRecordingDisposition {
        attemptedEventCount += 1
        let definition = ProductTelemetryRegistry.definition(for: eventName)
        let preferences: ProductTelemetryPreferences
        do {
            preferences = try store.productTelemetryPreferences()
        } catch {
            return recordFailure(.persistence)
        }
        guard preferences.enables(definition.questionID) else {
            preferenceSkippedEventCount += 1
            return .skippedByPreference
        }

        let assignments: [FeatureFlagKey: String]
        do {
            assignments = try featureAssignments()
        } catch {
            return recordFailure(.featureConfiguration)
        }
        let featureFlag = Self.featureFlag(for: definition.questionID)
        guard assignments[featureFlag] == "enabled" else {
            featureFlagSkippedEventCount += 1
            return .skippedByFeatureFlag
        }

        let receivedAt = clock()
        let event: ProductTelemetryEvent
        do {
            event = try ProductTelemetryEvent(
                eventID: eventID ?? identifier(),
                occurredAt: occurredAt,
                receivedAt: receivedAt,
                sessionID: sessionID,
                deviceID: deviceID,
                appBuild: appBuild,
                surface: surface,
                eventName: eventName,
                contextVersion: Self.contextVersion,
                featureFlagAssignments: Dictionary(
                    uniqueKeysWithValues: assignments.map { ($0.key.rawValue, $0.value) }
                ),
                properties: properties,
                causalParentEventID: causalParentEventID,
                localOnly: true
            )
        } catch {
            return recordFailure(.eventConstruction)
        }
        do {
            guard try store.appendProductTelemetryEvent(event) else {
                storageSkippedEventCount += 1
                return .skippedByStorage
            }
        } catch {
            return recordFailure(.persistence)
        }
        recordedEventCount += 1
        return .recorded
    }

    private func recordUnsupportedContext() {
        attemptedEventCount += 1
        unsupportedContextEventCount += 1
    }

    private func recordFailure(
        _ failure: ProductTelemetryRecorderFailure
    ) -> ProductTelemetryRecordingDisposition {
        failedEventCount += 1
        lastFailure = failure
        lastFailureAt = clock()
        return .failed(failure)
    }

    private static func featureFlag(
        for questionID: ProductTelemetryQuestionID
    ) -> FeatureFlagKey {
        switch questionID {
        case .captureFriction:
            .captureTelemetryQuestion
        case .tomorrowMapValue:
            .tomorrowMapTelemetryQuestion
        }
    }

    private static func captureKind(_ kind: CapturePayloadKind) -> String? {
        switch kind {
        case .text:
            "text"
        case .audio:
            "audio"
        case .imageReference:
            "image_reference"
        case .fileReference:
            "file_reference"
        case .structuredQuickAction:
            nil
        }
    }

    private static func captureSurface(_ surface: CaptureInvokingSurface) -> String? {
        switch surface {
        case .iPhoneNow:
            "iphone_now"
        case .iPhoneGlobalCapture:
            "iphone_global_capture"
        case .appIntent:
            "app_intent"
        case .shareExtension:
            "share"
        case .widget:
            "widget"
        case .watchQuickAction:
            "watch"
        case .control:
            "control"
        case .mac:
            "mac"
        default:
            nil
        }
    }
}
