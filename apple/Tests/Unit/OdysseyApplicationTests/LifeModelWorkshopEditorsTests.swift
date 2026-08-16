import Foundation
import OdysseyApplication
import OdysseyDomain
import OdysseySync
import Testing

private let workshopEditorDate = Date(timeIntervalSince1970: 1_786_752_000.125)

@Test
func workshopEditorsRoundTripTypedDraftsWithoutIdentityDrift() throws {
    let factory = try LifeModelWorkshopDraftFactory(
        ownerActorID: "owner",
        timeZoneID: "UTC",
        clock: { workshopEditorDate }
    )
    let charterProposal = try factory.initialCharter()
    let lifeStageProposal = try factory.initialLifeStage()
    let seasonProposal = try factory.initialSeason(
        charterVersionID: charterProposal.versionID
    )

    let charter = try CharterDraftEditor(draft: editorRecord(charterProposal))
    let lifeStage = try LifeStageDraftEditor(draft: editorRecord(lifeStageProposal))
    let season = try SeasonDraftEditor(draft: editorRecord(seasonProposal))

    #expect(try charter.document() == charterProposal.document)
    #expect(try lifeStage.document() == lifeStageProposal.document)
    #expect(try season.document() == seasonProposal.document)
}

@Test
func workshopEditorsExposePlainLanguageMutableFields() throws {
    let factory = try LifeModelWorkshopDraftFactory(
        ownerActorID: "owner",
        timeZoneID: "UTC",
        clock: { workshopEditorDate }
    )
    let charterProposal = try factory.initialCharter()
    var charter = try CharterDraftEditor(draft: editorRecord(charterProposal))
    charter.values[0].title = "Integrity under pressure"
    charter.responsibilities.append("Name difficult trade-offs honestly")
    let changedCharter: CharterVersion = try decoded(charter.document())

    #expect(changedCharter.metadata.id == charterProposal.versionID)
    #expect(changedCharter.values[0].title == "Integrity under pressure")
    #expect(changedCharter.responsibilities.last == "Name difficult trade-offs honestly")

    let lifeStageProposal = try factory.initialLifeStage()
    var lifeStage = try LifeStageDraftEditor(draft: editorRecord(lifeStageProposal))
    lifeStage.geographyContext = "Evaluating a move without presuming it is required."
    lifeStage.uncertainties.append("Whether a move would improve daily life")
    let changedLifeStage: LifeStageVersion = try decoded(lifeStage.document())

    #expect(changedLifeStage.stageID == lifeStageProposal.logicalID)
    #expect(changedLifeStage.geographyContext.contains("without presuming"))
    #expect(changedLifeStage.uncertainties.count == lifeStage.uncertainties.count)

    let seasonProposal = try factory.initialSeason(
        charterVersionID: charterProposal.versionID
    )
    var season = try SeasonDraftEditor(draft: editorRecord(seasonProposal))
    season.goodWeekDescription = "Progress, connection, recovery, and open time."
    season.portfolioItems[0].sacrificeLimit = "Do not trade away sleep or integrity."
    season.explicitNonGoals.append("Do not turn every evening into scheduled work")
    let changedSeason: Season = try decoded(season.document())

    #expect(changedSeason.metadata.id == seasonProposal.versionID)
    #expect(changedSeason.goodWeekDescription == season.goodWeekDescription)
    #expect(changedSeason.portfolioItems[0].sacrificeLimit?.contains("sleep") == true)
    #expect(changedSeason.explicitNonGoals.count == season.explicitNonGoals.count)
}

@Test
func workshopSeasonEditorPreventsUnsupportedStatusJumps() throws {
    let factory = try LifeModelWorkshopDraftFactory(
        ownerActorID: "owner",
        timeZoneID: "UTC",
        clock: { workshopEditorDate }
    )
    let charter = try factory.initialCharter()
    let season = try factory.initialSeason(charterVersionID: charter.versionID)
    var editor = try SeasonDraftEditor(draft: editorRecord(season))

    #expect(editor.allowedStatuses == [.draft, .calibration, .active, .abandoned])
    editor.status = .complete
    #expect(throws: LifeModelWorkshopEditorError.invalidDocument(.season)) {
        try editor.document()
    }
}

@Test
func workshopEditorsRejectTheWrongTypedSurface() throws {
    let factory = try LifeModelWorkshopDraftFactory(
        ownerActorID: "owner",
        timeZoneID: "UTC",
        clock: { workshopEditorDate }
    )
    let lifeStage = try editorRecord(factory.initialLifeStage())

    #expect(throws: LifeModelWorkshopEditorError.incorrectKind(
        expected: .charter,
        actual: .lifeStage
    )) {
        try CharterDraftEditor(draft: lifeStage)
    }
}

private func editorRecord(
    _ proposal: LifeModelDraftProposal
) throws -> LifeModelDraftRecord {
    try LifeModelDraftRecord(
        draftID: UUIDv7(),
        kind: proposal.kind,
        versionID: proposal.versionID,
        logicalID: proposal.logicalID,
        versionNumber: proposal.versionNumber,
        baseVersionID: proposal.baseVersionID,
        acceptanceMethod: proposal.acceptanceMethod,
        document: proposal.document,
        contentRevision: 1,
        stateRevision: 1,
        phase: .editing,
        createdAt: workshopEditorDate,
        updatedAt: workshopEditorDate
    )
}

private func decoded<Value: Decodable>(
    _ document: [String: JSONValue]
) throws -> Value {
    try SyncJSONCoding.makeDecoder().decode(
        Value.self,
        from: SyncJSONCoding.makeEncoder().encode(document)
    )
}
