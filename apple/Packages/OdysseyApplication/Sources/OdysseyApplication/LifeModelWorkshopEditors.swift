import Foundation
import OdysseyDomain
import OdysseySync

public enum LifeModelWorkshopEditorError: Error, Equatable, Sendable {
    case incorrectKind(expected: LifeModelKind, actual: LifeModelKind)
    case invalidDocument(LifeModelKind)
}

extension LifeModelWorkshopEditorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .incorrectKind(expected, actual):
            "This editor requires a \(expected.displayName) draft, not \(actual.displayName)."
        case let .invalidDocument(kind):
            "The \(kind.displayName) draft does not satisfy the reviewed life-model contract."
        }
    }
}

public extension LifeModelKind {
    var displayName: String {
        switch self {
        case .charter:
            "Charter"
        case .lifeStage:
            "life stage"
        case .season:
            "season"
        }
    }
}

public struct CharterValueEditor: Identifiable, Equatable, Sendable {
    public let id: UUIDv7
    public var title: String
    public var description: String
    public var positiveExpression: String
    public var antiValueOrFailureMode: String

    public init(
        id: UUIDv7 = UUIDv7(),
        title: String = "",
        description: String = "",
        positiveExpression: String = "",
        antiValueOrFailureMode: String = ""
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.positiveExpression = positiveExpression
        self.antiValueOrFailureMode = antiValueOrFailureMode
    }

    init(_ value: CharterValue) {
        self.init(
            id: value.id,
            title: value.title,
            description: value.description,
            positiveExpression: value.positiveExpression,
            antiValueOrFailureMode: value.antiValueOrFailureMode ?? ""
        )
    }

    func value() throws -> CharterValue {
        try CharterValue(
            id: id,
            title: title,
            description: description,
            positiveExpression: positiveExpression,
            antiValueOrFailureMode: nilIfBlank(antiValueOrFailureMode)
        )
    }
}

public struct CharterDraftEditor: Equatable, Sendable {
    public let draftID: UUIDv7
    public let expectedStateRevision: Int
    public var values: [CharterValueEditor]
    public var responsibilities: [String]
    public var desiredWaysOfBeing: [String]
    public var nonNegotiableBoundaries: [String]
    public var antiOptimizationStatements: [String]
    public var interpretationNotes: String

    private let metadata: EntityMetadata
    private let charterID: UUIDv7
    private let versionNumber: Int
    private let effectiveInterval: TemporalInterval
    private let supersedesVersionID: UUIDv7?
    private let acceptedAt: Date

    public init(draft: LifeModelDraftRecord) throws {
        guard draft.kind == .charter else {
            throw LifeModelWorkshopEditorError.incorrectKind(
                expected: .charter,
                actual: draft.kind
            )
        }
        let charter: CharterVersion = try decodeDraft(draft)
        draftID = draft.draftID
        expectedStateRevision = draft.stateRevision
        values = charter.values.map(CharterValueEditor.init)
        responsibilities = charter.responsibilities
        desiredWaysOfBeing = charter.desiredWaysOfBeing
        nonNegotiableBoundaries = charter.nonNegotiableBoundaries
        antiOptimizationStatements = charter.antiOptimizationStatements
        interpretationNotes = charter.interpretationNotes
        metadata = charter.metadata
        charterID = charter.charterID
        versionNumber = charter.versionNumber
        effectiveInterval = charter.effectiveInterval
        supersedesVersionID = charter.supersedesVersionID
        acceptedAt = charter.acceptedAt
    }

    public func document() throws -> [String: JSONValue] {
        do {
            return try encodeDraft(
                CharterVersion(
                    metadata: metadata,
                    charterID: charterID,
                    versionNumber: versionNumber,
                    effectiveInterval: effectiveInterval,
                    values: try values.map { try $0.value() },
                    responsibilities: responsibilities,
                    desiredWaysOfBeing: desiredWaysOfBeing,
                    nonNegotiableBoundaries: nonNegotiableBoundaries,
                    antiOptimizationStatements: antiOptimizationStatements,
                    interpretationNotes: interpretationNotes,
                    supersedesVersionID: supersedesVersionID,
                    acceptedAt: acceptedAt
                )
            )
        } catch {
            throw LifeModelWorkshopEditorError.invalidDocument(.charter)
        }
    }
}

public struct LifeStageDraftEditor: Equatable, Sendable {
    public let draftID: UUIDv7
    public let expectedStateRevision: Int
    public var title: String
    public var careerContext: String
    public var partnershipFamilyContext: String
    public var healthCapabilityContext: String
    public var geographyContext: String
    public var financialContext: String
    public var careResponsibilities: [String]
    public var identityTransitions: [String]
    public var horizons: [String]
    public var uncertainties: [String]

    private let metadata: EntityMetadata
    private let stageID: UUIDv7
    private let effectiveInterval: TemporalInterval

    public init(draft: LifeModelDraftRecord) throws {
        guard draft.kind == .lifeStage else {
            throw LifeModelWorkshopEditorError.incorrectKind(
                expected: .lifeStage,
                actual: draft.kind
            )
        }
        let lifeStage: LifeStageVersion = try decodeDraft(draft)
        draftID = draft.draftID
        expectedStateRevision = draft.stateRevision
        title = lifeStage.title
        careerContext = lifeStage.careerContext
        partnershipFamilyContext = lifeStage.partnershipFamilyContext
        healthCapabilityContext = lifeStage.healthCapabilityContext
        geographyContext = lifeStage.geographyContext
        financialContext = lifeStage.financialContext
        careResponsibilities = lifeStage.careResponsibilities
        identityTransitions = lifeStage.identityTransitions
        horizons = lifeStage.horizons
        uncertainties = lifeStage.uncertainties
        metadata = lifeStage.metadata
        stageID = lifeStage.stageID
        effectiveInterval = lifeStage.effectiveInterval
    }

    public func document() throws -> [String: JSONValue] {
        do {
            return try encodeDraft(
                LifeStageVersion(
                    metadata: metadata,
                    stageID: stageID,
                    effectiveInterval: effectiveInterval,
                    title: title,
                    careerContext: careerContext,
                    partnershipFamilyContext: partnershipFamilyContext,
                    healthCapabilityContext: healthCapabilityContext,
                    geographyContext: geographyContext,
                    financialContext: financialContext,
                    careResponsibilities: careResponsibilities,
                    identityTransitions: identityTransitions,
                    horizons: horizons,
                    uncertainties: uncertainties
                )
            )
        } catch {
            throw LifeModelWorkshopEditorError.invalidDocument(.lifeStage)
        }
    }
}

public struct SeasonPortfolioItemEditor: Identifiable, Equatable, Sendable {
    public var id: UUIDv7 { directionID }

    public let directionID: UUIDv7
    public var role: DirectionRole
    public var allocationBand: AllocationBand
    public var minimumViableCommitment: String
    public var sacrificeLimit: String
    public var successSignals: [String]
    public var reviewDate: LocalDate?

    public init(
        directionID: UUIDv7 = UUIDv7(),
        role: DirectionRole = .foundation,
        allocationBand: AllocationBand = .moderate,
        minimumViableCommitment: String = "",
        sacrificeLimit: String = "",
        successSignals: [String] = [],
        reviewDate: LocalDate? = nil
    ) {
        self.directionID = directionID
        self.role = role
        self.allocationBand = allocationBand
        self.minimumViableCommitment = minimumViableCommitment
        self.sacrificeLimit = sacrificeLimit
        self.successSignals = successSignals
        self.reviewDate = reviewDate
    }

    init(_ value: SeasonPortfolioItem) {
        self.init(
            directionID: value.directionID,
            role: value.role,
            allocationBand: value.allocationBand,
            minimumViableCommitment: value.minimumViableCommitment ?? "",
            sacrificeLimit: value.sacrificeLimit ?? "",
            successSignals: value.successSignals,
            reviewDate: value.reviewDate
        )
    }

    func value() -> SeasonPortfolioItem {
        SeasonPortfolioItem(
            directionID: directionID,
            role: role,
            allocationBand: allocationBand,
            minimumViableCommitment: nilIfBlank(minimumViableCommitment),
            sacrificeLimit: nilIfBlank(sacrificeLimit),
            successSignals: successSignals,
            reviewDate: reviewDate
        )
    }
}

public struct SeasonRetrospectiveEditor: Equatable, Sendable {
    public let originalStatus: SeasonRetrospectiveStatus
    public var status: SeasonRetrospectiveStatus
    public var overview: String
    public var achievements: [String]
    public var disappointments: [String]
    public var decisionsThatChangedDirection: [String]
    public var practicesToCarryForward: [String]
    public var beliefsStrengthened: [String]
    public var beliefsInvalidated: [String]
    public var peopleAndExperiencesThatMattered: [String]
    public var dataAndModelQualityNotes: [String]
    public var unfinishedCommitmentDecisions: [String]

    public init(_ retrospective: SeasonRetrospective) {
        originalStatus = retrospective.status
        status = retrospective.status
        overview = retrospective.overview
        achievements = retrospective.achievements
        disappointments = retrospective.disappointments
        decisionsThatChangedDirection = retrospective.decisionsThatChangedDirection
        practicesToCarryForward = retrospective.practicesToCarryForward
        beliefsStrengthened = retrospective.beliefsStrengthened
        beliefsInvalidated = retrospective.beliefsInvalidated
        peopleAndExperiencesThatMattered = retrospective.peopleAndExperiencesThatMattered
        dataAndModelQualityNotes = retrospective.dataAndModelQualityNotes
        unfinishedCommitmentDecisions = retrospective.unfinishedCommitmentDecisions
    }

    public var allowedStatuses: [SeasonRetrospectiveStatus] {
        switch originalStatus {
        case .draft:
            [.draft, .accepted, .skipped]
        case .accepted:
            [.accepted]
        case .skipped:
            [.skipped]
        }
    }

    func value() throws -> SeasonRetrospective {
        guard allowedStatuses.contains(status) else {
            throw LifeModelWorkshopEditorError.invalidDocument(.season)
        }
        return try SeasonRetrospective(
            status: status,
            overview: overview,
            achievements: achievements,
            disappointments: disappointments,
            decisionsThatChangedDirection: decisionsThatChangedDirection,
            practicesToCarryForward: practicesToCarryForward,
            beliefsStrengthened: beliefsStrengthened,
            beliefsInvalidated: beliefsInvalidated,
            peopleAndExperiencesThatMattered: peopleAndExperiencesThatMattered,
            dataAndModelQualityNotes: dataAndModelQualityNotes,
            unfinishedCommitmentDecisions: unfinishedCommitmentDecisions
        )
    }
}

public struct SeasonDraftEditor: Equatable, Sendable {
    public let draftID: UUIDv7
    public let expectedStateRevision: Int
    public let originalStatus: SeasonStatus
    public let isSuccessor: Bool
    public var title: String
    public var status: SeasonStatus
    public var rationale: String
    public var triggeringContext: [String]
    public var portfolioItems: [SeasonPortfolioItemEditor]
    public var explicitNonGoals: [String]
    public var constraints: [String]
    public var opportunityBudgets: [String]
    public var progressSignals: [String]
    public var failureGuardrails: [String]
    public var protectedExperiences: [String]
    public var knownTradeoffs: [String]
    public var goodWeekDescription: String
    public var transitionTriggers: [String]
    public var reviewCadence: String
    public var transitionNotes: String
    public let outgoingSummary: FrozenOutgoingSeasonSummary?
    public var retrospective: SeasonRetrospectiveEditor?
    public var primaryOverrideExplanation: String

    private let metadata: EntityMetadata
    private let charterRevisionID: UUIDv7
    private let effectiveInterval: TemporalInterval
    private let createdFrom: SeasonCreationSource
    private let supersedesSeasonID: UUIDv7?

    public init(draft: LifeModelDraftRecord) throws {
        guard draft.kind == .season else {
            throw LifeModelWorkshopEditorError.incorrectKind(
                expected: .season,
                actual: draft.kind
            )
        }
        let season: Season = try decodeDraft(draft)
        draftID = draft.draftID
        expectedStateRevision = draft.stateRevision
        originalStatus = season.status
        isSuccessor = draft.baseVersionID != nil && draft.versionNumber == 1
        title = season.title
        status = season.status
        rationale = season.rationale
        triggeringContext = season.triggeringContext
        portfolioItems = season.portfolioItems.map(SeasonPortfolioItemEditor.init)
        explicitNonGoals = season.explicitNonGoals
        constraints = season.constraints
        opportunityBudgets = season.opportunityBudgets
        progressSignals = season.progressSignals
        failureGuardrails = season.failureGuardrails
        protectedExperiences = season.protectedExperiences
        knownTradeoffs = season.knownTradeoffs
        goodWeekDescription = season.goodWeekDescription
        transitionTriggers = season.transitionTriggers
        reviewCadence = season.reviewCadence
        transitionNotes = season.transitionNotes ?? ""
        outgoingSummary = season.outgoingSummary
        retrospective = season.retrospective.map(SeasonRetrospectiveEditor.init)
        primaryOverrideExplanation = season.primaryOverrideExplanation ?? ""
        metadata = season.metadata
        charterRevisionID = season.charterRevisionID
        effectiveInterval = season.effectiveInterval
        createdFrom = season.createdFrom
        supersedesSeasonID = season.supersedesSeasonID
    }

    public var allowedStatuses: [SeasonStatus] {
        if isSuccessor || supersedesSeasonID == nil {
            return [.draft, .calibration, .active, .abandoned]
        }
        switch originalStatus {
        case .draft:
            return [.draft, .calibration, .active, .abandoned]
        case .calibration:
            return [.calibration, .active, .abandoned]
        case .active:
            return [.active, .transitioning, .abandoned]
        case .transitioning:
            return [.transitioning, .complete, .active]
        case .complete:
            return [.complete]
        case .abandoned:
            return [.abandoned]
        }
    }

    public func document() throws -> [String: JSONValue] {
        guard allowedStatuses.contains(status) else {
            throw LifeModelWorkshopEditorError.invalidDocument(.season)
        }
        do {
            return try encodeDraft(
                Season(
                    metadata: metadata,
                    charterRevisionID: charterRevisionID,
                    title: title,
                    effectiveInterval: effectiveInterval,
                    status: status,
                    createdFrom: createdFrom,
                    rationale: rationale,
                    triggeringContext: triggeringContext,
                    portfolioItems: portfolioItems.map { $0.value() },
                    explicitNonGoals: explicitNonGoals,
                    constraints: constraints,
                    opportunityBudgets: opportunityBudgets,
                    progressSignals: progressSignals,
                    failureGuardrails: failureGuardrails,
                    protectedExperiences: protectedExperiences,
                    knownTradeoffs: knownTradeoffs,
                    goodWeekDescription: goodWeekDescription,
                    transitionTriggers: transitionTriggers,
                    reviewCadence: reviewCadence,
                    transitionNotes: nilIfBlank(transitionNotes),
                    supersedesSeasonID: supersedesSeasonID,
                    outgoingSummary: outgoingSummary,
                    retrospective: try retrospective?.value(),
                    primaryOverrideExplanation: nilIfBlank(primaryOverrideExplanation)
                )
            )
        } catch {
            throw LifeModelWorkshopEditorError.invalidDocument(.season)
        }
    }
}

private func decodeDraft<Value: Decodable>(
    _ draft: LifeModelDraftRecord
) throws -> Value {
    do {
        return try SyncJSONCoding.makeDecoder().decode(
            Value.self,
            from: SyncJSONCoding.makeEncoder().encode(draft.document)
        )
    } catch {
        throw LifeModelWorkshopEditorError.invalidDocument(draft.kind)
    }
}

private func encodeDraft<Value: Encodable>(
    _ value: Value
) throws -> [String: JSONValue] {
    try SyncJSONCoding.makeDecoder().decode(
        [String: JSONValue].self,
        from: SyncJSONCoding.makeEncoder().encode(value)
    )
}

private func nilIfBlank(_ value: String) -> String? {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
}
