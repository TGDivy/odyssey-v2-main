import Foundation
import OdysseyIntelligence
import Testing

private let reentryNow = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func reentryBeginsAfterThreeDaysWithoutPenalizingFirstUse() throws {
    let projector = ReentryProjector()
    #expect(!(try projector.shouldEnter(lastSeen: nil, now: reentryNow)))
    #expect(!(try projector.shouldEnter(
        lastSeen: reentryNow.addingTimeInterval(-2 * 24 * 60 * 60),
        now: reentryNow
    )))
    #expect(try projector.shouldEnter(
        lastSeen: reentryNow.addingTimeInterval(-3 * 24 * 60 * 60),
        now: reentryNow
    ))
}

@Test
func reentryBoundsSummarySelectsOneQuestionAndExpiresBacklog() throws {
    let lastSeen = reentryNow.addingTimeInterval(-5 * 24 * 60 * 60)
    let changes = try [
        ReentryMaterialChange(
            occurredAt: reentryNow.addingTimeInterval(-60),
            summary: "Season changed",
            relevance: 0.9,
            isUnresolved: true,
            clarificationQuestion: "Does the season still fit?",
            clarificationValue: 0.7
        ),
        ReentryMaterialChange(
            occurredAt: reentryNow.addingTimeInterval(-120),
            summary: "Travel changed",
            relevance: 0.8,
            isUnresolved: true,
            clarificationQuestion: "Are the travel dates still right?",
            clarificationValue: 0.95
        ),
        ReentryMaterialChange(
            occurredAt: reentryNow.addingTimeInterval(-180),
            summary: "Calendar changed",
            relevance: 0.7
        ),
        ReentryMaterialChange(
            occurredAt: reentryNow.addingTimeInterval(-240),
            summary: "Fourth change",
            relevance: 0.6
        ),
        ReentryMaterialChange(
            occurredAt: lastSeen.addingTimeInterval(-1),
            summary: "Before absence",
            relevance: 1
        ),
    ]
    let expired = try ReentryOpportunity(
        expiresAt: reentryNow.addingTimeInterval(-1)
    )
    let surface = try ReentryProjector().project(
        lastSeen: lastSeen,
        now: reentryNow,
        changes: changes,
        opportunities: [expired]
    )

    #expect(surface.summary.map(\.summary) == [
        "Season changed", "Travel changed", "Calendar changed",
    ])
    #expect(surface.oneQuestion == "Are the travel dates still right?")
    #expect(surface.expiredOpportunityIDs == [expired.id])
    #expect(surface.options == [.continue, .reviseSeason, .stayQuiet])
    #expect(surface.suppressBacklog)
    #expect(surface.noAbsencePenalty)
}

@Test
func reentryWithNoChangesStillOffersCleanRestart() throws {
    let surface = try ReentryProjector().project(
        lastSeen: reentryNow.addingTimeInterval(-4 * 24 * 60 * 60),
        now: reentryNow,
        changes: [],
        opportunities: []
    )
    #expect(surface.summary.isEmpty)
    #expect(surface.oneQuestion == nil)
    #expect(surface.reasons.contains(.noCurrentMaterialChange))
}
