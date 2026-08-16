import Foundation
import OdysseyTelemetry
import Testing

private let warmPathFinishedAt = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func foodWarmPathRequiresCommittedTwoOrThreeInteractionUnderFiveSeconds() throws {
    let token = try WarmPathTimer.start(
        workflow: .foodQuickLog,
        surface: .widget,
        initialInteractionCount: 1,
        correlationID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        uptimeNanoseconds: 1_000_000_000
    )
    let passing = try WarmPathTimer.finish(
        token,
        outcome: .committed,
        additionalInteractionCount: 1,
        finishedAt: warmPathFinishedAt,
        uptimeNanoseconds: 5_200_000_000
    )
    let tooSlow = try WarmPathTimer.finish(
        token,
        outcome: .committed,
        additionalInteractionCount: 1,
        finishedAt: warmPathFinishedAt,
        uptimeNanoseconds: 6_000_000_000
    )

    #expect(passing.durationMilliseconds == 4_200)
    #expect(passing.interactionCount == 2)
    #expect(passing.meetsTarget)
    #expect(!tooSlow.meetsTarget)
    #expect(passing.technicalSignal.dimensions["duration_bucket"] == "3_to_5s")
    #expect(passing.technicalSignal.dimensions["met_target"] == "true")
}

@Test
func warmPathTimerRejectsInvalidInteractionAndMonotonicClock() throws {
    #expect(throws: WarmPathTimingError.invalidInteractionCount) {
        try WarmPathTimer.start(
            workflow: .foodQuickLog,
            surface: .iPhone,
            initialInteractionCount: 21
        )
    }
    let token = try WarmPathTimer.start(
        workflow: .foodQuickLog,
        surface: .iPhone,
        uptimeNanoseconds: 100
    )
    #expect(throws: WarmPathTimingError.invalidClock) {
        try WarmPathTimer.finish(
            token,
            outcome: .failed,
            additionalInteractionCount: 1,
            finishedAt: warmPathFinishedAt,
            uptimeNanoseconds: 99
        )
    }
}
