import Foundation
@testable import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let draftFactoryDate = Date(timeIntervalSince1970: 1_786_752_000.125)

@Test
func workshopDraftFactorySeedsAreDeterministicAndOwnerEditable() throws {
    let first = try makeFactory(identifierStart: 1_000, provenanceStart: 1_000)
    let second = try makeFactory(identifierStart: 1_000, provenanceStart: 1_000)

    #expect(try first.initialCharter() == second.initialCharter())
    #expect(try first.initialLifeStage() == second.initialLifeStage())
    let charterVersionID = try draftFactoryIdentifier(900)
    #expect(
        try first.initialSeason(charterVersionID: charterVersionID)
            == second.initialSeason(charterVersionID: charterVersionID)
    )

    let charter = try decodedCharter(first.initialCharter())
    #expect(charter.metadata.createdBy == ActorRef(actorType: .user, actorID: "owner"))
    #expect(charter.interpretationNotes.contains("affirm, revise, or abandon"))
    #expect(charter.acceptedAt == draftFactoryDate)
}

@Test
func workshopDraftFactoryRevisionPreservesIdentityAndNamesPredecessor() throws {
    let factory = try makeFactory(identifierStart: 2_000, provenanceStart: 2_000)
    let charterVersionID = try draftFactoryIdentifier(902)
    let proposals = [
        try factory.initialCharter(),
        try factory.initialLifeStage(),
        try factory.initialSeason(charterVersionID: charterVersionID),
    ]
    var revisions: [LifeModelDraftProposal] = []
    for (offset, initial) in proposals.enumerated() {
        let accepted = try cachedVersion(
            from: initial,
            acceptanceSequence: offset + 1
        )
        let revision = try factory.revision(of: accepted)
        let originalMetadata = try decodedMetadata(initial)
        let revisedMetadata = try decodedMetadata(revision)
        revisions.append(revision)

        #expect(revision.kind == initial.kind)
        #expect(revision.logicalID == initial.logicalID)
        #expect(revision.versionID != initial.versionID)
        #expect(revision.versionNumber == initial.versionNumber + 1)
        #expect(revision.baseVersionID == initial.versionID)
        #expect(revisedMetadata.id == revision.versionID)
        #expect(revisedMetadata.revision == originalMetadata.revision + 1)
    }

    let initial = proposals[0]
    let revision = revisions[0]
    let originalCharter = try decodedCharter(initial)
    let revisedCharter = try decodedCharter(revision)
    let originalSeason = try decodedSeason(proposals[2])
    let revisedSeason = try decodedSeason(revisions[2])

    #expect(revisedCharter.charterID == originalCharter.charterID)
    #expect(revisedCharter.metadata.createdAt == originalCharter.metadata.createdAt)
    #expect(revisedCharter.metadata.lastRevisedAt == draftFactoryDate)
    #expect(revisedCharter.metadata.provenanceID != originalCharter.metadata.provenanceID)
    #expect(revisedCharter.supersedesVersionID == initial.versionID)
    #expect(revisedSeason.supersedesSeasonID == originalSeason.supersedesSeasonID)
}

@Test
func workshopDraftFactoryCreatesSuccessorOnlyAfterTerminalSeason() throws {
    let factory = try makeFactory(identifierStart: 3_000, provenanceStart: 3_000)
    let charterVersionID = try draftFactoryIdentifier(901)
    let active = try factory.initialSeason(charterVersionID: charterVersionID)
    let activeVersion = try cachedVersion(from: active, acceptanceSequence: 1)

    #expect(throws: LifeModelWorkshopDraftFactoryError.unsupportedSuccessorState(.active)) {
        try factory.successorSeason(after: activeVersion)
    }

    var terminalDocument = active.document
    terminalDocument["status"] = .string(SeasonStatus.complete.rawValue)
    let terminalVersion = try cachedVersion(
        from: active,
        document: terminalDocument,
        acceptanceSequence: 1
    )
    let successor = try factory.successorSeason(after: terminalVersion)
    let successorSeason = try decodedSeason(successor)

    #expect(successor.logicalID != active.logicalID)
    #expect(successor.versionNumber == 1)
    #expect(successor.baseVersionID == active.versionID)
    #expect(successorSeason.status == .calibration)
    #expect(successorSeason.charterRevisionID == charterVersionID)
    #expect(successorSeason.supersedesSeasonID == active.logicalID)
    #expect(successorSeason.outgoingSummary?.outgoingSeasonVersionID == active.versionID)
    #expect(successorSeason.outgoingSummary?.outgoingSeasonID == active.logicalID)
    #expect(successorSeason.outgoingSummary?.status == .complete)
    #expect(successorSeason.outgoingSummary?.plainLanguageSummary.contains("not a grade") == true)
    #expect(successorSeason.retrospective?.status == .draft)
    #expect(successorSeason.retrospective?.achievements.isEmpty == true)
    #expect(successorSeason.retrospective?.dataAndModelQualityNotes.count == 1)
}

@Test
func workshopServiceRejectsVersionIdentifiersUsedAsSeasonLineage() async throws {
    let fixture = try DraftFactoryServiceFixture()
    defer { fixture.remove() }
    let factory = try makeFactory(identifierStart: 3_500, provenanceStart: 3_500)
    let active = try factory.initialSeason(
        charterVersionID: try draftFactoryIdentifier(903)
    )
    var terminalDocument = active.document
    terminalDocument["status"] = .string(SeasonStatus.complete.rawValue)
    let terminal = try cachedVersion(
        from: active,
        document: terminalDocument,
        acceptanceSequence: 1
    )
    try fixture.store.cacheLifeModelVersion(terminal)
    let successor = try factory.successorSeason(after: terminal)
    var mismatchedSummaryDocument = successor.document
    guard case var .object(summaryObject) = mismatchedSummaryDocument["outgoing_summary"] else {
        throw LifeModelWorkshopError.invalidDraft("Missing transition-summary test fixture.")
    }
    summaryObject["outgoing_content_hash"] = .string(String(repeating: "b", count: 64))
    mismatchedSummaryDocument["outgoing_summary"] = .object(summaryObject)
    let mismatchedSummary = try LifeModelDraftProposal(
        kind: successor.kind,
        versionID: successor.versionID,
        logicalID: successor.logicalID,
        versionNumber: successor.versionNumber,
        baseVersionID: successor.baseVersionID,
        acceptanceMethod: successor.acceptanceMethod,
        document: mismatchedSummaryDocument
    )
    var malformedDocument = successor.document
    malformedDocument["supersedes_season_id"] = .string(terminal.versionID.description)
    let malformed = try LifeModelDraftProposal(
        kind: successor.kind,
        versionID: successor.versionID,
        logicalID: successor.logicalID,
        versionNumber: successor.versionNumber,
        baseVersionID: successor.baseVersionID,
        acceptanceMethod: successor.acceptanceMethod,
        document: malformedDocument
    )

    await #expect(throws: LifeModelWorkshopError.self) {
        try await fixture.service.createDraft(mismatchedSummary)
    }
    await #expect(throws: LifeModelWorkshopError.self) {
        try await fixture.service.createDraft(malformed)
    }
    let created = try await fixture.service.createDraft(successor)
    #expect(created.baseVersionID == terminal.versionID)
    #expect(try decodedSeason(successor).supersedesSeasonID == terminal.logicalID)
    #expect(try await fixture.service.draft(id: created.draftID).document == successor.document)
    var editor = try SeasonDraftEditor(draft: created)
    #expect(try editor.document() == successor.document)
    editor.retrospective?.achievements.append("Protected a foundation during transition")
    editor.retrospective?.status = .accepted
    let saved = try await fixture.service.saveDraft(
        draftID: created.draftID,
        expectedStateRevision: created.stateRevision,
        document: editor.document()
    )
    let savedSeason: Season = try decoded(saved.document)
    let proposedSeason = try decodedSeason(successor)
    #expect(savedSeason.outgoingSummary == proposedSeason.outgoingSummary)
    #expect(savedSeason.retrospective?.status == .accepted)
    #expect(savedSeason.retrospective?.achievements.count == 1)
}

@Test
func workshopDraftFactoryProposalsPassWorkshopValidation() async throws {
    let fixture = try DraftFactoryServiceFixture()
    defer { fixture.remove() }
    let factory = try makeFactory(identifierStart: 4_000, provenanceStart: 4_000)
    let charter = try factory.initialCharter()
    let lifeStage = try factory.initialLifeStage()
    let season = try factory.initialSeason(charterVersionID: charter.versionID)

    let charterDraft = try await fixture.service.createDraft(charter)
    let lifeStageDraft = try await fixture.service.createDraft(lifeStage)
    let seasonDraft = try await fixture.service.createDraft(season)

    #expect(charterDraft.kind == .charter)
    #expect(lifeStageDraft.kind == .lifeStage)
    #expect(seasonDraft.kind == .season)
    #expect(try await fixture.service.snapshot().drafts.count == 3)
}

private struct DraftFactoryServiceFixture {
    let directory: URL
    let store: SQLiteLedgerStore
    let service: LifeModelWorkshopService

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-draft-factory-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let deviceID = try draftFactoryIdentifier(990)
        store = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: directory.appendingPathComponent("ledger.sqlite3"),
                deviceID: deviceID,
                preMigrationBackupDirectory: directory,
                clock: { draftFactoryDate }
            )
        )
        let serviceIdentifiers = DraftFactoryIdentifiers(start: 9_000)
        service = try LifeModelWorkshopService(
            store: store,
            deviceID: deviceID,
            clock: { draftFactoryDate },
            identifier: serviceIdentifiers.next
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeFactory(
    identifierStart: Int,
    provenanceStart: Int
) throws -> LifeModelWorkshopDraftFactory {
    let identifiers = DraftFactoryIdentifiers(start: identifierStart)
    let provenanceIdentifiers = DraftFactoryProvenanceIdentifiers(start: provenanceStart)
    return try LifeModelWorkshopDraftFactory(
        ownerActorID: "owner",
        timeZoneID: "UTC",
        clock: { draftFactoryDate },
        identifier: identifiers.next,
        provenanceIdentifier: provenanceIdentifiers.next
    )
}

private func decodedCharter(
    _ proposal: LifeModelDraftProposal
) throws -> CharterVersion {
    try SyncJSONCoding.makeDecoder().decode(
        CharterVersion.self,
        from: SyncJSONCoding.makeEncoder().encode(proposal.document)
    )
}

private func decodedSeason(
    _ proposal: LifeModelDraftProposal
) throws -> Season {
    try SyncJSONCoding.makeDecoder().decode(
        Season.self,
        from: SyncJSONCoding.makeEncoder().encode(proposal.document)
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

private func decodedMetadata(
    _ proposal: LifeModelDraftProposal
) throws -> EntityMetadata {
    switch proposal.kind {
    case .charter:
        try decodedCharter(proposal).metadata
    case .lifeStage:
        try SyncJSONCoding.makeDecoder().decode(
            LifeStageVersion.self,
            from: SyncJSONCoding.makeEncoder().encode(proposal.document)
        ).metadata
    case .season:
        try decodedSeason(proposal).metadata
    }
}

private func cachedVersion(
    from proposal: LifeModelDraftProposal,
    document: [String: JSONValue]? = nil,
    acceptanceSequence: Int
) throws -> CachedLifeModelVersion {
    let acceptedValues = document ?? proposal.document
    let acceptedDocument = try SyncJSONCoding.makeEncoder().encode(acceptedValues)
    let status: String?
    if case let .string(value)? = acceptedValues["status"] {
        status = value
    } else {
        status = nil
    }
    return try CachedLifeModelVersion(
        kind: proposal.kind,
        versionID: proposal.versionID,
        logicalID: proposal.logicalID,
        versionNumber: proposal.versionNumber,
        acceptanceSequence: acceptanceSequence,
        supersedesVersionID: proposal.baseVersionID,
        status: status,
        acceptanceMethod: proposal.acceptanceMethod,
        acceptedAt: draftFactoryDate,
        contentHash: SHA256Digest.hexDigest(of: acceptedDocument),
        document: acceptedDocument,
        eventID: try draftFactoryIdentifier(995 + acceptanceSequence),
        ledgerSequence: Int64(acceptanceSequence),
        policyVersion: "test.v1",
        cachedAt: draftFactoryDate
    )
}

private func draftFactoryIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}

private final class DraftFactoryIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(start: Int) {
        value = start
    }

    func next() -> UUIDv7 {
        lock.withLock {
            value += 1
            return try! draftFactoryIdentifier(value)
        }
    }
}

private final class DraftFactoryProvenanceIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(start: Int) {
        value = start
    }

    func next() -> UUID {
        lock.withLock {
            value += 1
            let suffix = String(format: "%012x", value)
            return UUID(uuidString: "018f0000-0000-4000-8000-\(suffix)")!
        }
    }
}
