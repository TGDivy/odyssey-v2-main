import Foundation

public enum WeeklyProductReviewError: Error, Equatable, Sendable {
    case invalidInterval
    case invalidGeneratedAt
    case tooManyEvents
    case duplicateEvent
    case eventOutsideInterval
    case eventReceivedAfterReview
    case nonLocalEvent
}

public enum WeeklyProductReviewObservationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case insufficientCaptureSample = "insufficient_capture_sample"
    case captureAbandonmentNeedsReview = "capture_abandonment_needs_review"
    case captureFrictionNeedsReview = "capture_friction_needs_review"
    case incompleteCaptureLifecycle = "incomplete_capture_lifecycle"
    case insufficientTomorrowMapSample = "insufficient_tomorrow_map_sample"
    case intentionalTomorrowSilenceObserved = "intentional_tomorrow_silence_observed"
    case tomorrowMapValueSignal = "tomorrow_map_value_signal"
    case tomorrowMapFrictionNeedsReview = "tomorrow_map_friction_needs_review"
    case incompleteTomorrowMapLifecycle = "incomplete_tomorrow_map_lifecycle"
}

public struct WeeklyProductReviewObservation: Codable, Hashable, Sendable {
    public let kind: WeeklyProductReviewObservationKind
    public let questionID: ProductTelemetryQuestionID
    public let sampleSize: Int
    public let supportingEventCount: Int
    public let counterexampleCount: Int
}

public struct WeeklyProductTelemetryDurationDistribution: Codable, Hashable, Sendable {
    public let underOneSecond: Int
    public let oneToThreeSeconds: Int
    public let threeToFiveSeconds: Int
    public let fiveToTenSeconds: Int
    public let tenToThirtySeconds: Int
    public let thirtySecondsOrMore: Int

    public var totalCount: Int {
        underOneSecond
            + oneToThreeSeconds
            + threeToFiveSeconds
            + fiveToTenSeconds
            + tenToThirtySeconds
            + thirtySecondsOrMore
    }
}

public struct WeeklyCaptureFeedbackSummary: Codable, Hashable, Sendable {
    public let responseCount: Int
    public let usefulCount: Int
    public let neutralCount: Int
    public let addedFrictionCount: Int
}

public struct WeeklyCaptureProductReview: Codable, Hashable, Sendable {
    public let workflowStartedCount: Int
    public let workflowFinishedCount: Int
    public let committedCount: Int
    public let failedCount: Int
    public let abandonedCount: Int
    public let openWorkflowCount: Int
    public let orphanedFinishCount: Int
    public let feedback: WeeklyCaptureFeedbackSummary
    public let durationDistribution: WeeklyProductTelemetryDurationDistribution
}

public struct WeeklyTomorrowMapFeedbackSummary: Codable, Hashable, Sendable {
    public let responseCount: Int
    public let usefulCount: Int
    public let notUsefulCount: Int
    public let addedFrictionCount: Int
}

public struct WeeklyTomorrowMapDeviationSummary: Codable, Hashable, Sendable {
    public let responseCount: Int
    public let noDeviationCount: Int
    public let minorDeviationCount: Int
    public let materialDeviationCount: Int
    public let unknownDeviationCount: Int
    public let helpedCount: Int
    public let noEffectCount: Int
    public let addedBurdenCount: Int
    public let uncertainInfluenceCount: Int
}

public struct WeeklyTomorrowMapProductReview: Codable, Hashable, Sendable {
    public let availabilityEvaluationCount: Int
    public let freshCalendarCount: Int
    public let staleCalendarCount: Int
    public let missingCalendarCount: Int
    public let deniedCalendarCount: Int
    public let unavailableCalendarCount: Int
    public let intentionallyAbsentCount: Int
    public let viewedCount: Int
    public let sessionFinishedCount: Int
    public let dismissedCount: Int
    public let feedbackFinishedCount: Int
    public let backgroundedCount: Int
    public let openSessionCount: Int
    public let orphanedFinishCount: Int
    public let feedback: WeeklyTomorrowMapFeedbackSummary
    public let deviation: WeeklyTomorrowMapDeviationSummary
    public let durationDistribution: WeeklyProductTelemetryDurationDistribution
}

public struct WeeklyProductReviewSourceQuality: Codable, Hashable, Sendable {
    public let retainedEventCount: Int
    public let retentionCoverageDays: Int
    public let sourceTruncated: Bool

    public var coversFullReviewInterval: Bool {
        retentionCoverageDays >= 7 && !sourceTruncated
    }
}

public struct WeeklyProductReviewArtifact: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let periodStart: Date
    public let periodEnd: Date
    public let generatedAt: Date
    public let preferences: ProductTelemetryPreferences
    public let sourceQuality: WeeklyProductReviewSourceQuality
    public let capture: WeeklyCaptureProductReview
    public let tomorrowMap: WeeklyTomorrowMapProductReview
    public let observations: [WeeklyProductReviewObservation]

    fileprivate init(
        periodStart: Date,
        periodEnd: Date,
        generatedAt: Date,
        preferences: ProductTelemetryPreferences,
        sourceQuality: WeeklyProductReviewSourceQuality,
        capture: WeeklyCaptureProductReview,
        tomorrowMap: WeeklyTomorrowMapProductReview,
        observations: [WeeklyProductReviewObservation]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.generatedAt = generatedAt
        self.preferences = preferences
        self.sourceQuality = sourceQuality
        self.capture = capture
        self.tomorrowMap = tomorrowMap
        self.observations = observations
    }
}

public struct WeeklyProductReviewGenerator: Sendable {
    public static let reviewDuration: TimeInterval = 7 * 86_400
    public static let maximumEventCount = 5_000

    public init() {}

    public func generate(
        events: [ProductTelemetryEvent],
        preferences: ProductTelemetryPreferences,
        periodStart: Date,
        periodEnd: Date,
        generatedAt: Date,
        sourceTruncated: Bool = false
    ) throws -> WeeklyProductReviewArtifact {
        guard periodStart.timeIntervalSinceReferenceDate.isFinite,
              periodEnd.timeIntervalSinceReferenceDate.isFinite,
              periodEnd > periodStart,
              abs(periodEnd.timeIntervalSince(periodStart) - Self.reviewDuration) < 0.001
        else {
            throw WeeklyProductReviewError.invalidInterval
        }
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite,
              generatedAt >= periodEnd
        else {
            throw WeeklyProductReviewError.invalidGeneratedAt
        }
        guard events.count <= Self.maximumEventCount else {
            throw WeeklyProductReviewError.tooManyEvents
        }
        guard Set(events.map(\.eventID)).count == events.count else {
            throw WeeklyProductReviewError.duplicateEvent
        }
        guard events.allSatisfy({
            $0.occurredAt >= periodStart && $0.occurredAt < periodEnd
        }) else {
            throw WeeklyProductReviewError.eventOutsideInterval
        }
        guard events.allSatisfy({ $0.receivedAt <= generatedAt }) else {
            throw WeeklyProductReviewError.eventReceivedAfterReview
        }
        guard events.allSatisfy(\.localOnly) else {
            throw WeeklyProductReviewError.nonLocalEvent
        }

        let capture = captureReview(events)
        let tomorrowMap = tomorrowMapReview(events)
        return WeeklyProductReviewArtifact(
            periodStart: periodStart,
            periodEnd: periodEnd,
            generatedAt: generatedAt,
            preferences: preferences,
            sourceQuality: WeeklyProductReviewSourceQuality(
                retainedEventCount: events.count,
                retentionCoverageDays: min(preferences.retentionDays, 7),
                sourceTruncated: sourceTruncated
            ),
            capture: capture,
            tomorrowMap: tomorrowMap,
            observations: observations(capture: capture, tomorrowMap: tomorrowMap)
        )
    }

    private func captureReview(
        _ events: [ProductTelemetryEvent]
    ) -> WeeklyCaptureProductReview {
        let started = events.filter { $0.eventName == .captureWorkflowStarted }
        let finished = events.filter { $0.eventName == .captureWorkflowFinished }
        let feedbackEvents = events.filter { $0.eventName == .captureFeedbackRecorded }
        let startedSessions = Set(started.compactMap(\.sessionID))
        let finishedSessions = Set(finished.compactMap(\.sessionID))
        return WeeklyCaptureProductReview(
            workflowStartedCount: started.count,
            workflowFinishedCount: finished.count,
            committedCount: count(finished, property: "outcome", value: "committed"),
            failedCount: count(finished, property: "outcome", value: "failed"),
            abandonedCount: count(finished, property: "outcome", value: "abandoned"),
            openWorkflowCount: startedSessions.subtracting(finishedSessions).count,
            orphanedFinishCount: finishedSessions.subtracting(startedSessions).count,
            feedback: WeeklyCaptureFeedbackSummary(
                responseCount: feedbackEvents.count,
                usefulCount: count(feedbackEvents, property: "rating", value: "useful"),
                neutralCount: count(feedbackEvents, property: "rating", value: "neutral"),
                addedFrictionCount: count(
                    feedbackEvents,
                    property: "rating",
                    value: "added_friction"
                )
            ),
            durationDistribution: durationDistribution(finished)
        )
    }

    private func tomorrowMapReview(
        _ events: [ProductTelemetryEvent]
    ) -> WeeklyTomorrowMapProductReview {
        let availability = events.filter {
            $0.eventName == .tomorrowMapAvailabilityEvaluated
        }
        let viewed = events.filter { $0.eventName == .tomorrowMapViewed }
        let finished = events.filter { $0.eventName == .tomorrowMapSessionFinished }
        let feedbackEvents = events.filter { $0.eventName == .tomorrowMapFeedbackRecorded }
        let deviations = events.filter { $0.eventName == .tomorrowMapPlanDeviationRecorded }
        let viewedSessions = Set(viewed.compactMap(\.sessionID))
        let finishedSessions = Set(finished.compactMap(\.sessionID))
        return WeeklyTomorrowMapProductReview(
            availabilityEvaluationCount: availability.count,
            freshCalendarCount: count(availability, property: "calendar_state", value: "fresh"),
            staleCalendarCount: count(availability, property: "calendar_state", value: "stale"),
            missingCalendarCount: count(
                availability,
                property: "calendar_state",
                value: "missing"
            ),
            deniedCalendarCount: count(availability, property: "calendar_state", value: "denied"),
            unavailableCalendarCount: count(
                availability,
                property: "calendar_state",
                value: "unavailable"
            ),
            intentionallyAbsentCount: count(
                availability,
                property: "intentionally_absent",
                boolean: true
            ),
            viewedCount: viewed.count,
            sessionFinishedCount: finished.count,
            dismissedCount: count(finished, property: "outcome", value: "dismissed"),
            feedbackFinishedCount: count(finished, property: "outcome", value: "feedback"),
            backgroundedCount: count(finished, property: "outcome", value: "backgrounded"),
            openSessionCount: viewedSessions.subtracting(finishedSessions).count,
            orphanedFinishCount: finishedSessions.subtracting(viewedSessions).count,
            feedback: WeeklyTomorrowMapFeedbackSummary(
                responseCount: feedbackEvents.count,
                usefulCount: count(feedbackEvents, property: "rating", value: "useful"),
                notUsefulCount: count(feedbackEvents, property: "rating", value: "not_useful"),
                addedFrictionCount: count(
                    feedbackEvents,
                    property: "rating",
                    value: "added_friction"
                )
            ),
            deviation: WeeklyTomorrowMapDeviationSummary(
                responseCount: deviations.count,
                noDeviationCount: count(deviations, property: "deviation", value: "none"),
                minorDeviationCount: count(deviations, property: "deviation", value: "minor"),
                materialDeviationCount: count(
                    deviations,
                    property: "deviation",
                    value: "material"
                ),
                unknownDeviationCount: count(
                    deviations,
                    property: "deviation",
                    value: "unknown"
                ),
                helpedCount: count(deviations, property: "map_influence", value: "helped"),
                noEffectCount: count(
                    deviations,
                    property: "map_influence",
                    value: "no_effect"
                ),
                addedBurdenCount: count(
                    deviations,
                    property: "map_influence",
                    value: "added_burden"
                ),
                uncertainInfluenceCount: count(
                    deviations,
                    property: "map_influence",
                    value: "uncertain"
                )
            ),
            durationDistribution: durationDistribution(finished)
        )
    }

    private func observations(
        capture: WeeklyCaptureProductReview,
        tomorrowMap: WeeklyTomorrowMapProductReview
    ) -> [WeeklyProductReviewObservation] {
        var values: [WeeklyProductReviewObservation] = []
        if capture.workflowFinishedCount < 5 {
            values.append(observation(
                .insufficientCaptureSample,
                question: .captureFriction,
                sampleSize: capture.workflowFinishedCount,
                supporting: capture.workflowFinishedCount
            ))
        }
        if capture.abandonedCount >= 2,
           capture.abandonedCount * 5 >= max(capture.workflowFinishedCount, 1)
        {
            values.append(observation(
                .captureAbandonmentNeedsReview,
                question: .captureFriction,
                sampleSize: capture.workflowFinishedCount,
                supporting: capture.abandonedCount,
                counterexamples: capture.committedCount
            ))
        }
        if capture.feedback.addedFrictionCount >= 2 {
            values.append(observation(
                .captureFrictionNeedsReview,
                question: .captureFriction,
                sampleSize: capture.feedback.responseCount,
                supporting: capture.feedback.addedFrictionCount,
                counterexamples: capture.feedback.usefulCount + capture.feedback.neutralCount
            ))
        }
        if capture.openWorkflowCount + capture.orphanedFinishCount > 0 {
            values.append(observation(
                .incompleteCaptureLifecycle,
                question: .captureFriction,
                sampleSize: capture.workflowStartedCount + capture.workflowFinishedCount,
                supporting: capture.openWorkflowCount + capture.orphanedFinishCount,
                counterexamples: min(
                    capture.workflowStartedCount,
                    capture.workflowFinishedCount
                )
            ))
        }

        if tomorrowMap.availabilityEvaluationCount < 3 {
            values.append(observation(
                .insufficientTomorrowMapSample,
                question: .tomorrowMapValue,
                sampleSize: tomorrowMap.availabilityEvaluationCount,
                supporting: tomorrowMap.availabilityEvaluationCount
            ))
        }
        if tomorrowMap.intentionallyAbsentCount > 0 {
            values.append(observation(
                .intentionalTomorrowSilenceObserved,
                question: .tomorrowMapValue,
                sampleSize: tomorrowMap.availabilityEvaluationCount,
                supporting: tomorrowMap.intentionallyAbsentCount,
                counterexamples: max(
                    tomorrowMap.availabilityEvaluationCount
                        - tomorrowMap.intentionallyAbsentCount,
                    0
                )
            ))
        }
        let negativeTomorrowFeedback = tomorrowMap.feedback.notUsefulCount
            + tomorrowMap.feedback.addedFrictionCount
        if tomorrowMap.feedback.usefulCount >= 2,
           tomorrowMap.feedback.usefulCount > negativeTomorrowFeedback
        {
            values.append(observation(
                .tomorrowMapValueSignal,
                question: .tomorrowMapValue,
                sampleSize: tomorrowMap.feedback.responseCount,
                supporting: tomorrowMap.feedback.usefulCount,
                counterexamples: negativeTomorrowFeedback
            ))
        }
        if negativeTomorrowFeedback >= 2 {
            values.append(observation(
                .tomorrowMapFrictionNeedsReview,
                question: .tomorrowMapValue,
                sampleSize: tomorrowMap.feedback.responseCount,
                supporting: negativeTomorrowFeedback,
                counterexamples: tomorrowMap.feedback.usefulCount
            ))
        }
        if tomorrowMap.openSessionCount + tomorrowMap.orphanedFinishCount > 0 {
            values.append(observation(
                .incompleteTomorrowMapLifecycle,
                question: .tomorrowMapValue,
                sampleSize: tomorrowMap.viewedCount + tomorrowMap.sessionFinishedCount,
                supporting: tomorrowMap.openSessionCount + tomorrowMap.orphanedFinishCount,
                counterexamples: min(tomorrowMap.viewedCount, tomorrowMap.sessionFinishedCount)
            ))
        }
        return values.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private func observation(
        _ kind: WeeklyProductReviewObservationKind,
        question: ProductTelemetryQuestionID,
        sampleSize: Int,
        supporting: Int,
        counterexamples: Int = 0
    ) -> WeeklyProductReviewObservation {
        WeeklyProductReviewObservation(
            kind: kind,
            questionID: question,
            sampleSize: sampleSize,
            supportingEventCount: supporting,
            counterexampleCount: counterexamples
        )
    }

    private func durationDistribution(
        _ events: [ProductTelemetryEvent]
    ) -> WeeklyProductTelemetryDurationDistribution {
        WeeklyProductTelemetryDurationDistribution(
            underOneSecond: count(events, property: "duration_bucket", value: "under_1s"),
            oneToThreeSeconds: count(
                events,
                property: "duration_bucket",
                value: "1_to_3s"
            ),
            threeToFiveSeconds: count(
                events,
                property: "duration_bucket",
                value: "3_to_5s"
            ),
            fiveToTenSeconds: count(
                events,
                property: "duration_bucket",
                value: "5_to_10s"
            ),
            tenToThirtySeconds: count(
                events,
                property: "duration_bucket",
                value: "10_to_30s"
            ),
            thirtySecondsOrMore: count(
                events,
                property: "duration_bucket",
                value: "30s_or_more"
            )
        )
    }

    private func count(
        _ events: [ProductTelemetryEvent],
        property: String,
        value: String
    ) -> Int {
        events.count { event in
            guard case let .string(propertyValue) = event.properties[property] else {
                return false
            }
            return propertyValue == value
        }
    }

    private func count(
        _ events: [ProductTelemetryEvent],
        property: String,
        boolean: Bool
    ) -> Int {
        events.count { event in
            guard case let .boolean(propertyValue) = event.properties[property] else {
                return false
            }
            return propertyValue == boolean
        }
    }
}
