import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public struct CharterRevisionRequest: Codable, Hashable, Sendable {
    public let eventID: UUIDv7
    public let deviceID: UUIDv7
    public let expectedCurrentVersionID: UUIDv7?
    public let acceptanceMethod: LifeModelAcceptanceMethod
    public let charter: CharterVersion

    public init(
        eventID: UUIDv7,
        deviceID: UUIDv7,
        expectedCurrentVersionID: UUIDv7?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        charter: CharterVersion
    ) {
        self.eventID = eventID
        self.deviceID = deviceID
        self.expectedCurrentVersionID = expectedCurrentVersionID
        self.acceptanceMethod = acceptanceMethod
        self.charter = charter
    }
}

public struct LifeStageRevisionRequest: Codable, Hashable, Sendable {
    public let eventID: UUIDv7
    public let deviceID: UUIDv7
    public let expectedCurrentVersionID: UUIDv7?
    public let acceptanceMethod: LifeModelAcceptanceMethod
    public let acceptedAt: Date
    public let lifeStage: LifeStageVersion

    public init(
        eventID: UUIDv7,
        deviceID: UUIDv7,
        expectedCurrentVersionID: UUIDv7?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        acceptedAt: Date,
        lifeStage: LifeStageVersion
    ) {
        self.eventID = eventID
        self.deviceID = deviceID
        self.expectedCurrentVersionID = expectedCurrentVersionID
        self.acceptanceMethod = acceptanceMethod
        self.acceptedAt = acceptedAt
        self.lifeStage = lifeStage
    }
}

public struct SeasonRevisionRequest: Codable, Hashable, Sendable {
    public let eventID: UUIDv7
    public let deviceID: UUIDv7
    public let seasonID: UUIDv7
    public let expectedCurrentVersionID: UUIDv7?
    public let acceptanceMethod: LifeModelAcceptanceMethod
    public let acceptedAt: Date
    public let season: Season

    public init(
        eventID: UUIDv7,
        deviceID: UUIDv7,
        seasonID: UUIDv7,
        expectedCurrentVersionID: UUIDv7?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        acceptedAt: Date,
        season: Season
    ) {
        self.eventID = eventID
        self.deviceID = deviceID
        self.seasonID = seasonID
        self.expectedCurrentVersionID = expectedCurrentVersionID
        self.acceptanceMethod = acceptanceMethod
        self.acceptedAt = acceptedAt
        self.season = season
    }
}

public struct LifeModelVersionEnvelope: Codable, Hashable, Sendable {
    public let kind: LifeModelKind
    public let versionID: UUIDv7
    public let logicalID: UUIDv7
    public let versionNumber: Int
    public let acceptanceSequence: Int
    public let eventID: UUIDv7
    public let ledgerSequence: Int64
    public let supersedesVersionID: UUIDv7?
    public let status: String?
    public let acceptanceMethod: LifeModelAcceptanceMethod
    public let acceptedAt: Date
    public let contentHash: String
    public let document: [String: JSONValue]

    public init(
        kind: LifeModelKind,
        versionID: UUIDv7,
        logicalID: UUIDv7,
        versionNumber: Int,
        acceptanceSequence: Int,
        eventID: UUIDv7,
        ledgerSequence: Int64,
        supersedesVersionID: UUIDv7?,
        status: String?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        acceptedAt: Date,
        contentHash: String,
        document: [String: JSONValue]
    ) {
        self.kind = kind
        self.versionID = versionID
        self.logicalID = logicalID
        self.versionNumber = versionNumber
        self.acceptanceSequence = acceptanceSequence
        self.eventID = eventID
        self.ledgerSequence = ledgerSequence
        self.supersedesVersionID = supersedesVersionID
        self.status = status
        self.acceptanceMethod = acceptanceMethod
        self.acceptedAt = acceptedAt
        self.contentHash = contentHash
        self.document = document
    }

    public func cached(
        policyVersion: String,
        cachedAt: Date
    ) throws -> CachedLifeModelVersion {
        try CachedLifeModelVersion(
            kind: kind,
            versionID: versionID,
            logicalID: logicalID,
            versionNumber: versionNumber,
            acceptanceSequence: acceptanceSequence,
            supersedesVersionID: supersedesVersionID,
            status: status,
            acceptanceMethod: acceptanceMethod,
            acceptedAt: acceptedAt,
            contentHash: contentHash,
            document: SyncJSONCoding.makeEncoder().encode(document),
            eventID: eventID,
            ledgerSequence: ledgerSequence,
            policyVersion: policyVersion,
            cachedAt: cachedAt
        )
    }
}

public struct LifeModelRevisionReceipt: Codable, Hashable, Sendable {
    public let version: LifeModelVersionEnvelope
    public let eventID: UUIDv7
    public let ledgerSequence: Int64
    public let created: Bool
    public let warnings: [String]
    public let policyVersion: String

    public init(
        version: LifeModelVersionEnvelope,
        eventID: UUIDv7,
        ledgerSequence: Int64,
        created: Bool,
        warnings: [String],
        policyVersion: String
    ) {
        self.version = version
        self.eventID = eventID
        self.ledgerSequence = ledgerSequence
        self.created = created
        self.warnings = warnings
        self.policyVersion = policyVersion
    }
}

public struct CurrentOrientationResponse: Codable, Hashable, Sendable {
    public let asOf: Date
    public let charter: LifeModelVersionEnvelope?
    public let lifeStage: LifeModelVersionEnvelope?
    public let season: LifeModelVersionEnvelope?
    public let policyVersion: String

    public init(
        asOf: Date,
        charter: LifeModelVersionEnvelope?,
        lifeStage: LifeModelVersionEnvelope?,
        season: LifeModelVersionEnvelope?,
        policyVersion: String
    ) {
        self.asOf = asOf
        self.charter = charter
        self.lifeStage = lifeStage
        self.season = season
        self.policyVersion = policyVersion
    }

    public func version(for kind: LifeModelKind) -> LifeModelVersionEnvelope? {
        switch kind {
        case .charter:
            charter
        case .lifeStage:
            lifeStage
        case .season:
            season
        }
    }

    public var versions: [LifeModelVersionEnvelope] {
        [charter, lifeStage, season].compactMap { $0 }
    }
}

public struct LifeModelHistoryResponse: Codable, Hashable, Sendable {
    public let kind: LifeModelKind
    public let versions: [LifeModelVersionEnvelope]
    public let policyVersion: String

    public init(
        kind: LifeModelKind,
        versions: [LifeModelVersionEnvelope],
        policyVersion: String
    ) {
        self.kind = kind
        self.versions = versions
        self.policyVersion = policyVersion
    }
}
