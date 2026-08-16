import Foundation
import OdysseyDomain
import OdysseyIntelligence
import Testing

private let currentContextDate = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func deterministicCurrentContextSelectsEveryStateByPriority() {
    let cases: [(DeterministicContextInput, NowState)] = [
        (DeterministicContextInput(
            unresolvedDecisionCount: 0,
            preparationDeadlineCount: 0,
            materialHealthConstraintCount: 0,
            disruptionCount: 0,
            explicitlyOpen: false
        ), .clear),
        (DeterministicContextInput(
            unresolvedDecisionCount: 1,
            preparationDeadlineCount: 0,
            materialHealthConstraintCount: 0,
            disruptionCount: 0,
            explicitlyOpen: false
        ), .choice),
        (DeterministicContextInput(
            unresolvedDecisionCount: 1,
            preparationDeadlineCount: 1,
            materialHealthConstraintCount: 0,
            disruptionCount: 0,
            explicitlyOpen: false
        ), .preparation),
        (DeterministicContextInput(
            unresolvedDecisionCount: 1,
            preparationDeadlineCount: 1,
            materialHealthConstraintCount: 1,
            disruptionCount: 0,
            explicitlyOpen: false
        ), .recovery),
        (DeterministicContextInput(
            unresolvedDecisionCount: 0,
            preparationDeadlineCount: 0,
            materialHealthConstraintCount: 0,
            disruptionCount: 0,
            explicitlyOpen: true
        ), .open),
        (DeterministicContextInput(
            unresolvedDecisionCount: 1,
            preparationDeadlineCount: 1,
            materialHealthConstraintCount: 1,
            disruptionCount: 1,
            explicitlyOpen: true
        ), .disrupted),
    ]

    for (input, expected) in cases {
        #expect(DeterministicContextProjector().project(input) == expected)
    }
}

@Test
func nowContextCorrectionIsExplicitBoundedAndExpires() throws {
    let input = try NowContextInput(
        generatedAt: currentContextDate,
        localDay: LocalDate(year: 2026, month: 8, day: 15),
        timeZoneID: "America/New_York",
        signals: DeterministicContextInput(
            unresolvedDecisionCount: 0,
            preparationDeadlineCount: 0,
            materialHealthConstraintCount: 0,
            disruptionCount: 0,
            explicitlyOpen: true
        ),
        currentThread: "Protect recovery",
        sources: [
            try CurrentContextSourceSnapshot(
                source: .calendar,
                state: .fresh,
                observedAt: currentContextDate
            ),
        ]
    )
    let correction = try NowStateCorrection(
        state: .recovery,
        reason: .capacityChanged,
        createdAt: currentContextDate.addingTimeInterval(-60),
        expiresAt: currentContextDate.addingTimeInterval(3_600)
    )

    let corrected = NowContextProjector().project(input, correction: correction)
    #expect(corrected.inferredState == .open)
    #expect(corrected.state == .recovery)
    #expect(corrected.correction == correction)
    #expect(!corrected.isIntentionallySilent)

    let expiredInput = try NowContextInput(
        generatedAt: correction.expiresAt,
        localDay: input.localDay,
        timeZoneID: input.timeZoneID,
        signals: input.signals,
        currentThread: input.currentThread,
        sources: input.sources,
        hasEnoughContextForSilence: input.hasEnoughContextForSilence
    )
    let expired = NowContextProjector().project(expiredInput, correction: correction)
    #expect(expired.state == .open)
    #expect(expired.correction == nil)
}

@Test
func clearStateDistinguishesIntentionalSilenceFromMissingContext() throws {
    let signals = DeterministicContextInput(
        unresolvedDecisionCount: 0,
        preparationDeadlineCount: 0,
        materialHealthConstraintCount: 0,
        disruptionCount: 0,
        explicitlyOpen: false
    )
    let empty = NowContextProjector().project(try NowContextInput(
        generatedAt: currentContextDate,
        localDay: LocalDate(year: 2026, month: 8, day: 15),
        timeZoneID: "UTC",
        signals: signals
    ))
    let silent = NowContextProjector().project(try NowContextInput(
        generatedAt: currentContextDate,
        localDay: LocalDate(year: 2026, month: 8, day: 15),
        timeZoneID: "UTC",
        signals: signals,
        hasEnoughContextForSilence: true
    ))
    let quietCorrection = try NowStateCorrection(
        state: .clear,
        reason: .ownerRequestedQuiet,
        createdAt: currentContextDate.addingTimeInterval(-60),
        expiresAt: currentContextDate.addingTimeInterval(3_600)
    )
    let ownerQuiet = NowContextProjector().project(
        try NowContextInput(
            generatedAt: currentContextDate,
            localDay: LocalDate(year: 2026, month: 8, day: 15),
            timeZoneID: "UTC",
            signals: signals
        ),
        correction: quietCorrection
    )

    #expect(!empty.isIntentionallySilent)
    #expect(silent.isIntentionallySilent)
    #expect(ownerQuiet.isIntentionallySilent)
    #expect(ownerQuiet.summary == "You asked Odyssey to stay quiet for now.")
    #expect(empty.summary != silent.summary)
}

@Test
func nowContextRejectsDuplicateSourcesAndUnboundedCorrections() throws {
    let source = try CurrentContextSourceSnapshot(source: .calendar, state: .fresh)
    #expect(throws: CurrentContextError.invalidSources) {
        try NowContextInput(
            generatedAt: currentContextDate,
            localDay: LocalDate(year: 2026, month: 8, day: 15),
            timeZoneID: "UTC",
            signals: DeterministicContextInput(
                unresolvedDecisionCount: 0,
                preparationDeadlineCount: 0,
                materialHealthConstraintCount: 0,
                disruptionCount: 0,
                explicitlyOpen: false
            ),
            sources: [source, source]
        )
    }
    #expect(throws: CurrentContextError.invalidCorrection) {
        try NowStateCorrection(
            state: .choice,
            reason: .situationChanged,
            createdAt: currentContextDate,
            expiresAt: currentContextDate.addingTimeInterval(
                NowStateCorrection.maximumLifetime + 1
            )
        )
    }
}
