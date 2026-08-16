import Foundation
@testable import OdysseyApplication
import OdysseyDomain
import Testing

private let seasonMapDate = Date(timeIntervalSince1970: 1_786_752_000)

@Test
func seasonMapProjectionPreservesPolicyWithoutInventingScoresOrTasks() throws {
    let primaryID = try seasonMapIdentifier(10)
    let foundationID = try seasonMapIdentifier(11)
    let dormantID = try seasonMapIdentifier(12)
    let season = try mapSeason(
        portfolioItems: [
            SeasonPortfolioItem(
                directionID: primaryID,
                role: .primary,
                allocationBand: .dominant,
                minimumViableCommitment: "Prepare deliberately for the next role.",
                sacrificeLimit: "Do not trade away sleep or integrity.",
                successSignals: ["Role fit becomes clearer"]
            ),
            SeasonPortfolioItem(
                directionID: foundationID,
                role: .foundation,
                allocationBand: .moderate,
                minimumViableCommitment: "Protect recovery and close relationships.",
                successSignals: ["Energy remains compatible with the season"]
            ),
            SeasonPortfolioItem(
                directionID: dormantID,
                role: .dormant,
                allocationBand: .minimal,
                minimumViableCommitment: "Leave the side project deliberately dormant."
            ),
        ]
    )

    let projection = SeasonMapProjector.project(season)

    #expect(projection.seasonVersionID == season.metadata.id)
    #expect(projection.paths.map(\.id) == [primaryID, foundationID, dormantID])
    #expect(projection.paths.map(\.emphasis) == [.foreground, .middleGround, .background])
    #expect(projection.paths[0].boundary == "Do not trade away sleep or integrity.")
    #expect(projection.protectedTerrain.contains("Protect recovery and close relationships."))
    #expect(projection.openHorizon.contains("One open evening each week."))
    #expect(projection.landmarks.map(\.title).contains("The role transition resolves."))
    #expect(projection.deliberatelyDormant.contains("Do not optimize every open hour."))
    #expect(projection.deliberatelyDormant.contains("Leave the side project deliberately dormant."))
    #expect(!projection.orientationStatement.lowercased().contains("score"))
}

@Test
func seasonMapProjectionNamesRepeatedRolesAndReviewLandmarksDeterministically() throws {
    let season = try mapSeason(
        portfolioItems: [
            SeasonPortfolioItem(
                directionID: try seasonMapIdentifier(20),
                role: .exploration,
                allocationBand: .low,
                successSignals: ["First bounded exploration"]
            ),
            SeasonPortfolioItem(
                directionID: try seasonMapIdentifier(21),
                role: .exploration,
                allocationBand: .moderate,
                successSignals: ["Second bounded exploration"],
                reviewDate: LocalDate(year: 2026, month: 9, day: 30)
            ),
        ]
    )

    let first = SeasonMapProjector.project(season)
    let second = SeasonMapProjector.project(season)

    #expect(first == second)
    #expect(first.paths.map(\.title) == ["Exploration path 1", "Exploration path 2"])
    #expect(first.landmarks.last?.detail == "2026-09-30")
}

private func mapSeason(portfolioItems: [SeasonPortfolioItem]) throws -> Season {
    let metadata = try EntityMetadata(
        id: seasonMapIdentifier(1),
        createdAt: seasonMapDate,
        createdBy: ActorRef(actorType: .user, actorID: "owner"),
        lastRevisedAt: seasonMapDate,
        revision: 1,
        sensitivity: .sensitive,
        provenanceID: UUID(uuidString: "018f0000-0000-4000-8000-000000000001")!
    )
    return try Season(
        metadata: metadata,
        charterRevisionID: seasonMapIdentifier(2),
        title: "Synthetic orientation season",
        effectiveInterval: TemporalInterval(
            start: .localDate(LocalDate(year: 2026, month: 8, day: 15)),
            timeZoneID: "UTC",
            startPrecision: .day,
            allDaySemantics: true
        ),
        status: .active,
        createdFrom: .user,
        rationale: "Keep one direction clear while protecting foundations and open time.",
        portfolioItems: portfolioItems,
        explicitNonGoals: ["Do not optimize every open hour."],
        constraints: ["Protect accepted commitments."],
        opportunityBudgets: ["One open evening each week."],
        protectedExperiences: ["Time with close people."],
        goodWeekDescription: "Focused progress with energy and open time left.",
        transitionTriggers: ["The role transition resolves."],
        reviewCadence: "Every two weeks"
    )
}

private func seasonMapIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
