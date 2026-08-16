import Foundation
@testable import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let workshopFixtureDate = Date(timeIntervalSince1970: 1_786_752_000.125)

@Test
func workshopDraftReviewAndAcceptanceRemainLocalDurableAndInspectable() async throws {
    let fixture = try WorkshopFixture()
    defer { fixture.remove() }
    let proposal = try fixture.charterProposal(
        index: 1,
        responsibilities: ["Protect important relationships"]
    )
    let created = try await fixture.service.createDraft(proposal)
    let editedDocument = try fixture.charterProposal(
        index: 1,
        responsibilities: [
            "Protect important relationships",
            "Act with integrity under pressure",
        ]
    ).document

    let edited = try await fixture.service.saveDraft(
        draftID: created.draftID,
        expectedStateRevision: created.stateRevision,
        document: editedDocument
    )
    let review = try await fixture.service.prepareReview(
        draftID: edited.draftID,
        expectedStateRevision: edited.stateRevision
    )

    #expect(review.draft.phase == .reviewed)
    #expect(review.changes.contains { $0.label == "Responsibilities" })
    #expect(review.changes.allSatisfy { !$0.path.hasPrefix("metadata") })
    #expect(review.warnings.count == 1)
    await #expect(throws: LifeModelWorkshopError.reviewChanged) {
        try await fixture.service.queueReviewedDraft(
            draftID: review.draft.draftID,
            reviewDigest: String(repeating: "0", count: 64)
        )
    }

    let queued = try await fixture.service.queueReviewedDraft(
        draftID: review.draft.draftID,
        reviewDigest: review.reviewDigest
    )

    #expect(queued.deliveryStatus == .pending)
    #expect(queued.command.versionID == proposal.versionID)
    let expectedDocument = try SyncJSONCoding.makeEncoder().encode(editedDocument)
    #expect(queued.command.document == expectedDocument)
    let request = try SyncJSONCoding.makeDecoder().decode(
        CharterRevisionRequest.self,
        from: queued.command.requestBody
    )
    #expect(request.eventID == queued.command.eventID)
    #expect(request.deviceID == fixture.deviceID)
    #expect(request.charter.metadata.id == proposal.versionID)
    #expect(request.charter.responsibilities.count == 2)
    let current = try await fixture.service.draft(id: created.draftID)
    #expect(current.phase == .queued)
    #expect(current.queuedEventID == queued.command.eventID)
    let history = try await fixture.service.draftHistory(draftID: created.draftID)
    #expect(history.map(\.phase) == [.queued, .reviewed, .editing, .editing])
    #expect(history.map(\.stateRevision) == [4, 3, 2, 1])
    let localSync = try await fixture.store.localSyncDiagnostics()
    #expect(localSync.operationsQueued == 0)
    let snapshot = try await fixture.service.snapshot()
    #expect(snapshot.drafts.count == 1)
    #expect(snapshot.acceptanceCommands.count == 1)
    #expect(snapshot.queueDiagnostics.queuedCount == 1)
}

@Test
func workshopUsesOptimisticDraftEditsAndPlainLanguageSemanticDiffs() async throws {
    let fixture = try WorkshopFixture()
    defer { fixture.remove() }
    let proposal = try fixture.lifeStageProposal(index: 10, title: "Current chapter")
    let draft = try await fixture.service.createDraft(proposal)
    let changed = try fixture.lifeStageProposal(
        index: 10,
        title: "Current chapter with a geographic transition"
    ).document

    await #expect(throws: LifeModelWorkshopError.staleDraft(
        expectedRevision: 0,
        actualRevision: 1
    )) {
        try await fixture.service.saveDraft(
            draftID: draft.draftID,
            expectedStateRevision: 0,
            document: changed
        )
    }
    let saved = try await fixture.service.saveDraft(
        draftID: draft.draftID,
        expectedStateRevision: 1,
        document: changed
    )
    let review = try await fixture.service.prepareReview(
        draftID: draft.draftID,
        expectedStateRevision: saved.stateRevision
    )

    let titleChange = try #require(review.changes.first { $0.label == "Title" })
    #expect(titleChange.kind == .added)
    #expect(titleChange.after == "Current chapter with a geographic transition")
    #expect(review.changes.allSatisfy { $0.path != "stage_id" })
    #expect(review.changes.allSatisfy { !$0.path.hasPrefix("metadata") })
}

@Test
func workshopSurfacesSeasonAttentionWarningsAndTerminalConflicts() async throws {
    let fixture = try WorkshopFixture()
    defer { fixture.remove() }
    let proposal = try fixture.seasonProposal(index: 20, primaryCount: 2)
    let draft = try await fixture.service.createDraft(proposal)
    let review = try await fixture.service.prepareReview(
        draftID: draft.draftID,
        expectedStateRevision: draft.stateRevision
    )

    #expect(review.warnings.contains { $0.contains("2 primary directions") })
    let queued = try await fixture.service.queueReviewedDraft(
        draftID: draft.draftID,
        reviewDigest: review.reviewDigest
    )
    let actualCurrent = try fixture.identifier(998)
    try fixture.store.recordLifeModelConflict(
        eventID: queued.command.eventID,
        errorCode: "LIFE_MODEL_CURRENT_VERSION_CONFLICT",
        message: "The accepted current version changed and requires owner review.",
        actualCurrentVersionID: actualCurrent,
        completedAt: workshopFixtureDate.addingTimeInterval(1)
    )

    let snapshot = try await fixture.service.snapshot()
    let conflict = try #require(snapshot.acceptanceCommands.first)
    #expect(conflict.deliveryStatus == .conflict)
    #expect(conflict.actualCurrentVersionID == actualCurrent)
    #expect(snapshot.queueDiagnostics.conflictCount == 1)
    #expect(snapshot.queueDiagnostics.queuedCount == 0)
}

private struct WorkshopFixture {
    let directory: URL
    let deviceID: UUIDv7
    let store: SQLiteLedgerStore
    let service: LifeModelWorkshopService

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-workshop-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        deviceID = try Self.identifier(900)
        store = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: directory.appendingPathComponent("ledger.sqlite3"),
                deviceID: deviceID,
                preMigrationBackupDirectory: directory,
                clock: { workshopFixtureDate }
            )
        )
        let identifiers = WorkshopIdentifiers()
        service = try LifeModelWorkshopService(
            store: store,
            deviceID: deviceID,
            clock: { workshopFixtureDate },
            identifier: identifiers.next
        )
    }

    func charterProposal(
        index: Int,
        responsibilities: [String]
    ) throws -> LifeModelDraftProposal {
        let versionID = try identifier(index * 100 + 1)
        let charterID = try identifier(index * 100 + 2)
        let metadata = try self.metadata(versionID: versionID, revision: 1)
        let charter = try CharterVersion(
            metadata: metadata,
            charterID: charterID,
            versionNumber: 1,
            effectiveInterval: interval(),
            values: [
                try CharterValue(
                    id: identifier(index * 100 + 3),
                    title: "Integrity",
                    description: "Choose actions that remain self-endorsed.",
                    positiveExpression: "Act consistently with stated principles.",
                    antiValueOrFailureMode: "Do not optimize for appearance over substance."
                ),
            ],
            responsibilities: responsibilities,
            desiredWaysOfBeing: ["Present", "Courageous"],
            nonNegotiableBoundaries: ["Do not sacrifice health for avoidable urgency"],
            antiOptimizationStatements: ["Never turn every experience into productivity"],
            interpretationNotes: "A reviewed synthetic Charter.",
            acceptedAt: workshopFixtureDate
        )
        return try LifeModelDraftProposal(
            kind: .charter,
            versionID: versionID,
            logicalID: charterID,
            versionNumber: 1,
            baseVersionID: nil,
            acceptanceMethod: .ownerAuthored,
            document: document(charter)
        )
    }

    func lifeStageProposal(
        index: Int,
        title: String
    ) throws -> LifeModelDraftProposal {
        let versionID = try identifier(index * 100 + 1)
        let stageID = try identifier(index * 100 + 2)
        let lifeStage = try LifeStageVersion(
            metadata: metadata(versionID: versionID, revision: 1),
            stageID: stageID,
            effectiveInterval: interval(),
            title: title,
            careerContext: "Building technical depth and evaluating the next role.",
            partnershipFamilyContext: "Protecting meaningful relationships without scoring them.",
            healthCapabilityContext: "Training sustainably.",
            geographyContext: "Current location may change.",
            financialContext: "Preserve optionality.",
            careResponsibilities: ["Maintain close family contact"],
            identityTransitions: ["Growing into broader technical leadership"],
            horizons: ["Potential role change"],
            uncertainties: ["Timing and location"]
        )
        return try LifeModelDraftProposal(
            kind: .lifeStage,
            versionID: versionID,
            logicalID: stageID,
            versionNumber: 1,
            baseVersionID: nil,
            acceptanceMethod: .ownerAuthored,
            document: document(lifeStage)
        )
    }

    func seasonProposal(
        index: Int,
        primaryCount: Int
    ) throws -> LifeModelDraftProposal {
        let versionID = try identifier(index * 100 + 1)
        let seasonID = try identifier(index * 100 + 2)
        var portfolio: [SeasonPortfolioItem] = []
        for offset in 0 ..< primaryCount {
            portfolio.append(
                SeasonPortfolioItem(
                    directionID: try identifier(index * 100 + 10 + offset),
                    role: .primary,
                    allocationBand: .high,
                    successSignals: ["Meaningful progress without sacrificing foundations"]
                )
            )
        }
        let season = try Season(
            metadata: metadata(versionID: versionID, revision: 1),
            charterRevisionID: try identifier(700),
            title: "Synthetic orientation season",
            effectiveInterval: interval(),
            status: .draft,
            createdFrom: .user,
            rationale: "Focus attention while preserving health, relationships, and experience.",
            triggeringContext: ["A meaningful transition is approaching"],
            portfolioItems: portfolio,
            explicitNonGoals: ["Do not optimize every free evening"],
            constraints: ["Protect sleep opportunity"],
            opportunityBudgets: ["Leave one open period each week"],
            progressSignals: ["Work feels clearer rather than merely busier"],
            failureGuardrails: ["Revisit if recovery deteriorates"],
            protectedExperiences: ["Time with close friends and family"],
            knownTradeoffs: ["Some lower-priority projects remain dormant"],
            goodWeekDescription: "Focused progress with energy left for people and experience.",
            transitionTriggers: ["The primary direction resolves or stops fitting"],
            reviewCadence: "Every two weeks"
        )
        return try LifeModelDraftProposal(
            kind: .season,
            versionID: versionID,
            logicalID: seasonID,
            versionNumber: 1,
            baseVersionID: nil,
            acceptanceMethod: .ownerAuthored,
            document: document(season)
        )
    }

    func identifier(_ value: Int) throws -> UUIDv7 {
        try Self.identifier(value)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func metadata(
        versionID: UUIDv7,
        revision: Int
    ) throws -> EntityMetadata {
        try EntityMetadata(
            id: versionID,
            createdAt: workshopFixtureDate,
            createdBy: ActorRef(actorType: .user, actorID: "owner"),
            lastRevisedAt: workshopFixtureDate,
            revision: revision,
            sensitivity: .sensitive,
            provenanceID: UUID(uuidString: "018f0000-0000-4000-8000-000000000001")!
        )
    }

    private func interval() throws -> TemporalInterval {
        try TemporalInterval(
            start: .localDate(LocalDate(year: 2026, month: 8, day: 15)),
            timeZoneID: "UTC",
            startPrecision: .day,
            allDaySemantics: true
        )
    }

    private func document<Value: Encodable>(
        _ value: Value
    ) throws -> [String: JSONValue] {
        try SyncJSONCoding.makeDecoder().decode(
            [String: JSONValue].self,
            from: SyncJSONCoding.makeEncoder().encode(value)
        )
    }

    private static func identifier(_ value: Int) throws -> UUIDv7 {
        let suffix = String(format: "%012x", value)
        return try UUIDv7(
            validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
        )
    }
}

private final class WorkshopIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 8_000

    func next() -> UUIDv7 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        let suffix = String(format: "%012x", value)
        return try! UUIDv7(
            validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
        )
    }
}
