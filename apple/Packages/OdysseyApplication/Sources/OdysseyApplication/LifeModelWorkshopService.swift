import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public protocol LifeModelWorkshopStore: LedgerStore, LifeModelAcceptanceStore {
    func projectedEntity(
        entityType: String,
        entityID: UUIDv7
    ) throws -> ProjectedEntity?
    func projectedEntities(
        entityType: String,
        limit: Int
    ) throws -> [ProjectedEntity]
    func projectionHistory(
        entityType: String,
        entityID: UUIDv7,
        limit: Int
    ) throws -> [ProjectedEntity]
}

extension SQLiteLedgerStore: LifeModelWorkshopStore {}

private enum ValidatedLifeModelDocument {
    case charter(CharterVersion)
    case lifeStage(LifeStageVersion)
    case season(Season)
}

public actor LifeModelWorkshopService {
    public static let entityType = "life_model_draft"
    public static let aggregateType = "life_model_draft"

    private let store: any LifeModelWorkshopStore
    private let deviceID: UUIDv7
    private let ownerActorID: String
    private let clock: @Sendable () -> Date
    private let identifier: @Sendable () -> UUIDv7
    private let provenanceIdentifier: @Sendable () -> UUID

    public init(
        store: any LifeModelWorkshopStore,
        deviceID: UUIDv7,
        ownerActorID: String = "owner",
        clock: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> UUIDv7 = UUIDv7.init,
        provenanceIdentifier: @escaping @Sendable () -> UUID = UUID.init
    ) throws {
        guard (1 ... 100).contains(ownerActorID.count),
              ownerActorID == ownerActorID.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw LifeModelWorkshopError.invalidDraft(
                "The Workshop owner actor identifier is invalid."
            )
        }
        self.store = store
        self.deviceID = deviceID
        self.ownerActorID = ownerActorID
        self.clock = clock
        self.identifier = identifier
        self.provenanceIdentifier = provenanceIdentifier
    }

    @discardableResult
    public func createDraft(
        _ proposal: LifeModelDraftProposal
    ) async throws -> LifeModelDraftRecord {
        _ = try validate(
            kind: proposal.kind,
            versionID: proposal.versionID,
            logicalID: proposal.logicalID,
            versionNumber: proposal.versionNumber,
            baseVersionID: proposal.baseVersionID,
            acceptanceMethod: proposal.acceptanceMethod,
            document: proposal.document
        )
        let existing = try drafts(limit: 500)
        guard !existing.contains(where: {
            $0.kind == proposal.kind && ($0.phase == .editing || $0.phase == .reviewed)
        }) else {
            throw LifeModelWorkshopError.openDraftAlreadyExists(proposal.kind)
        }
        let now = try validClockInstant(context: "draft creation")
        let draft = try LifeModelDraftRecord(
            draftID: identifier(),
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
            createdAt: now,
            updatedAt: now
        )
        try await commit(
            draft,
            eventType: "life_model.draft.created.v1",
            mutationType: .create
        )
        return draft
    }

    @discardableResult
    public func saveDraft(
        draftID: UUIDv7,
        expectedStateRevision: Int,
        document: [String: JSONValue]
    ) async throws -> LifeModelDraftRecord {
        let current = try draft(id: draftID)
        try requireRevision(current, expected: expectedStateRevision)
        guard current.phase == .editing || current.phase == .reviewed else {
            throw LifeModelWorkshopError.invalidDraft(
                "Queued or abandoned drafts cannot be edited. Start a new revision instead."
            )
        }
        _ = try validate(
            kind: current.kind,
            versionID: current.versionID,
            logicalID: current.logicalID,
            versionNumber: current.versionNumber,
            baseVersionID: current.baseVersionID,
            acceptanceMethod: current.acceptanceMethod,
            document: document
        )
        let updatedAt = try validClockInstant(context: "draft edit")
        let updated = try LifeModelDraftRecord(
            draftID: current.draftID,
            kind: current.kind,
            versionID: current.versionID,
            logicalID: current.logicalID,
            versionNumber: current.versionNumber,
            baseVersionID: current.baseVersionID,
            acceptanceMethod: current.acceptanceMethod,
            document: document,
            contentRevision: current.contentRevision + 1,
            stateRevision: current.stateRevision + 1,
            phase: .editing,
            createdAt: current.createdAt,
            updatedAt: updatedAt
        )
        try await commit(
            updated,
            eventType: "life_model.draft.edited.v1",
            mutationType: .update
        )
        return updated
    }

    public func prepareReview(
        draftID: UUIDv7,
        expectedStateRevision: Int
    ) async throws -> LifeModelDraftReview {
        let current = try draft(id: draftID)
        try requireRevision(current, expected: expectedStateRevision)
        if current.phase == .reviewed || current.phase == .queued {
            return try makeReview(for: current)
        }
        guard current.phase == .editing else {
            throw LifeModelWorkshopError.invalidDraft(
                "An abandoned draft cannot enter review."
            )
        }
        let provisionalReview = try makeReview(for: current)
        if current.baseVersionID != nil, provisionalReview.changes.isEmpty {
            throw LifeModelWorkshopError.noSemanticChanges
        }
        let reviewedAt = try validClockInstant(context: "draft review")
        let reviewed = try LifeModelDraftRecord(
            draftID: current.draftID,
            kind: current.kind,
            versionID: current.versionID,
            logicalID: current.logicalID,
            versionNumber: current.versionNumber,
            baseVersionID: current.baseVersionID,
            acceptanceMethod: current.acceptanceMethod,
            document: current.document,
            contentRevision: current.contentRevision,
            stateRevision: current.stateRevision + 1,
            phase: .reviewed,
            reviewedDocumentSHA256: current.documentSHA256,
            reviewedAt: reviewedAt,
            createdAt: current.createdAt,
            updatedAt: reviewedAt
        )
        try await commit(
            reviewed,
            eventType: "life_model.draft.reviewed.v1",
            mutationType: .update
        )
        return try makeReview(for: reviewed)
    }

    public func review(draftID: UUIDv7) throws -> LifeModelDraftReview {
        try makeReview(for: draft(id: draftID))
    }

    @discardableResult
    public func queueReviewedDraft(
        draftID: UUIDv7,
        reviewDigest confirmedReviewDigest: String
    ) async throws -> StoredLifeModelAcceptance {
        let current = try draft(id: draftID)
        if let existing = try existingAcceptance(for: current) {
            try validate(existing: existing, matches: current)
            if current.phase != .queued {
                try await markQueued(current, eventID: existing.command.eventID)
            }
            return existing
        }
        guard current.phase == .reviewed,
              current.reviewedDocumentSHA256 == current.documentSHA256
        else {
            throw LifeModelWorkshopError.reviewRequired
        }
        let expectedDigest = makeReviewDigest(for: current)
        guard confirmedReviewDigest == expectedDigest else {
            throw LifeModelWorkshopError.reviewChanged
        }
        let command = try makeCommand(from: current)
        let queued = try store.enqueueLifeModelAcceptance(command)
        try await markQueued(current, eventID: command.eventID)
        return queued
    }

    @discardableResult
    public func abandonDraft(
        draftID: UUIDv7,
        expectedStateRevision: Int
    ) async throws -> LifeModelDraftRecord {
        let current = try draft(id: draftID)
        try requireRevision(current, expected: expectedStateRevision)
        guard current.phase == .editing || current.phase == .reviewed else {
            throw LifeModelWorkshopError.invalidDraft(
                "Only unqueued drafts can be abandoned."
            )
        }
        let updatedAt = try validClockInstant(context: "draft abandonment")
        let abandoned = try LifeModelDraftRecord(
            draftID: current.draftID,
            kind: current.kind,
            versionID: current.versionID,
            logicalID: current.logicalID,
            versionNumber: current.versionNumber,
            baseVersionID: current.baseVersionID,
            acceptanceMethod: current.acceptanceMethod,
            document: current.document,
            contentRevision: current.contentRevision,
            stateRevision: current.stateRevision + 1,
            phase: .abandoned,
            createdAt: current.createdAt,
            updatedAt: updatedAt
        )
        try await commit(
            abandoned,
            eventType: "life_model.draft.abandoned.v1",
            mutationType: .update
        )
        return abandoned
    }

    public func draft(id: UUIDv7) throws -> LifeModelDraftRecord {
        guard let projection = try store.projectedEntity(
            entityType: Self.entityType,
            entityID: id
        ) else {
            throw LifeModelWorkshopError.draftNotFound(id)
        }
        return try decode(projection)
    }

    public func drafts(limit: Int = 200) throws -> [LifeModelDraftRecord] {
        try store.projectedEntities(entityType: Self.entityType, limit: limit)
            .map(decode)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func draftHistory(
        draftID: UUIDv7,
        limit: Int = 200
    ) throws -> [LifeModelDraftRecord] {
        try store.projectionHistory(
            entityType: Self.entityType,
            entityID: draftID,
            limit: limit
        ).map(decode)
    }

    public func snapshot() throws -> LifeModelWorkshopSnapshot {
        let versions = try LifeModelKind.allCases.flatMap {
            try store.cachedLifeModelVersions(kind: $0, limit: 200)
        }.sorted {
            if $0.kind == $1.kind {
                return $0.acceptanceSequence > $1.acceptanceSequence
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return LifeModelWorkshopSnapshot(
            drafts: try drafts(),
            acceptanceCommands: try store.lifeModelAcceptances(kind: nil, limit: 1_000),
            acceptedVersions: versions,
            queueDiagnostics: try store.lifeModelQueueDiagnostics()
        )
    }

    private func commit(
        _ draft: LifeModelDraftRecord,
        eventType: String,
        mutationType: LedgerMutationType
    ) async throws {
        let payload = try SyncJSONCoding.makeEncoder().encode(draft)
        let provenanceID = provenanceIdentifier()
        _ = try await store.commit(
            LedgerCommit(
                entry: LedgerEntry(
                    eventID: identifier(),
                    eventType: eventType,
                    aggregateType: Self.aggregateType,
                    aggregateID: draft.draftID,
                    occurredAt: draft.updatedAt,
                    recordedAt: draft.updatedAt,
                    payload: payload,
                    provenanceID: provenanceID
                ),
                projection: ProjectionMutation(
                    entityType: Self.entityType,
                    entityID: draft.draftID,
                    revision: draft.stateRevision,
                    mutationType: mutationType,
                    document: payload
                )
            )
        )
    }

    private func markQueued(
        _ current: LifeModelDraftRecord,
        eventID: UUIDv7
    ) async throws {
        let updatedAt = try validClockInstant(context: "acceptance queueing")
        let queued = try LifeModelDraftRecord(
            draftID: current.draftID,
            kind: current.kind,
            versionID: current.versionID,
            logicalID: current.logicalID,
            versionNumber: current.versionNumber,
            baseVersionID: current.baseVersionID,
            acceptanceMethod: current.acceptanceMethod,
            document: current.document,
            contentRevision: current.contentRevision,
            stateRevision: current.stateRevision + 1,
            phase: .queued,
            reviewedDocumentSHA256: current.documentSHA256,
            reviewedAt: current.reviewedAt,
            queuedEventID: eventID,
            createdAt: current.createdAt,
            updatedAt: updatedAt
        )
        try await commit(
            queued,
            eventType: "life_model.draft.queued.v1",
            mutationType: .update
        )
    }

    private func decode(_ projection: ProjectedEntity) throws -> LifeModelDraftRecord {
        guard projection.entityType == Self.entityType else {
            throw LifeModelWorkshopError.invalidDraft(
                "A Workshop projection has the wrong entity type."
            )
        }
        let draft = try SyncJSONCoding.makeDecoder().decode(
            LifeModelDraftRecord.self,
            from: projection.document
        ).validated()
        guard draft.draftID == projection.entityID,
              draft.stateRevision == projection.revision
        else {
            throw LifeModelWorkshopError.invalidDraft(
                "A Workshop projection does not match its draft identity or revision."
            )
        }
        return draft
    }

    private func makeReview(
        for draft: LifeModelDraftRecord
    ) throws -> LifeModelDraftReview {
        guard draft.phase != .abandoned else {
            throw LifeModelWorkshopError.invalidDraft(
                "An abandoned draft does not have an active review."
            )
        }
        let before = try draft.baseVersionID.map {
            try acceptedDocument(kind: draft.kind, versionID: $0)
        }
        let changes = LifeModelSemanticDiffer.changes(
            from: before,
            to: draft.document
        )
        return LifeModelDraftReview(
            draft: draft,
            changes: changes,
            warnings: try reviewWarnings(for: draft),
            reviewDigest: makeReviewDigest(for: draft)
        )
    }

    private func acceptedDocument(
        kind: LifeModelKind,
        versionID: UUIDv7
    ) throws -> [String: JSONValue] {
        guard let version = try store.cachedLifeModelVersions(kind: kind, limit: 1_000)
            .first(where: { $0.versionID == versionID })
        else {
            throw LifeModelWorkshopError.acceptedVersionUnavailable(versionID)
        }
        return try SyncJSONCoding.makeDecoder().decode(
            [String: JSONValue].self,
            from: version.document
        )
    }

    private func reviewWarnings(
        for draft: LifeModelDraftRecord
    ) throws -> [String] {
        let document = try validate(
            kind: draft.kind,
            versionID: draft.versionID,
            logicalID: draft.logicalID,
            versionNumber: draft.versionNumber,
            baseVersionID: draft.baseVersionID,
            acceptanceMethod: draft.acceptanceMethod,
            document: draft.document
        )
        var warnings = [
            "Acceptance makes this version immutable and eligible for future decision context.",
        ]
        guard case let .season(season) = document else {
            return warnings
        }
        let primaryCount = season.portfolioItems.count { $0.role == .primary }
        let foundationCount = season.portfolioItems.count { $0.role == .foundation }
        let supportingCount = season.portfolioItems.count {
            $0.role == .maintenance || $0.role == .exploration
        }
        if primaryCount != 1 {
            warnings.append(
                "This season has \(primaryCount) primary directions; one is the normal attention budget."
            )
        }
        if supportingCount > 2 {
            warnings.append(
                "This season has more than two supporting directions, which may fragment attention."
            )
        }
        if foundationCount > 5 {
            warnings.append(
                "This season protects more than five foundations; confirm each minimum is realistic."
            )
        }
        return warnings
    }

    private func makeReviewDigest(for draft: LifeModelDraftRecord) -> String {
        let material = [
            draft.draftID.description,
            draft.versionID.description,
            String(draft.contentRevision),
            draft.documentSHA256,
            draft.baseVersionID?.description ?? "initial",
        ].joined(separator: "|")
        return SHA256Digest.hexDigest(of: Data(material.utf8))
    }

    private func existingAcceptance(
        for draft: LifeModelDraftRecord
    ) throws -> StoredLifeModelAcceptance? {
        try store.lifeModelAcceptances(kind: draft.kind, limit: 1_000)
            .first { $0.command.versionID == draft.versionID }
    }

    private func validate(
        existing: StoredLifeModelAcceptance,
        matches draft: LifeModelDraftRecord
    ) throws {
        let commandDocument = try SyncJSONCoding.makeDecoder().decode(
            [String: JSONValue].self,
            from: existing.command.document
        )
        guard existing.command.kind == draft.kind,
              existing.command.logicalID == draft.logicalID,
              existing.command.versionNumber == draft.versionNumber,
              existing.command.expectedCurrentVersionID == draft.baseVersionID,
              existing.command.acceptanceMethod == draft.acceptanceMethod,
              commandDocument == draft.document
        else {
            throw LifeModelWorkshopError.invalidDraft(
                "An existing acceptance command does not match the reviewed draft."
            )
        }
    }

    private func makeCommand(
        from draft: LifeModelDraftRecord
    ) throws -> LifeModelAcceptanceCommand {
        let validated = try validate(
            kind: draft.kind,
            versionID: draft.versionID,
            logicalID: draft.logicalID,
            versionNumber: draft.versionNumber,
            baseVersionID: draft.baseVersionID,
            acceptanceMethod: draft.acceptanceMethod,
            document: draft.document
        )
        let eventID = identifier()
        let acceptedAt: Date
        let requestBody: Data
        let document: Data
        switch validated {
        case let .charter(charter):
            acceptedAt = charter.acceptedAt
            requestBody = try SyncJSONCoding.makeEncoder().encode(
                CharterRevisionRequest(
                    eventID: eventID,
                    deviceID: deviceID,
                    expectedCurrentVersionID: draft.baseVersionID,
                    acceptanceMethod: draft.acceptanceMethod,
                    charter: charter
                )
            )
            document = try SyncJSONCoding.makeEncoder().encode(charter)
        case let .lifeStage(lifeStage):
            acceptedAt = try validClockInstant(context: "life-stage acceptance")
            guard acceptedAt >= lifeStage.metadata.lastRevisedAt else {
                throw LifeModelWorkshopError.invalidDraft(
                    "The local clock precedes the life-stage revision time."
                )
            }
            requestBody = try SyncJSONCoding.makeEncoder().encode(
                LifeStageRevisionRequest(
                    eventID: eventID,
                    deviceID: deviceID,
                    expectedCurrentVersionID: draft.baseVersionID,
                    acceptanceMethod: draft.acceptanceMethod,
                    acceptedAt: acceptedAt,
                    lifeStage: lifeStage
                )
            )
            document = try SyncJSONCoding.makeEncoder().encode(lifeStage)
        case let .season(season):
            acceptedAt = try validClockInstant(context: "season acceptance")
            guard acceptedAt >= season.metadata.lastRevisedAt else {
                throw LifeModelWorkshopError.invalidDraft(
                    "The local clock precedes the season revision time."
                )
            }
            requestBody = try SyncJSONCoding.makeEncoder().encode(
                SeasonRevisionRequest(
                    eventID: eventID,
                    deviceID: deviceID,
                    seasonID: draft.logicalID,
                    expectedCurrentVersionID: draft.baseVersionID,
                    acceptanceMethod: draft.acceptanceMethod,
                    acceptedAt: acceptedAt,
                    season: season
                )
            )
            document = try SyncJSONCoding.makeEncoder().encode(season)
        }
        return try LifeModelAcceptanceCommand(
            eventID: eventID,
            kind: draft.kind,
            versionID: draft.versionID,
            logicalID: draft.logicalID,
            versionNumber: draft.versionNumber,
            expectedCurrentVersionID: draft.baseVersionID,
            acceptanceMethod: draft.acceptanceMethod,
            acceptedAt: acceptedAt,
            requestBody: requestBody,
            document: document,
            createdAt: try validClockInstant(context: "acceptance queueing")
        )
    }

    private func validate(
        kind: LifeModelKind,
        versionID: UUIDv7,
        logicalID: UUIDv7,
        versionNumber: Int,
        baseVersionID: UUIDv7?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        document: [String: JSONValue]
    ) throws -> ValidatedLifeModelDocument {
        let data = try SyncJSONCoding.makeEncoder().encode(document)
        guard !document.isEmpty, data.count <= 768 * 1_024 else {
            throw LifeModelWorkshopError.invalidDraft(
                "The Workshop document is empty or exceeds the local safety limit."
            )
        }
        let decoder = SyncJSONCoding.makeDecoder()
        do {
            switch kind {
            case .charter:
                let decoded = try decoder.decode(CharterVersion.self, from: data)
                let charter = try validatedCharter(decoded)
                guard charter.metadata.id == versionID,
                      charter.charterID == logicalID,
                      charter.versionNumber == versionNumber,
                      charter.supersedesVersionID == baseVersionID
                else {
                    throw LifeModelWorkshopError.invalidDraft(
                        "The Charter identity or predecessor changed inside the draft."
                    )
                }
                try validateOwnerMetadata(charter.metadata)
                try requireCanonical(charter, matches: document)
                return .charter(charter)
            case .lifeStage:
                let decoded = try decoder.decode(LifeStageVersion.self, from: data)
                let lifeStage = try validatedLifeStage(decoded)
                guard lifeStage.metadata.id == versionID,
                      lifeStage.stageID == logicalID,
                      lifeStage.metadata.revision == versionNumber
                else {
                    throw LifeModelWorkshopError.invalidDraft(
                        "The life-stage identity changed inside the draft."
                    )
                }
                try validateOwnerMetadata(lifeStage.metadata)
                try requireCanonical(lifeStage, matches: document)
                return .lifeStage(lifeStage)
            case .season:
                let decoded = try decoder.decode(Season.self, from: data)
                let season = try validatedSeason(decoded)
                let expectedMethod: LifeModelAcceptanceMethod = switch season.createdFrom {
                case .user: .ownerAuthored
                case .assisted: .ownerReviewedAssisted
                case .imported: .ownerApprovedImport
                }
                guard season.metadata.id == versionID,
                      season.metadata.revision == versionNumber,
                      season.supersedesSeasonID == baseVersionID,
                      acceptanceMethod == expectedMethod
                else {
                    throw LifeModelWorkshopError.invalidDraft(
                        "The season identity, predecessor, or creation source changed inside the draft."
                    )
                }
                try validateOwnerMetadata(season.metadata)
                try requireCanonical(season, matches: document)
                return .season(season)
            }
        } catch let error as LifeModelWorkshopError {
            throw error
        } catch {
            throw LifeModelWorkshopError.invalidDraft(
                "The Workshop document does not satisfy the typed life-model contract."
            )
        }
    }

    private func validatedCharter(_ value: CharterVersion) throws -> CharterVersion {
        try CharterVersion(
            metadata: validatedMetadata(value.metadata),
            charterID: value.charterID,
            versionNumber: value.versionNumber,
            effectiveInterval: validatedInterval(value.effectiveInterval),
            values: try value.values.map {
                try CharterValue(
                    id: $0.id,
                    title: $0.title,
                    description: $0.description,
                    positiveExpression: $0.positiveExpression,
                    antiValueOrFailureMode: $0.antiValueOrFailureMode
                )
            },
            responsibilities: value.responsibilities,
            desiredWaysOfBeing: value.desiredWaysOfBeing,
            nonNegotiableBoundaries: value.nonNegotiableBoundaries,
            antiOptimizationStatements: value.antiOptimizationStatements,
            interpretationNotes: value.interpretationNotes,
            supersedesVersionID: value.supersedesVersionID,
            acceptedAt: value.acceptedAt
        )
    }

    private func requireCanonical<Value: Encodable>(
        _ value: Value,
        matches document: [String: JSONValue]
    ) throws {
        let canonical = try SyncJSONCoding.makeDecoder().decode(
            [String: JSONValue].self,
            from: SyncJSONCoding.makeEncoder().encode(value)
        )
        guard canonical == document else {
            throw LifeModelWorkshopError.invalidDraft(
                "The Workshop document contains unsupported or non-canonical fields."
            )
        }
    }

    private func validatedLifeStage(_ value: LifeStageVersion) throws -> LifeStageVersion {
        try LifeStageVersion(
            metadata: validatedMetadata(value.metadata),
            stageID: value.stageID,
            effectiveInterval: validatedInterval(value.effectiveInterval),
            title: value.title,
            careerContext: value.careerContext,
            partnershipFamilyContext: value.partnershipFamilyContext,
            healthCapabilityContext: value.healthCapabilityContext,
            geographyContext: value.geographyContext,
            financialContext: value.financialContext,
            careResponsibilities: value.careResponsibilities,
            identityTransitions: value.identityTransitions,
            horizons: value.horizons,
            uncertainties: value.uncertainties
        )
    }

    private func validatedSeason(_ value: Season) throws -> Season {
        for item in value.portfolioItems {
            if let reviewDate = item.reviewDate {
                try validate(reviewDate)
            }
        }
        return try Season(
            metadata: validatedMetadata(value.metadata),
            charterRevisionID: value.charterRevisionID,
            title: value.title,
            effectiveInterval: validatedInterval(value.effectiveInterval),
            status: value.status,
            createdFrom: value.createdFrom,
            rationale: value.rationale,
            triggeringContext: value.triggeringContext,
            portfolioItems: value.portfolioItems,
            explicitNonGoals: value.explicitNonGoals,
            constraints: value.constraints,
            opportunityBudgets: value.opportunityBudgets,
            progressSignals: value.progressSignals,
            failureGuardrails: value.failureGuardrails,
            protectedExperiences: value.protectedExperiences,
            knownTradeoffs: value.knownTradeoffs,
            goodWeekDescription: value.goodWeekDescription,
            transitionTriggers: value.transitionTriggers,
            reviewCadence: value.reviewCadence,
            transitionNotes: value.transitionNotes,
            supersedesSeasonID: value.supersedesSeasonID,
            primaryOverrideExplanation: value.primaryOverrideExplanation
        )
    }

    private func validatedMetadata(_ value: EntityMetadata) throws -> EntityMetadata {
        guard value.createdAt.timeIntervalSinceReferenceDate.isFinite,
              value.lastRevisedAt.timeIntervalSinceReferenceDate.isFinite,
              value.tombstonedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              value.schemaVersion >= 1,
              value.revision >= 1,
              value.sensitivity != .operationalSecret
        else {
            throw LifeModelWorkshopError.invalidDraft(
                "Life-model metadata contains an invalid time, revision, or sensitivity."
            )
        }
        return try EntityMetadata(
            id: value.id,
            schemaVersion: value.schemaVersion,
            createdAt: value.createdAt,
            createdBy: value.createdBy,
            lastRevisedAt: value.lastRevisedAt,
            revision: value.revision,
            tombstonedAt: value.tombstonedAt,
            sensitivity: value.sensitivity,
            provenanceID: value.provenanceID
        )
    }

    private func validateOwnerMetadata(_ metadata: EntityMetadata) throws {
        guard metadata.createdBy.actorType == .user,
              metadata.createdBy.actorID == ownerActorID
        else {
            throw LifeModelWorkshopError.invalidDraft(
                "Only the configured owner can author or review a normative life-model draft."
            )
        }
    }

    private func validatedInterval(_ value: TemporalInterval) throws -> TemporalInterval {
        if case let .instant(date)? = value.start,
           !date.timeIntervalSinceReferenceDate.isFinite
        {
            throw LifeModelWorkshopError.invalidDraft(
                "The life-model interval has a non-finite start."
            )
        }
        if case let .instant(date)? = value.end,
           !date.timeIntervalSinceReferenceDate.isFinite
        {
            throw LifeModelWorkshopError.invalidDraft(
                "The life-model interval has a non-finite end."
            )
        }
        if case let .localDate(date)? = value.start {
            try validate(date)
        }
        if case let .localDate(date)? = value.end {
            try validate(date)
        }
        return try TemporalInterval(
            start: value.start,
            end: value.end,
            timeZoneID: value.timeZoneID,
            startPrecision: value.startPrecision,
            endPrecision: value.endPrecision,
            allDaySemantics: value.allDaySemantics
        )
    }

    private func validate(_ date: LocalDate) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = date.year
        components.month = date.month
        components.day = date.day
        guard let resolved = components.date,
              calendar.dateComponents(
                  [.year, .month, .day],
                  from: resolved
              ) == DateComponents(year: date.year, month: date.month, day: date.day)
        else {
            throw LifeModelWorkshopError.invalidDraft(
                "The life-model document contains an invalid local date."
            )
        }
    }

    private func requireRevision(
        _ draft: LifeModelDraftRecord,
        expected: Int
    ) throws {
        guard draft.stateRevision == expected else {
            throw LifeModelWorkshopError.staleDraft(
                expectedRevision: expected,
                actualRevision: draft.stateRevision
            )
        }
    }

    private func validClockInstant(context: String) throws -> Date {
        let value = clock()
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw LifeModelWorkshopError.invalidDraft(
                "The local clock returned a non-finite \(context) time."
            )
        }
        return value
    }
}
