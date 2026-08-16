import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public enum LifeModelWorkshopDraftFactoryError: Error, Equatable, Sendable {
    case invalidOwner
    case invalidTimeZone
    case invalidClock
    case unsupportedSuccessorState(SeasonStatus)
    case invalidAcceptedDocument
}

extension LifeModelWorkshopDraftFactoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidOwner:
            "The Workshop owner identifier is invalid."
        case .invalidTimeZone:
            "The Workshop time zone is invalid."
        case .invalidClock:
            "The local clock cannot create a life-model draft."
        case .unsupportedSuccessorState:
            "Complete or abandon the current season before starting its successor."
        case .invalidAcceptedDocument:
            "The accepted version cannot be decoded into an editable life-model document."
        }
    }
}

public struct LifeModelWorkshopDraftFactory: Sendable {
    private let ownerActorID: String
    private let timeZoneID: String
    private let clock: @Sendable () -> Date
    private let identifier: @Sendable () -> UUIDv7
    private let provenanceIdentifier: @Sendable () -> UUID

    public init(
        ownerActorID: String = "owner",
        timeZoneID: String = TimeZone.current.identifier,
        clock: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> UUIDv7 = UUIDv7.init,
        provenanceIdentifier: @escaping @Sendable () -> UUID = UUID.init
    ) throws {
        guard (1 ... 100).contains(ownerActorID.count),
              ownerActorID == ownerActorID.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw LifeModelWorkshopDraftFactoryError.invalidOwner
        }
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw LifeModelWorkshopDraftFactoryError.invalidTimeZone
        }
        self.ownerActorID = ownerActorID
        self.timeZoneID = timeZoneID
        self.clock = clock
        self.identifier = identifier
        self.provenanceIdentifier = provenanceIdentifier
    }

    public func initialCharter() throws -> LifeModelDraftProposal {
        let now = try validNow()
        let versionID = identifier()
        let charterID = identifier()
        let charter = try CharterVersion(
            metadata: metadata(
                id: versionID,
                createdAt: now,
                revision: 1,
                revisedAt: now
            ),
            charterID: charterID,
            versionNumber: 1,
            effectiveInterval: interval(startingAt: now),
            values: [
                try CharterValue(
                    id: identifier(),
                    title: "Self-authored integrity",
                    description: "Choose a life that remains recognizably your own.",
                    positiveExpression: "Act consistently with chosen principles and honest trade-offs.",
                    antiValueOrFailureMode: "Do not optimize for appearance, status, or compliance alone."
                ),
                try CharterValue(
                    id: identifier(),
                    title: "Meaningful relationships",
                    description: "Treat close relationships as part of flourishing, not as a metric.",
                    positiveExpression: "Make room for care, intimacy, friendship, and shared experience.",
                    antiValueOrFailureMode: "Never rank people or turn affection into relationship ROI."
                ),
                try CharterValue(
                    id: identifier(),
                    title: "Vitality with experience",
                    description: "Build capability while still living, noticing, and enjoying life.",
                    positiveExpression: "Protect health, energy, play, adventure, and sustainable growth.",
                    antiValueOrFailureMode: "Do not turn health or self-improvement into perfectionism."
                ),
            ],
            responsibilities: [
                "Honor explicit commitments and care responsibilities.",
                "Protect future optionality without postponing all present experience.",
            ],
            desiredWaysOfBeing: [
                "Present with people who matter",
                "Courageous under uncertainty",
                "Curious without becoming ungrounded",
            ],
            nonNegotiableBoundaries: [
                "No hidden universal life score or people ranking",
                "No irreversible action without explicit authority",
                "No avoidable sacrifice of health or close relationships for urgency theater",
            ],
            antiOptimizationStatements: [
                "Odyssey must never optimize every hour into productivity.",
                "Odyssey must never infer that culturally common milestones are required.",
                "Odyssey must never make model output canonical without owner review.",
            ],
            interpretationNotes: "Editable seed based on the Odyssey commission; "
                + "affirm, revise, or abandon it before acceptance.",
            acceptedAt: now
        )
        return try proposal(
            kind: .charter,
            versionID: versionID,
            logicalID: charterID,
            versionNumber: 1,
            baseVersionID: nil,
            acceptanceMethod: .ownerAuthored,
            value: charter
        )
    }

    public func initialLifeStage() throws -> LifeModelDraftProposal {
        let now = try validNow()
        let versionID = identifier()
        let stageID = identifier()
        let lifeStage = try LifeStageVersion(
            metadata: metadata(
                id: versionID,
                createdAt: now,
                revision: 1,
                revisedAt: now
            ),
            stageID: stageID,
            effectiveInterval: interval(startingAt: now),
            title: "Current life stage",
            careerContext: "Building exceptional current-role performance while exploring a high-quality next role.",
            partnershipFamilyContext: "Creating meaningful romantic opportunity while "
                + "protecting close friendships and family ties.",
            healthCapabilityContext: "Developing durable energy and physical capability through sustainable training.",
            geographyContext: "Current geography is a constraint and an open question, not an identity prescription.",
            financialContext: "Protect enough stability and optionality to make deliberate changes.",
            careResponsibilities: ["Keep explicit responsibilities visible and renegotiate them honestly"],
            identityTransitions: ["Growing into broader technical and personal responsibility"],
            horizons: ["Potential role transition", "Evolving partnership and location context"],
            uncertainties: ["Timing, geography, and which opportunities will prove genuinely fitting"]
        )
        return try proposal(
            kind: .lifeStage,
            versionID: versionID,
            logicalID: stageID,
            versionNumber: 1,
            baseVersionID: nil,
            acceptanceMethod: .ownerAuthored,
            value: lifeStage
        )
    }

    public func initialSeason(
        charterVersionID: UUIDv7
    ) throws -> LifeModelDraftProposal {
        let now = try validNow()
        let versionID = identifier()
        let seasonID = identifier()
        let season = try Season(
            metadata: metadata(
                id: versionID,
                createdAt: now,
                revision: 1,
                revisedAt: now
            ),
            charterRevisionID: charterVersionID,
            title: "Focused transition with protected foundations",
            effectiveInterval: interval(startingAt: now),
            status: .active,
            createdFrom: .user,
            rationale: "Concentrate attention on a high-quality career transition while "
                + "creating real relational opportunity and preserving vitality, friendship, "
                + "family, joy, and adventure.",
            triggeringContext: [
                "A meaningful role transition is plausible",
                "Training and relationship foundations need explicit protection",
            ],
            portfolioItems: [
                SeasonPortfolioItem(
                    directionID: identifier(),
                    role: .primary,
                    allocationBand: .dominant,
                    minimumViableCommitment: "Sustain excellent current-role work and "
                        + "deliberate interview preparation.",
                    sacrificeLimit: "Do not trade away sleep, integrity, or every open evening.",
                    successSignals: ["Clearer role fit and stronger technical readiness"]
                ),
                SeasonPortfolioItem(
                    directionID: identifier(),
                    role: .exploration,
                    allocationBand: .moderate,
                    minimumViableCommitment: "Create recurring space for meaningful romantic and social opportunity.",
                    sacrificeLimit: "Do not turn people or dates into throughput targets.",
                    successSignals: ["More genuine connection and less performative optimization"]
                ),
                SeasonPortfolioItem(
                    directionID: identifier(),
                    role: .foundation,
                    allocationBand: .moderate,
                    minimumViableCommitment: "Protect sustainable training, recovery, "
                        + "friendship, family, and non-instrumental experience.",
                    sacrificeLimit: "Do not let any single target consume health or important relationships.",
                    successSignals: ["Energy remains compatible with the life being asked of it"]
                ),
            ],
            explicitNonGoals: [
                "Do not maximize application count, date count, or training volume",
                "Do not fill every open period with optimization work",
            ],
            constraints: [
                "Preserve sufficient sleep opportunity and recovery",
                "Honor consequential work and relationship commitments",
            ],
            opportunityBudgets: [
                "Keep at least one meaningful open period each week",
                "Allow spontaneous social, cultural, or travel opportunities when foundations hold",
            ],
            progressSignals: [
                "Career preparation becomes more specific and less anxious",
                "Relational life feels more alive without becoming transactional",
                "Training remains sustainable and capability improves",
            ],
            failureGuardrails: [
                "Revisit if recovery, mood, or close relationships deteriorate",
                "Revisit if the primary direction no longer appears self-endorsed",
            ],
            protectedExperiences: [
                "Time with close friends and family",
                "Joy, beauty, adventure, and unstructured experience",
            ],
            knownTradeoffs: [
                "Some lower-priority projects remain dormant",
                "Progress may be slower in exchange for sustainability and openness",
            ],
            goodWeekDescription: "Focused preparation and excellent present work, "
                + "sustainable training, real human connection, and enough unclaimed time "
                + "to feel alive rather than managed.",
            transitionTriggers: [
                "A role transition resolves or materially changes",
                "The portfolio repeatedly fails to fit real capacity or priorities",
                "A major relationship, health, geography, or care transition changes the decision policy",
            ],
            reviewCadence: "Every two weeks during calibration, then monthly"
        )
        return try proposal(
            kind: .season,
            versionID: versionID,
            logicalID: seasonID,
            versionNumber: 1,
            baseVersionID: nil,
            acceptanceMethod: .ownerAuthored,
            value: season
        )
    }

    public func revision(
        of accepted: CachedLifeModelVersion
    ) throws -> LifeModelDraftProposal {
        let now = try validNow()
        let versionID = identifier()
        let data = accepted.document
        do {
            switch accepted.kind {
            case .charter:
                let current = try SyncJSONCoding.makeDecoder().decode(
                    CharterVersion.self,
                    from: data
                )
                let next = try CharterVersion(
                    metadata: revisedMetadata(current.metadata, id: versionID, at: now),
                    charterID: current.charterID,
                    versionNumber: accepted.versionNumber + 1,
                    effectiveInterval: current.effectiveInterval,
                    values: current.values,
                    responsibilities: current.responsibilities,
                    desiredWaysOfBeing: current.desiredWaysOfBeing,
                    nonNegotiableBoundaries: current.nonNegotiableBoundaries,
                    antiOptimizationStatements: current.antiOptimizationStatements,
                    interpretationNotes: current.interpretationNotes,
                    supersedesVersionID: accepted.versionID,
                    acceptedAt: now
                )
                return try proposal(
                    kind: .charter,
                    versionID: versionID,
                    logicalID: accepted.logicalID,
                    versionNumber: accepted.versionNumber + 1,
                    baseVersionID: accepted.versionID,
                    acceptanceMethod: .ownerAuthored,
                    value: next
                )
            case .lifeStage:
                let current = try SyncJSONCoding.makeDecoder().decode(
                    LifeStageVersion.self,
                    from: data
                )
                let next = try LifeStageVersion(
                    metadata: revisedMetadata(current.metadata, id: versionID, at: now),
                    stageID: current.stageID,
                    effectiveInterval: current.effectiveInterval,
                    title: current.title,
                    careerContext: current.careerContext,
                    partnershipFamilyContext: current.partnershipFamilyContext,
                    healthCapabilityContext: current.healthCapabilityContext,
                    geographyContext: current.geographyContext,
                    financialContext: current.financialContext,
                    careResponsibilities: current.careResponsibilities,
                    identityTransitions: current.identityTransitions,
                    horizons: current.horizons,
                    uncertainties: current.uncertainties
                )
                return try proposal(
                    kind: .lifeStage,
                    versionID: versionID,
                    logicalID: accepted.logicalID,
                    versionNumber: accepted.versionNumber + 1,
                    baseVersionID: accepted.versionID,
                    acceptanceMethod: .ownerAuthored,
                    value: next
                )
            case .season:
                let current = try SyncJSONCoding.makeDecoder().decode(
                    Season.self,
                    from: data
                )
                let next = try Season(
                    metadata: revisedMetadata(current.metadata, id: versionID, at: now),
                    charterRevisionID: current.charterRevisionID,
                    title: current.title,
                    effectiveInterval: current.effectiveInterval,
                    status: current.status,
                    createdFrom: .user,
                    rationale: current.rationale,
                    triggeringContext: current.triggeringContext,
                    portfolioItems: current.portfolioItems,
                    explicitNonGoals: current.explicitNonGoals,
                    constraints: current.constraints,
                    opportunityBudgets: current.opportunityBudgets,
                    progressSignals: current.progressSignals,
                    failureGuardrails: current.failureGuardrails,
                    protectedExperiences: current.protectedExperiences,
                    knownTradeoffs: current.knownTradeoffs,
                    goodWeekDescription: current.goodWeekDescription,
                    transitionTriggers: current.transitionTriggers,
                    reviewCadence: current.reviewCadence,
                    transitionNotes: current.transitionNotes,
                    supersedesSeasonID: current.supersedesSeasonID,
                    outgoingSummary: current.outgoingSummary,
                    retrospective: current.retrospective,
                    primaryOverrideExplanation: current.primaryOverrideExplanation
                )
                return try proposal(
                    kind: .season,
                    versionID: versionID,
                    logicalID: accepted.logicalID,
                    versionNumber: accepted.versionNumber + 1,
                    baseVersionID: accepted.versionID,
                    acceptanceMethod: .ownerAuthored,
                    value: next
                )
            }
        } catch let error as LifeModelWorkshopDraftFactoryError {
            throw error
        } catch {
            throw LifeModelWorkshopDraftFactoryError.invalidAcceptedDocument
        }
    }

    public func successorSeason(
        after accepted: CachedLifeModelVersion
    ) throws -> LifeModelDraftProposal {
        guard accepted.kind == .season else {
            throw LifeModelWorkshopDraftFactoryError.invalidAcceptedDocument
        }
        let current: Season
        do {
            current = try SyncJSONCoding.makeDecoder().decode(
                Season.self,
                from: accepted.document
            )
        } catch {
            throw LifeModelWorkshopDraftFactoryError.invalidAcceptedDocument
        }
        guard current.status == .complete || current.status == .abandoned else {
            throw LifeModelWorkshopDraftFactoryError.unsupportedSuccessorState(current.status)
        }
        let now = try validNow()
        let versionID = identifier()
        let seasonID = identifier()
        let plainLanguageSummary = Self.outgoingSummary(for: current)
        let outgoingSummary = try FrozenOutgoingSeasonSummary(
            outgoingSeasonVersionID: accepted.versionID,
            outgoingSeasonID: accepted.logicalID,
            outgoingContentHash: accepted.contentHash,
            frozenAt: now,
            title: current.title,
            status: current.status,
            effectiveInterval: current.effectiveInterval,
            plainLanguageSummary: plainLanguageSummary
        )
        let retrospective = try SeasonRetrospective(
            overview: plainLanguageSummary,
            practicesToCarryForward: Self.unique(
                current.portfolioItems.compactMap(\.minimumViableCommitment)
            ),
            peopleAndExperiencesThatMattered: current.protectedExperiences,
            dataAndModelQualityNotes: [
                "This draft uses the accepted Season Charter only; verify it against "
                    + "source history."
            ]
        )
        let successor = try Season(
            metadata: metadata(
                id: versionID,
                createdAt: now,
                revision: 1,
                revisedAt: now
            ),
            charterRevisionID: current.charterRevisionID,
            title: "Next season",
            effectiveInterval: interval(startingAt: now),
            status: .calibration,
            createdFrom: .user,
            rationale: "Calibrate the next decision policy against current context before "
                + "increasing intervention intensity.",
            triggeringContext: ["The prior season reached a terminal state"],
            portfolioItems: current.portfolioItems,
            explicitNonGoals: current.explicitNonGoals,
            constraints: current.constraints,
            opportunityBudgets: current.opportunityBudgets,
            progressSignals: current.progressSignals,
            failureGuardrails: current.failureGuardrails,
            protectedExperiences: current.protectedExperiences,
            knownTradeoffs: current.knownTradeoffs,
            goodWeekDescription: current.goodWeekDescription,
            transitionTriggers: current.transitionTriggers,
            reviewCadence: "Every two weeks during calibration",
            transitionNotes: "Carry forward only what still fits after reviewing the outgoing season.",
            supersedesSeasonID: accepted.logicalID,
            outgoingSummary: outgoingSummary,
            retrospective: retrospective,
            primaryOverrideExplanation: current.primaryOverrideExplanation
        )
        return try proposal(
            kind: .season,
            versionID: versionID,
            logicalID: seasonID,
            versionNumber: 1,
            baseVersionID: accepted.versionID,
            acceptanceMethod: .ownerAuthored,
            value: successor
        )
    }

    private static func outgoingSummary(for season: Season) -> String {
        let portfolioCount = season.portfolioItems.count
        let foundationCount = season.portfolioItems.count { $0.role == .foundation }
        let nonGoalCount = season.explicitNonGoals.count
        return "“\(season.title)” is preserved as an outgoing decision policy, not a grade "
            + "of the person. It carried \(portfolioCount) portfolio directions, protected "
            + "\(foundationCount) foundations, and named \(nonGoalCount) explicit not-now "
            + "areas. Review source history before recording achievements or disappointments."
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert($0).inserted
        }
    }

    private func proposal<Value: Encodable>(
        kind: LifeModelKind,
        versionID: UUIDv7,
        logicalID: UUIDv7,
        versionNumber: Int,
        baseVersionID: UUIDv7?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        value: Value
    ) throws -> LifeModelDraftProposal {
        let document = try SyncJSONCoding.makeDecoder().decode(
            [String: JSONValue].self,
            from: SyncJSONCoding.makeEncoder().encode(value)
        )
        return try LifeModelDraftProposal(
            kind: kind,
            versionID: versionID,
            logicalID: logicalID,
            versionNumber: versionNumber,
            baseVersionID: baseVersionID,
            acceptanceMethod: acceptanceMethod,
            document: document
        )
    }

    private func metadata(
        id: UUIDv7,
        createdAt: Date,
        revision: Int,
        revisedAt: Date
    ) throws -> EntityMetadata {
        try EntityMetadata(
            id: id,
            createdAt: createdAt,
            createdBy: ActorRef(actorType: .user, actorID: ownerActorID),
            lastRevisedAt: revisedAt,
            revision: revision,
            sensitivity: .sensitive,
            provenanceID: provenanceIdentifier()
        )
    }

    private func revisedMetadata(
        _ current: EntityMetadata,
        id: UUIDv7,
        at date: Date
    ) throws -> EntityMetadata {
        try EntityMetadata(
            id: id,
            schemaVersion: current.schemaVersion,
            createdAt: current.createdAt,
            createdBy: ActorRef(actorType: .user, actorID: ownerActorID),
            lastRevisedAt: date,
            revision: current.revision + 1,
            sensitivity: current.sensitivity,
            provenanceID: provenanceIdentifier()
        )
    }

    private func interval(startingAt date: Date) throws -> TemporalInterval {
        try TemporalInterval(
            start: .instant(date),
            timeZoneID: timeZoneID,
            startPrecision: .day
        )
    }

    private func validNow() throws -> Date {
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw LifeModelWorkshopDraftFactoryError.invalidClock
        }
        return now
    }
}
