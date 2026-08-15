import Foundation

public enum DomainValidationError: Error, Equatable, Sendable {
    case invalidUUIDVersion
    case invalidTemporalInterval
    case invalidTimeZone
    case revisionPrecedesCreation
    case tombstonePrecedesCreation
    case tooManyPrimaryDirections
    case duplicateDirection
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
        let value = "\(timestamp.prefix(8))-\(timestamp.suffix(4))-7\(String(format: "%03x", randomA))-\(String(format: "%04x", variantAndHighRandom))-\(String(format: "%012llx", lowRandom))"
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
        try container.encode(rawValue)
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

public enum SeasonStatus: String, Codable, Sendable {
    case draft
    case calibration
    case active
    case transitioning
    case complete
    case abandoned
}

public enum DirectionRole: String, Codable, Sendable {
    case primary
    case foundation
    case maintenance
    case exploration
    case dormant
}

public enum AllocationBand: String, Codable, Sendable {
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

public struct Season: Codable, Hashable, Sendable {
    public let metadata: EntityMetadata
    public let title: String
    public let effectiveInterval: TemporalInterval
    public let status: SeasonStatus
    public let rationale: String
    public let triggeringContext: [String]
    public let portfolioItems: [SeasonPortfolioItem]
    public let constraints: [String]
    public let protectedExperiences: [String]
    public let knownTradeoffs: [String]
    public let transitionNotes: String?
    public let primaryOverrideExplanation: String?

    public init(
        metadata: EntityMetadata,
        title: String,
        effectiveInterval: TemporalInterval,
        status: SeasonStatus,
        rationale: String,
        triggeringContext: [String] = [],
        portfolioItems: [SeasonPortfolioItem],
        constraints: [String] = [],
        protectedExperiences: [String] = [],
        knownTradeoffs: [String] = [],
        transitionNotes: String? = nil,
        primaryOverrideExplanation: String? = nil
    ) throws {
        let primaryCount = portfolioItems.count { $0.role == .primary }
        if primaryCount > 2 && primaryOverrideExplanation?.isEmpty != false {
            throw DomainValidationError.tooManyPrimaryDirections
        }
        if Set(portfolioItems.map(\.directionID)).count != portfolioItems.count {
            throw DomainValidationError.duplicateDirection
        }
        self.metadata = metadata
        self.title = title
        self.effectiveInterval = effectiveInterval
        self.status = status
        self.rationale = rationale
        self.triggeringContext = triggeringContext
        self.portfolioItems = portfolioItems
        self.constraints = constraints
        self.protectedExperiences = protectedExperiences
        self.knownTradeoffs = knownTradeoffs
        self.transitionNotes = transitionNotes
        self.primaryOverrideExplanation = primaryOverrideExplanation
    }
}

