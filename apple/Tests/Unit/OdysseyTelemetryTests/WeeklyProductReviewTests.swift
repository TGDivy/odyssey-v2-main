import Foundation
import OdysseyDomain
import OdysseyTelemetry
import Testing

private let weeklyReviewEnd = Date(timeIntervalSince1970: 1_786_838_400)
private let weeklyReviewStart = weeklyReviewEnd.addingTimeInterval(
    -WeeklyProductReviewGenerator.reviewDuration
)
private let weeklyReviewDeviceID = try! weeklyReviewUUID(900)

@Test
func weeklyProductReviewAggregatesBoundedQuestionEvidence() throws {
    let captureSessionOne = try weeklyReviewUUID(501)
    let captureSessionTwo = try weeklyReviewUUID(502)
    let tomorrowSession = try weeklyReviewUUID(601)
    let events = try [
        weeklyReviewEvent(
            1,
            name: .captureWorkflowStarted,
            offset: 100,
            sessionID: captureSessionOne,
            properties: captureStartedProperties()
        ),
        weeklyReviewEvent(
            2,
            name: .captureWorkflowFinished,
            offset: 102,
            sessionID: captureSessionOne,
            properties: captureFinishedProperties(
                outcome: "committed",
                duration: "1_to_3s"
            )
        ),
        weeklyReviewEvent(
            3,
            name: .captureWorkflowStarted,
            offset: 200,
            sessionID: captureSessionTwo,
            properties: captureStartedProperties()
        ),
        weeklyReviewEvent(
            4,
            name: .captureWorkflowFinished,
            offset: 204,
            sessionID: captureSessionTwo,
            properties: captureFinishedProperties(
                outcome: "abandoned",
                duration: "3_to_5s"
            )
        ),
        weeklyReviewEvent(
            5,
            name: .captureFeedbackRecorded,
            offset: 205,
            properties: ["rating": .string("added_friction")]
        ),
        weeklyReviewEvent(
            6,
            name: .tomorrowMapAvailabilityEvaluated,
            offset: 300,
            properties: tomorrowAvailabilityProperties(
                calendarState: "fresh",
                intentionallyAbsent: false
            )
        ),
        weeklyReviewEvent(
            7,
            name: .tomorrowMapAvailabilityEvaluated,
            offset: 400,
            properties: tomorrowAvailabilityProperties(
                calendarState: "fresh",
                intentionallyAbsent: true
            )
        ),
        weeklyReviewEvent(
            8,
            name: .tomorrowMapAvailabilityEvaluated,
            offset: 500,
            properties: tomorrowAvailabilityProperties(
                calendarState: "missing",
                intentionallyAbsent: false
            )
        ),
        weeklyReviewEvent(
            9,
            name: .tomorrowMapViewed,
            offset: 600,
            sessionID: tomorrowSession,
            properties: [
                "calendar_state": .string("fresh"),
                "entry_point": .string("automatic_now"),
            ]
        ),
        weeklyReviewEvent(
            10,
            name: .tomorrowMapSessionFinished,
            offset: 606,
            sessionID: tomorrowSession,
            properties: [
                "duration_bucket": .string("5_to_10s"),
                "outcome": .string("feedback"),
            ]
        ),
        weeklyReviewEvent(
            11,
            name: .tomorrowMapFeedbackRecorded,
            offset: 607,
            sessionID: tomorrowSession,
            properties: ["rating": .string("useful")]
        ),
        weeklyReviewEvent(
            12,
            name: .tomorrowMapFeedbackRecorded,
            offset: 608,
            properties: ["rating": .string("useful")]
        ),
        weeklyReviewEvent(
            13,
            name: .tomorrowMapPlanDeviationRecorded,
            offset: 700,
            properties: [
                "deviation": .string("material"),
                "map_influence": .string("helped"),
            ]
        ),
    ]

    let artifact = try WeeklyProductReviewGenerator().generate(
        events: events,
        preferences: weeklyReviewPreferences(),
        periodStart: weeklyReviewStart,
        periodEnd: weeklyReviewEnd,
        generatedAt: weeklyReviewEnd
    )

    #expect(artifact.schemaVersion == 1)
    #expect(artifact.sourceQuality.retainedEventCount == events.count)
    #expect(artifact.sourceQuality.coversFullReviewInterval)
    #expect(artifact.capture.workflowStartedCount == 2)
    #expect(artifact.capture.workflowFinishedCount == 2)
    #expect(artifact.capture.committedCount == 1)
    #expect(artifact.capture.abandonedCount == 1)
    #expect(artifact.capture.openWorkflowCount == 0)
    #expect(artifact.capture.feedback.addedFrictionCount == 1)
    #expect(artifact.capture.durationDistribution.oneToThreeSeconds == 1)
    #expect(artifact.capture.durationDistribution.threeToFiveSeconds == 1)
    #expect(artifact.tomorrowMap.availabilityEvaluationCount == 3)
    #expect(artifact.tomorrowMap.freshCalendarCount == 2)
    #expect(artifact.tomorrowMap.missingCalendarCount == 1)
    #expect(artifact.tomorrowMap.intentionallyAbsentCount == 1)
    #expect(artifact.tomorrowMap.viewedCount == 1)
    #expect(artifact.tomorrowMap.feedbackFinishedCount == 1)
    #expect(artifact.tomorrowMap.feedback.usefulCount == 2)
    #expect(artifact.tomorrowMap.deviation.materialDeviationCount == 1)
    #expect(artifact.tomorrowMap.deviation.helpedCount == 1)
    #expect(Set(artifact.observations.map(\.kind)) == [
        .insufficientCaptureSample,
        .intentionalTomorrowSilenceObserved,
        .tomorrowMapValueSignal,
    ])
    let valueObservation = try #require(artifact.observations.first {
        $0.kind == .tomorrowMapValueSignal
    })
    #expect(valueObservation.sampleSize == 2)
    #expect(valueObservation.supportingEventCount == 2)
    #expect(valueObservation.counterexampleCount == 0)
}

@Test
func weeklyProductReviewSurfacesPatternsCounterexamplesAndIncompleteSessions() throws {
    var events: [ProductTelemetryEvent] = []
    for index in 1 ... 5 {
        let sessionID = try weeklyReviewUUID(700 + index)
        events.append(try weeklyReviewEvent(
            100 + index * 2,
            name: .captureWorkflowStarted,
            offset: TimeInterval(1_000 + index * 10),
            sessionID: sessionID,
            properties: captureStartedProperties()
        ))
        if index < 5 {
            events.append(try weeklyReviewEvent(
                101 + index * 2,
                name: .captureWorkflowFinished,
                offset: TimeInterval(1_004 + index * 10),
                sessionID: sessionID,
                properties: captureFinishedProperties(
                    outcome: index <= 2 ? "abandoned" : "committed",
                    duration: "3_to_5s"
                )
            ))
        }
    }
    events.append(try weeklyReviewEvent(
        120,
        name: .captureFeedbackRecorded,
        offset: 1_100,
        properties: ["rating": .string("added_friction")]
    ))
    events.append(try weeklyReviewEvent(
        121,
        name: .captureFeedbackRecorded,
        offset: 1_101,
        properties: ["rating": .string("added_friction")]
    ))

    let artifact = try WeeklyProductReviewGenerator().generate(
        events: events,
        preferences: weeklyReviewPreferences(retentionDays: 3),
        periodStart: weeklyReviewStart,
        periodEnd: weeklyReviewEnd,
        generatedAt: weeklyReviewEnd,
        sourceTruncated: true
    )

    #expect(!artifact.sourceQuality.coversFullReviewInterval)
    #expect(artifact.capture.openWorkflowCount == 1)
    let abandonment = try #require(artifact.observations.first {
        $0.kind == .captureAbandonmentNeedsReview
    })
    #expect(abandonment.sampleSize == 4)
    #expect(abandonment.supportingEventCount == 2)
    #expect(abandonment.counterexampleCount == 2)
    #expect(artifact.observations.contains {
        $0.kind == .captureFrictionNeedsReview && $0.counterexampleCount == 0
    })
    #expect(artifact.observations.contains {
        $0.kind == .incompleteCaptureLifecycle && $0.supportingEventCount == 1
    })
}

@Test
func weeklyProductReviewRejectsDuplicateOutsideOrRemoteEvents() throws {
    let local = try weeklyReviewEvent(
        300,
        name: .captureWorkflowStarted,
        offset: 100,
        properties: captureStartedProperties()
    )
    let generator = WeeklyProductReviewGenerator()
    #expect(throws: WeeklyProductReviewError.duplicateEvent) {
        try generator.generate(
            events: [local, local],
            preferences: weeklyReviewPreferences(),
            periodStart: weeklyReviewStart,
            periodEnd: weeklyReviewEnd,
            generatedAt: weeklyReviewEnd
        )
    }
    #expect(throws: WeeklyProductReviewError.eventOutsideInterval) {
        try generator.generate(
            events: [try weeklyReviewEvent(
                301,
                name: .captureWorkflowStarted,
                offset: WeeklyProductReviewGenerator.reviewDuration,
                properties: captureStartedProperties()
            )],
            preferences: weeklyReviewPreferences(),
            periodStart: weeklyReviewStart,
            periodEnd: weeklyReviewEnd,
            generatedAt: weeklyReviewEnd
        )
    }
    #expect(throws: WeeklyProductReviewError.nonLocalEvent) {
        try generator.generate(
            events: [try weeklyReviewEvent(
                302,
                name: .captureWorkflowStarted,
                offset: 100,
                properties: captureStartedProperties(),
                localOnly: false
            )],
            preferences: weeklyReviewPreferences(),
            periodStart: weeklyReviewStart,
            periodEnd: weeklyReviewEnd,
            generatedAt: weeklyReviewEnd
        )
    }
}

private func weeklyReviewEvent(
    _ identifier: Int,
    name: ProductTelemetryEventName,
    offset: TimeInterval,
    sessionID: UUIDv7? = nil,
    properties: [String: ProductTelemetryPropertyValue],
    localOnly: Bool = true
) throws -> ProductTelemetryEvent {
    let occurredAt = weeklyReviewStart.addingTimeInterval(offset)
    return try ProductTelemetryEvent(
        eventID: weeklyReviewUUID(identifier),
        occurredAt: occurredAt,
        receivedAt: occurredAt,
        sessionID: sessionID,
        deviceID: weeklyReviewDeviceID,
        appBuild: "1.0.0 (900)",
        surface: "iphone_now",
        eventName: name,
        contextVersion: "product_telemetry_registry_v1",
        featureFlagAssignments: [
            FeatureFlagKey.captureTelemetryQuestion.rawValue: "enabled",
            FeatureFlagKey.tomorrowMapTelemetryQuestion.rawValue: "enabled",
        ],
        properties: properties,
        localOnly: localOnly
    )
}

private func weeklyReviewUUID(_ identifier: Int) throws -> UUIDv7 {
    let value = String(
        format: "018f22d2-8a80-7000-8000-%012llx",
        Int64(identifier)
    )
    return try UUIDv7(validating: #require(UUID(uuidString: value)))
}

private func weeklyReviewPreferences(
    retentionDays: Int = 7
) throws -> ProductTelemetryPreferences {
    try ProductTelemetryPreferences(
        collectionMode: .localOnly,
        enabledQuestions: ProductTelemetryQuestionID.allCases,
        retentionDays: retentionDays
    )
}

private func captureStartedProperties() -> [String: ProductTelemetryPropertyValue] {
    [
        "capture_kind": .string("text"),
        "invoking_surface": .string("iphone_now"),
    ]
}

private func captureFinishedProperties(
    outcome: String,
    duration: String
) -> [String: ProductTelemetryPropertyValue] {
    [
        "capture_kind": .string("text"),
        "invoking_surface": .string("iphone_now"),
        "outcome": .string(outcome),
        "exit_stage": .string("local_commit"),
        "duration_bucket": .string(duration),
    ]
}

private func tomorrowAvailabilityProperties(
    calendarState: String,
    intentionallyAbsent: Bool
) -> [String: ProductTelemetryPropertyValue] {
    [
        "calendar_state": .string(calendarState),
        "intentionally_absent": .boolean(intentionallyAbsent),
        "transition_count": .integer(0),
        "pressure_present": .boolean(false),
        "protected_open_present": .boolean(false),
    ]
}
