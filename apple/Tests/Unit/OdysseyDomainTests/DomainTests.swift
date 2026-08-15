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
            title: "Synthetic season",
            effectiveInterval: interval,
            status: .draft,
            rationale: "Validate the portfolio guard.",
            portfolioItems: items
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
