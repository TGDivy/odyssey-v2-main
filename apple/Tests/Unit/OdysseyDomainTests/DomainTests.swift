import Foundation
import OdysseyDomain
import Testing

@Test
func uuidV7RoundTrips() throws {
    let identifier = UUIDv7()
    let encoded = try JSONEncoder().encode(identifier)
    let decoded = try JSONDecoder().decode(UUIDv7.self, from: encoded)

    #expect(decoded == identifier)
    #expect(String(decoding: encoded, as: UTF8.self) == "\"\(identifier.description)\"")
    #expect(identifier.description.split(separator: "-")[2].first == "7")
}

@Test
func seasonRequiresPrimaryOverrideExplanation() throws {
    let now = Date()
    let metadata = try EntityMetadata(
        createdAt: now,
        createdBy: ActorRef(actorType: .user, actorID: "owner"),
        lastRevisedAt: now,
        revision: 1,
        sensitivity: .private,
        provenanceID: UUID()
    )
    let interval = try TemporalInterval(
        start: .instant(now),
        end: .instant(now.addingTimeInterval(86_400))
    )
    let items = (0 ..< 3).map { _ in
        SeasonPortfolioItem(
            directionID: UUIDv7(),
            role: .primary,
            allocationBand: .moderate
        )
    }

    #expect(throws: DomainValidationError.tooManyPrimaryDirections) {
        try Season(
            metadata: metadata,
            charterRevisionID: UUIDv7(),
            title: "Synthetic season",
            effectiveInterval: interval,
            status: .draft,
            createdFrom: .user,
            rationale: "Validate the portfolio guard.",
            portfolioItems: items,
            explicitNonGoals: ["Do not optimize every hour."],
            goodWeekDescription: "Important work and relationships both receive attention.",
            transitionTriggers: ["Review after the launch."],
            reviewCadence: "P2W"
        )
    }
}

@Test
func charterAndLifeStageContractsPreserveOwnerReviewedVersions() throws {
    let now = Date(timeIntervalSince1970: 1_786_752_000)
    let metadata = try EntityMetadata(
        createdAt: now,
        createdBy: ActorRef(actorType: .user, actorID: "owner"),
        lastRevisedAt: now,
        revision: 1,
        sensitivity: .private,
        provenanceID: UUIDv7().rawValue
    )
    let interval = try TemporalInterval(
        start: .instant(now),
        timeZoneID: "Europe/London",
        startPrecision: .exact
    )
    let value = try CharterValue(
        title: "Integrity",
        description: "Keep consequential choices self-endorsed.",
        positiveExpression: "Act honestly and preserve agency."
    )
    let charter = try CharterVersion(
        metadata: metadata,
        charterID: UUIDv7(),
        versionNumber: 1,
        effectiveInterval: interval,
        values: [value],
        responsibilities: ["Keep explicit commitments."],
        desiredWaysOfBeing: ["Present"],
        nonNegotiableBoundaries: ["No hidden external action."],
        antiOptimizationStatements: ["Never optimize away meaningful relationships."],
        acceptedAt: now
    )
    let lifeStage = try LifeStageVersion(
        metadata: metadata,
        stageID: UUIDv7(),
        effectiveInterval: interval,
        title: "Owner-described current context",
        uncertainties: ["Future location is unknown."]
    )

    #expect(charter.versionNumber == charter.metadata.revision)
    #expect(charter.values == [value])
    #expect(lifeStage.uncertainties == ["Future location is unknown."])
    #expect(LifeModelKind.allCases == [.charter, .lifeStage, .season])
}

@Test
func charterRejectsMissingOwnerBoundaries() throws {
    let now = Date(timeIntervalSince1970: 1_786_752_000)
    let metadata = try EntityMetadata(
        createdAt: now,
        createdBy: ActorRef(actorType: .user, actorID: "owner"),
        lastRevisedAt: now,
        revision: 1,
        sensitivity: .private,
        provenanceID: UUIDv7().rawValue
    )
    let interval = try TemporalInterval(start: .instant(now), timeZoneID: "UTC")
    let value = try CharterValue(
        title: "Agency",
        description: "Retain final authority.",
        positiveExpression: "Choose deliberately."
    )

    #expect(throws: DomainValidationError.invalidCharter) {
        try CharterVersion(
            metadata: metadata,
            charterID: UUIDv7(),
            versionNumber: 1,
            effectiveInterval: interval,
            values: [value],
            responsibilities: [],
            desiredWaysOfBeing: [],
            nonNegotiableBoundaries: [],
            antiOptimizationStatements: [],
            acceptedAt: now
        )
    }
}

@Test
func localDateIntervalsRejectReverseOrder() {
    #expect(throws: DomainValidationError.invalidTemporalInterval) {
        try TemporalInterval(
            start: .localDate(LocalDate(year: 2026, month: 8, day: 16)),
            end: .localDate(LocalDate(year: 2026, month: 8, day: 15)),
            timeZoneID: "Europe/London",
            startPrecision: .day,
            endPrecision: .day,
            allDaySemantics: true
        )
    }
}
