import Foundation
import OdysseyDomain

public enum SeasonMapEmphasis: String, CaseIterable, Hashable, Sendable {
    case foreground
    case middleGround
    case background
}

public struct SeasonMapPath: Identifiable, Hashable, Sendable {
    public let id: UUIDv7
    public let role: DirectionRole
    public let allocationBand: AllocationBand
    public let emphasis: SeasonMapEmphasis
    public let title: String
    public let detail: String
    public let boundary: String?
    public let signals: [String]

    public init(
        id: UUIDv7,
        role: DirectionRole,
        allocationBand: AllocationBand,
        emphasis: SeasonMapEmphasis,
        title: String,
        detail: String,
        boundary: String?,
        signals: [String]
    ) {
        self.id = id
        self.role = role
        self.allocationBand = allocationBand
        self.emphasis = emphasis
        self.title = title
        self.detail = detail
        self.boundary = boundary
        self.signals = signals
    }
}

public struct SeasonMapLandmark: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?

    public init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public struct SeasonMapProjection: Hashable, Sendable {
    public let seasonVersionID: UUIDv7
    public let title: String
    public let status: SeasonStatus
    public let orientationStatement: String
    public let rationale: String
    public let paths: [SeasonMapPath]
    public let protectedTerrain: [String]
    public let openHorizon: [String]
    public let landmarks: [SeasonMapLandmark]
    public let deliberatelyDormant: [String]
    public let reviewCadence: String

    public init(
        seasonVersionID: UUIDv7,
        title: String,
        status: SeasonStatus,
        orientationStatement: String,
        rationale: String,
        paths: [SeasonMapPath],
        protectedTerrain: [String],
        openHorizon: [String],
        landmarks: [SeasonMapLandmark],
        deliberatelyDormant: [String],
        reviewCadence: String
    ) {
        self.seasonVersionID = seasonVersionID
        self.title = title
        self.status = status
        self.orientationStatement = orientationStatement
        self.rationale = rationale
        self.paths = paths
        self.protectedTerrain = protectedTerrain
        self.openHorizon = openHorizon
        self.landmarks = landmarks
        self.deliberatelyDormant = deliberatelyDormant
        self.reviewCadence = reviewCadence
    }
}

public enum SeasonMapProjector {
    public static func project(_ season: Season) -> SeasonMapProjection {
        let roleCounts = Dictionary(grouping: season.portfolioItems, by: \.role)
            .mapValues(\.count)
        var roleOffsets: [DirectionRole: Int] = [:]
        let paths = season.portfolioItems.map { item in
            let offset = roleOffsets[item.role, default: 0] + 1
            roleOffsets[item.role] = offset
            let roleCount = roleCounts[item.role, default: 0]
            return SeasonMapPath(
                id: item.directionID,
                role: item.role,
                allocationBand: item.allocationBand,
                emphasis: emphasis(for: item.role),
                title: title(for: item.role, offset: offset, count: roleCount),
                detail: item.minimumViableCommitment
                    ?? item.successSignals.first
                    ?? fallbackDetail(for: item.role),
                boundary: item.sacrificeLimit,
                signals: item.successSignals
            )
        }
        let foundationDetails = paths
            .filter { $0.role == .foundation }
            .map(\.detail)
        let dormantDetails = paths
            .filter { $0.role == .dormant }
            .map(\.detail)
        let reviewLandmarks = season.portfolioItems.compactMap { item -> SeasonMapLandmark? in
            guard let reviewDate = item.reviewDate else { return nil }
            return SeasonMapLandmark(
                id: "review-\(item.directionID.description)",
                title: "Review \(title(for: item.role, offset: 1, count: 1).lowercased())",
                detail: localDate(reviewDate)
            )
        }
        let transitionLandmarks = season.transitionTriggers.enumerated().map {
            SeasonMapLandmark(
                id: "transition-\($0.offset)",
                title: $0.element
            )
        }
        return SeasonMapProjection(
            seasonVersionID: season.metadata.id,
            title: season.title,
            status: season.status,
            orientationStatement: season.goodWeekDescription,
            rationale: season.rationale,
            paths: paths,
            protectedTerrain: unique(
                foundationDetails + season.constraints + season.protectedExperiences
            ),
            openHorizon: unique(season.opportunityBudgets + season.protectedExperiences),
            landmarks: transitionLandmarks + reviewLandmarks,
            deliberatelyDormant: unique(dormantDetails + season.explicitNonGoals),
            reviewCadence: season.reviewCadence
        )
    }

    private static func emphasis(for role: DirectionRole) -> SeasonMapEmphasis {
        switch role {
        case .primary:
            .foreground
        case .foundation, .maintenance, .exploration:
            .middleGround
        case .dormant:
            .background
        }
    }

    private static func title(
        for role: DirectionRole,
        offset: Int,
        count: Int
    ) -> String {
        let base = switch role {
        case .primary: "Primary direction"
        case .foundation: "Protected foundation"
        case .maintenance: "Maintenance path"
        case .exploration: "Exploration path"
        case .dormant: "Dormant direction"
        }
        return count > 1 ? "\(base) \(offset)" : base
    }

    private static func fallbackDetail(for role: DirectionRole) -> String {
        switch role {
        case .primary:
            "The season's dominant direction"
        case .foundation:
            "A condition this season protects"
        case .maintenance:
            "A direction receiving enough attention to remain viable"
        case .exploration:
            "A bounded path for learning without premature commitment"
        case .dormant:
            "Deliberately outside the current attention budget"
        }
    }

    private static func localDate(_ date: LocalDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
