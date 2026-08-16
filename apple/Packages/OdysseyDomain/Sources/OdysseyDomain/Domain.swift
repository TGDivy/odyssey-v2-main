import Foundation

public enum DomainValidationError: Error, Equatable, Sendable {
    case invalidUUIDVersion
    case invalidTemporalInterval
    case invalidTimeZone
    case revisionPrecedesCreation
    case tombstonePrecedesCreation
    case tooManyPrimaryDirections
    case duplicateDirection
    case duplicateSeasonPolicyEntry
    case missingRequiredSeasonPolicy
    case invalidSeasonTransition
    case invalidCharter
    case invalidLifeStage
}

public struct UUIDv7: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
        let timestamp = String(format: "%012llx", milliseconds)
        let randomA = UInt16.random(in: 0 ... 0x0fff)
        let randomB = UInt64.random(in: 0 ... 0x3fff_ffff_ffff_ffff)
        let variantAndHighRandom = UInt16(0x8000) | UInt16((randomB >> 48) & 0x3fff)
        let lowRandom = randomB & 0x0000_ffff_ffff_ffff
        let value = "\(timestamp.prefix(8))-\(timestamp.suffix(4))"
            + "-7\(String(format: "%03x", randomA))"
            + "-\(String(format: "%04x", variantAndHighRandom))"
            + "-\(String(format: "%012llx", lowRandom))"
        self.rawValue = UUID(uuidString: value)!
    }

    public init(validating rawValue: UUID) throws {
        guard Self.version(of: rawValue) == 7 else {
            throw DomainValidationError.invalidUUIDVersion
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode(UUID.self)
        try self.init(validating: decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func version(of identifier: UUID) -> Int? {
        let compact = identifier.uuidString.replacingOccurrences(of: "-", with: "")
        let versionIndex = compact.index(compact.startIndex, offsetBy: 12)
        return Int(String(compact[versionIndex]), radix: 16)
    }
}

public enum ActorType: String, Codable, Sendable {
    case user
    case device
    case system
    case integration
    case model
}

public struct ActorRef: Codable, Hashable, Sendable {
    public let actorType: ActorType
    public let actorID: String

    public init(actorType: ActorType, actorID: String) {
        self.actorType = actorType
        self.actorID = actorID
    }
}

public enum DataClass: String, Codable, Sendable {
    case `public`
    case `private`
    case sensitive
    case highlySensitive = "highly_sensitive"
    case operationalSecret = "operational_secret"
    case derivedSensitive = "derived_sensitive"
}

public struct EntityMetadata: Codable, Hashable, Sendable {
    public let id: UUIDv7
    public let schemaVersion: Int
    public let createdAt: Date
    public let createdBy: ActorRef
    public let lastRevisedAt: Date
    public let revision: Int
    public let tombstonedAt: Date?
    public let sensitivity: DataClass
    public let provenanceID: UUID

    public init(
        id: UUIDv7 = UUIDv7(),
        schemaVersion: Int = 1,
        createdAt: Date,
        createdBy: ActorRef,
        lastRevisedAt: Date,
        revision: Int,
        tombstonedAt: Date? = nil,
        sensitivity: DataClass,
        provenanceID: UUID
    ) throws {
        guard lastRevisedAt >= createdAt else {
            throw DomainValidationError.revisionPrecedesCreation
        }
        if let tombstonedAt, tombstonedAt < createdAt {
            throw DomainValidationError.tombstonePrecedesCreation
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.lastRevisedAt = lastRevisedAt
        self.revision = revision
        self.tombstonedAt = tombstonedAt
        self.sensitivity = sensitivity
        self.provenanceID = provenanceID
    }
}

public struct LocalDate: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(
        containing instant: Date,
        in timeZoneID: String
    ) throws {
        guard instant.timeIntervalSinceReferenceDate.isFinite else {
            throw DomainValidationError.invalidTemporalInterval
        }
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw DomainValidationError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: instant
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            throw DomainValidationError.invalidTemporalInterval
        }
        self.init(year: year, month: month, day: day)
    }

    public static func < (left: LocalDate, right: LocalDate) -> Bool {
        if left.year != right.year { return left.year < right.year }
        if left.month != right.month { return left.month < right.month }
        return left.day < right.day
    }
}

public enum TemporalBoundary: Codable, Hashable, Sendable {
    case instant(Date)
    case localDate(LocalDate)
}

public enum TemporalPrecision: String, Codable, Sendable {
    case exact
    case minute
    case hour
    case day
    case month
    case approximate
    case unknown
}

public struct TemporalInterval: Codable, Hashable, Sendable {
    public let start: TemporalBoundary?
    public let end: TemporalBoundary?
    public let timeZoneID: String?
    public let startPrecision: TemporalPrecision
    public let endPrecision: TemporalPrecision
    public let allDaySemantics: Bool

    public init(
        start: TemporalBoundary? = nil,
        end: TemporalBoundary? = nil,
        timeZoneID: String? = nil,
        startPrecision: TemporalPrecision = .unknown,
        endPrecision: TemporalPrecision = .unknown,
        allDaySemantics: Bool = false
    ) throws {
        if let timeZoneID, TimeZone(identifier: timeZoneID) == nil {
            throw DomainValidationError.invalidTimeZone
        }
        switch (start, end) {
        case let (.instant(startDate), .instant(endDate)) where endDate < startDate:
            throw DomainValidationError.invalidTemporalInterval
        case let (.localDate(startDate), .localDate(endDate)) where endDate < startDate:
            throw DomainValidationError.invalidTemporalInterval
        case (.instant, .localDate), (.localDate, .instant):
            throw DomainValidationError.invalidTemporalInterval
        default:
            break
        }
        if allDaySemantics {
            if case .instant = start { throw DomainValidationError.invalidTemporalInterval }
            if case .instant = end { throw DomainValidationError.invalidTemporalInterval }
        }
        self.start = start
        self.end = end
        self.timeZoneID = timeZoneID
        self.startPrecision = startPrecision
        self.endPrecision = endPrecision
        self.allDaySemantics = allDaySemantics
    }
}

public enum EpistemicKind: String, Codable, Sendable {
    case observed
    case userStated = "user_stated"
    case externallyAsserted = "externally_asserted"
    case inferred
    case hypothesized
    case experimentallySupported = "experimentally_supported"
    case acceptedInterpretation = "accepted_interpretation"
    case retracted
}

public enum ConfidenceBand: String, Codable, Sendable {
    case veryLow = "very_low"
    case low
    case moderate
    case high
    case veryHigh = "very_high"
}

public enum Applicability: String, Codable, Sendable {
    case direct
    case partial
    case indirect
    case unknown
}

public struct EpistemicState: Codable, Hashable, Sendable {
    public let kind: EpistemicKind
    public let confidenceBand: ConfidenceBand?
    public let numericConfidence: Double?
    public let applicability: Applicability
    public let lastEvaluatedAt: Date?
    public let expiresAt: Date?

    public init(
        kind: EpistemicKind,
        confidenceBand: ConfidenceBand? = nil,
        numericConfidence: Double? = nil,
        applicability: Applicability = .unknown,
        lastEvaluatedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.kind = kind
        self.confidenceBand = confidenceBand
        self.numericConfidence = numericConfidence
        self.applicability = applicability
        self.lastEvaluatedAt = lastEvaluatedAt
        self.expiresAt = expiresAt
    }
}

public enum LifeModelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case charter
    case lifeStage = "life_stage"
    case season
}

public enum LifeModelAcceptanceMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case ownerAuthored = "owner_authored"
    case ownerReviewedAssisted = "owner_reviewed_assisted"
    case ownerApprovedImport = "owner_approved_import"
}

public struct CharterValue: Codable, Hashable, Sendable {
    public let id: UUIDv7
    public let title: String
    public let description: String
    public let positiveExpression: String
    public let antiValueOrFailureMode: String?

    public init(
        id: UUIDv7 = UUIDv7(),
        title: String,
        description: String,
        positiveExpression: String,
        antiValueOrFailureMode: String? = nil
    ) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !positiveExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DomainValidationError.invalidCharter
        }
        self.id = id
        self.title = title
        self.description = description
        self.positiveExpression = positiveExpression
        self.antiValueOrFailureMode = antiValueOrFailureMode
    }
}

public struct CharterVersion: Codable, Hashable, Sendable {
    public let metadata: EntityMetadata
    public let charterID: UUIDv7
    public let versionNumber: Int
    public let effectiveInterval: TemporalInterval
    public let values: [CharterValue]
    public let responsibilities: [String]
    public let desiredWaysOfBeing: [String]
    public let nonNegotiableBoundaries: [String]
    public let antiOptimizationStatements: [String]
    public let interpretationNotes: String
    public let supersedesVersionID: UUIDv7?
    public let acceptedAt: Date

    public init(
        metadata: EntityMetadata,
        charterID: UUIDv7,
        versionNumber: Int,
        effectiveInterval: TemporalInterval,
        values: [CharterValue],
        responsibilities: [String],
        desiredWaysOfBeing: [String],
        nonNegotiableBoundaries: [String],
        antiOptimizationStatements: [String],
        interpretationNotes: String = "",
        supersedesVersionID: UUIDv7? = nil,
        acceptedAt: Date
    ) throws {
        guard versionNumber >= 1,
              versionNumber == metadata.revision,
              !values.isEmpty,
              Set(values.map(\.id)).count == values.count,
              !antiOptimizationStatements.isEmpty,
              acceptedAt >= metadata.lastRevisedAt
        else {
            throw DomainValidationError.invalidCharter
        }
        self.metadata = metadata
        self.charterID = charterID
        self.versionNumber = versionNumber
        self.effectiveInterval = effectiveInterval
        self.values = values
        self.responsibilities = responsibilities
        self.desiredWaysOfBeing = desiredWaysOfBeing
        self.nonNegotiableBoundaries = nonNegotiableBoundaries
        self.antiOptimizationStatements = antiOptimizationStatements
        self.interpretationNotes = interpretationNotes
        self.supersedesVersionID = supersedesVersionID
        self.acceptedAt = acceptedAt
    }
}

public struct LifeStageVersion: Codable, Hashable, Sendable {
    public let metadata: EntityMetadata
    public let stageID: UUIDv7
    public let effectiveInterval: TemporalInterval
    public let title: String
    public let careerContext: String
    public let partnershipFamilyContext: String
    public let healthCapabilityContext: String
    public let geographyContext: String
    public let financialContext: String
    public let careResponsibilities: [String]
    public let identityTransitions: [String]
    public let horizons: [String]
    public let uncertainties: [String]

    public init(
        metadata: EntityMetadata,
        stageID: UUIDv7,
        effectiveInterval: TemporalInterval,
        title: String,
        careerContext: String = "",
        partnershipFamilyContext: String = "",
        healthCapabilityContext: String = "",
        geographyContext: String = "",
        financialContext: String = "",
        careResponsibilities: [String] = [],
        identityTransitions: [String] = [],
        horizons: [String] = [],
        uncertainties: [String] = []
    ) throws {
        guard metadata.revision >= 1,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DomainValidationError.invalidLifeStage
        }
        self.metadata = metadata
        self.stageID = stageID
        self.effectiveInterval = effectiveInterval
        self.title = title
        self.careerContext = careerContext
        self.partnershipFamilyContext = partnershipFamilyContext
        self.healthCapabilityContext = healthCapabilityContext
        self.geographyContext = geographyContext
        self.financialContext = financialContext
        self.careResponsibilities = careResponsibilities
        self.identityTransitions = identityTransitions
        self.horizons = horizons
        self.uncertainties = uncertainties
    }
}

public enum SeasonStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case draft
    case calibration
    case active
    case transitioning
    case complete
    case abandoned
}

public enum SeasonCreationSource: String, Codable, CaseIterable, Hashable, Sendable {
    case user
    case assisted
    case imported
}

public enum DirectionRole: String, Codable, CaseIterable, Hashable, Sendable {
    case primary
    case foundation
    case maintenance
    case exploration
    case dormant
}

public enum AllocationBand: String, Codable, CaseIterable, Hashable, Sendable {
    case minimal
    case low
    case moderate
    case high
    case dominant
}

public struct SeasonPortfolioItem: Codable, Hashable, Sendable {
    public let directionID: UUIDv7
    public let role: DirectionRole
    public let allocationBand: AllocationBand
    public let minimumViableCommitment: String?
    public let sacrificeLimit: String?
    public let successSignals: [String]
    public let reviewDate: LocalDate?

    public init(
        directionID: UUIDv7,
        role: DirectionRole,
        allocationBand: AllocationBand,
        minimumViableCommitment: String? = nil,
        sacrificeLimit: String? = nil,
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
}

public enum SeasonRetrospectiveStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case draft
    case accepted
    case skipped
}

public struct FrozenOutgoingSeasonSummary: Codable, Hashable, Sendable {
    public let outgoingSeasonVersionID: UUIDv7
    public let outgoingSeasonID: UUIDv7
    public let outgoingContentHash: String
    public let frozenAt: Date
    public let title: String
    public let status: SeasonStatus
    public let effectiveInterval: TemporalInterval
    public let plainLanguageSummary: String

    public init(
        outgoingSeasonVersionID: UUIDv7,
        outgoingSeasonID: UUIDv7,
        outgoingContentHash: String,
        frozenAt: Date,
        title: String,
        status: SeasonStatus,
        effectiveInterval: TemporalInterval,
        plainLanguageSummary: String
    ) throws {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        let hashIsValid = outgoingContentHash.count == 64
            && outgoingContentHash.unicodeScalars.allSatisfy(hexadecimal.contains)
        guard hashIsValid,
              frozenAt.timeIntervalSinceReferenceDate.isFinite,
              status == .complete || status == .abandoned,
              Self.validText(title, maximum: 200),
              Self.validText(plainLanguageSummary, maximum: 8_000)
        else {
            throw DomainValidationError.invalidSeasonTransition
        }
        self.outgoingSeasonVersionID = outgoingSeasonVersionID
        self.outgoingSeasonID = outgoingSeasonID
        self.outgoingContentHash = outgoingContentHash
        self.frozenAt = frozenAt
        self.title = title
        self.status = status
        self.effectiveInterval = effectiveInterval
        self.plainLanguageSummary = plainLanguageSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            outgoingSeasonVersionID: container.decode(
                UUIDv7.self,
                forKey: .outgoingSeasonVersionID
            ),
            outgoingSeasonID: container.decode(UUIDv7.self, forKey: .outgoingSeasonID),
            outgoingContentHash: container.decode(String.self, forKey: .outgoingContentHash),
            frozenAt: container.decode(Date.self, forKey: .frozenAt),
            title: container.decode(String.self, forKey: .title),
            status: container.decode(SeasonStatus.self, forKey: .status),
            effectiveInterval: container.decode(
                TemporalInterval.self,
                forKey: .effectiveInterval
            ),
            plainLanguageSummary: container.decode(String.self, forKey: .plainLanguageSummary)
        )
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SeasonRetrospective: Codable, Hashable, Sendable {
    public let status: SeasonRetrospectiveStatus
    public let overview: String
    public let achievements: [String]
    public let disappointments: [String]
    public let decisionsThatChangedDirection: [String]
    public let practicesToCarryForward: [String]
    public let beliefsStrengthened: [String]
    public let beliefsInvalidated: [String]
    public let peopleAndExperiencesThatMattered: [String]
    public let dataAndModelQualityNotes: [String]
    public let unfinishedCommitmentDecisions: [String]

    public init(
        status: SeasonRetrospectiveStatus = .draft,
        overview: String,
        achievements: [String] = [],
        disappointments: [String] = [],
        decisionsThatChangedDirection: [String] = [],
        practicesToCarryForward: [String] = [],
        beliefsStrengthened: [String] = [],
        beliefsInvalidated: [String] = [],
        peopleAndExperiencesThatMattered: [String] = [],
        dataAndModelQualityNotes: [String] = [],
        unfinishedCommitmentDecisions: [String] = []
    ) throws {
        let lists = [
            achievements,
            disappointments,
            decisionsThatChangedDirection,
            practicesToCarryForward,
            beliefsStrengthened,
            beliefsInvalidated,
            peopleAndExperiencesThatMattered,
            dataAndModelQualityNotes,
            unfinishedCommitmentDecisions,
        ]
        guard Self.validText(overview, maximum: 8_000),
              lists.allSatisfy(Self.validEntries)
        else {
            throw DomainValidationError.invalidSeasonTransition
        }
        self.status = status
        self.overview = overview
        self.achievements = achievements
        self.disappointments = disappointments
        self.decisionsThatChangedDirection = decisionsThatChangedDirection
        self.practicesToCarryForward = practicesToCarryForward
        self.beliefsStrengthened = beliefsStrengthened
        self.beliefsInvalidated = beliefsInvalidated
        self.peopleAndExperiencesThatMattered = peopleAndExperiencesThatMattered
        self.dataAndModelQualityNotes = dataAndModelQualityNotes
        self.unfinishedCommitmentDecisions = unfinishedCommitmentDecisions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            status: try container.decodeIfPresent(
                SeasonRetrospectiveStatus.self,
                forKey: .status
            ) ?? .draft,
            overview: try container.decode(String.self, forKey: .overview),
            achievements: try container.decodeIfPresent(
                [String].self,
                forKey: .achievements
            ) ?? [],
            disappointments: try container.decodeIfPresent(
                [String].self,
                forKey: .disappointments
            ) ?? [],
            decisionsThatChangedDirection: try container.decodeIfPresent(
                [String].self,
                forKey: .decisionsThatChangedDirection
            ) ?? [],
            practicesToCarryForward: try container.decodeIfPresent(
                [String].self,
                forKey: .practicesToCarryForward
            ) ?? [],
            beliefsStrengthened: try container.decodeIfPresent(
                [String].self,
                forKey: .beliefsStrengthened
            ) ?? [],
            beliefsInvalidated: try container.decodeIfPresent(
                [String].self,
                forKey: .beliefsInvalidated
            ) ?? [],
            peopleAndExperiencesThatMattered: try container.decodeIfPresent(
                [String].self,
                forKey: .peopleAndExperiencesThatMattered
            ) ?? [],
            dataAndModelQualityNotes: try container.decodeIfPresent(
                [String].self,
                forKey: .dataAndModelQualityNotes
            ) ?? [],
            unfinishedCommitmentDecisions: try container.decodeIfPresent(
                [String].self,
                forKey: .unfinishedCommitmentDecisions
            ) ?? []
        )
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validEntries(_ values: [String]) -> Bool {
        values.count <= 100
            && Set(values).count == values.count
            && values.allSatisfy { validText($0, maximum: 1_000) }
    }
}

public struct Season: Codable, Hashable, Sendable {
    public let metadata: EntityMetadata
    public let charterRevisionID: UUIDv7
    public let title: String
    public let effectiveInterval: TemporalInterval
    public let status: SeasonStatus
    public let createdFrom: SeasonCreationSource
    public let rationale: String
    public let triggeringContext: [String]
    public let portfolioItems: [SeasonPortfolioItem]
    public let explicitNonGoals: [String]
    public let constraints: [String]
    public let opportunityBudgets: [String]
    public let progressSignals: [String]
    public let failureGuardrails: [String]
    public let protectedExperiences: [String]
    public let knownTradeoffs: [String]
    public let goodWeekDescription: String
    public let transitionTriggers: [String]
    public let reviewCadence: String
    public let transitionNotes: String?
    public let supersedesSeasonID: UUIDv7?
    public let outgoingSummary: FrozenOutgoingSeasonSummary?
    public let retrospective: SeasonRetrospective?
    public let primaryOverrideExplanation: String?

    public init(
        metadata: EntityMetadata,
        charterRevisionID: UUIDv7,
        title: String,
        effectiveInterval: TemporalInterval,
        status: SeasonStatus,
        createdFrom: SeasonCreationSource,
        rationale: String,
        triggeringContext: [String] = [],
        portfolioItems: [SeasonPortfolioItem],
        explicitNonGoals: [String],
        constraints: [String] = [],
        opportunityBudgets: [String] = [],
        progressSignals: [String] = [],
        failureGuardrails: [String] = [],
        protectedExperiences: [String] = [],
        knownTradeoffs: [String] = [],
        goodWeekDescription: String,
        transitionTriggers: [String],
        reviewCadence: String,
        transitionNotes: String? = nil,
        supersedesSeasonID: UUIDv7? = nil,
        outgoingSummary: FrozenOutgoingSeasonSummary? = nil,
        retrospective: SeasonRetrospective? = nil,
        primaryOverrideExplanation: String? = nil
    ) throws {
        let primaryCount = portfolioItems.count { $0.role == .primary }
        if primaryCount > 2 && primaryOverrideExplanation?.isEmpty != false {
            throw DomainValidationError.tooManyPrimaryDirections
        }
        if Set(portfolioItems.map(\.directionID)).count != portfolioItems.count {
            throw DomainValidationError.duplicateDirection
        }
        let policyLists = [
            triggeringContext,
            explicitNonGoals,
            constraints,
            opportunityBudgets,
            progressSignals,
            failureGuardrails,
            protectedExperiences,
            knownTradeoffs,
            transitionTriggers,
        ]
        if policyLists.contains(where: { Set($0).count != $0.count }) {
            throw DomainValidationError.duplicateSeasonPolicyEntry
        }
        if explicitNonGoals.isEmpty || goodWeekDescription.isEmpty ||
            transitionTriggers.isEmpty || reviewCadence.isEmpty
        {
            throw DomainValidationError.missingRequiredSeasonPolicy
        }
        if retrospective != nil, outgoingSummary == nil {
            throw DomainValidationError.invalidSeasonTransition
        }
        self.metadata = metadata
        self.charterRevisionID = charterRevisionID
        self.title = title
        self.effectiveInterval = effectiveInterval
        self.status = status
        self.createdFrom = createdFrom
        self.rationale = rationale
        self.triggeringContext = triggeringContext
        self.portfolioItems = portfolioItems
        self.explicitNonGoals = explicitNonGoals
        self.constraints = constraints
        self.opportunityBudgets = opportunityBudgets
        self.progressSignals = progressSignals
        self.failureGuardrails = failureGuardrails
        self.protectedExperiences = protectedExperiences
        self.knownTradeoffs = knownTradeoffs
        self.goodWeekDescription = goodWeekDescription
        self.transitionTriggers = transitionTriggers
        self.reviewCadence = reviewCadence
        self.transitionNotes = transitionNotes
        self.supersedesSeasonID = supersedesSeasonID
        self.outgoingSummary = outgoingSummary
        self.retrospective = retrospective
        self.primaryOverrideExplanation = primaryOverrideExplanation
    }
}
