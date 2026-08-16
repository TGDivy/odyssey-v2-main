import Foundation
import OdysseyDomain

public enum ReentryError: Error, Equatable, Sendable {
    case invalidClock
    case invalidText
    case invalidRelevance
    case invalidPolicy
    case futureLastSeen
}

public enum ReentryOption: String, Codable, CaseIterable, Hashable, Sendable {
    case `continue`
    case reviseSeason = "revise_season"
    case stayQuiet = "stay_quiet"
}

public enum ReentryReason: String, Codable, Hashable, Sendable {
    case absenceThresholdMet = "ABSENCE_THRESHOLD_MET"
    case materialChangesSummarized = "MATERIAL_CHANGES_SUMMARIZED"
    case staleOpportunitiesExpired = "STALE_OPPORTUNITIES_EXPIRED"
    case oneClarificationSelected = "ONE_CLARIFICATION_SELECTED"
    case noCurrentMaterialChange = "NO_CURRENT_MATERIAL_CHANGE"
}

public struct ReentryMaterialChange: Codable, Hashable, Sendable {
    public let id: UUIDv7
    public let occurredAt: Date
    public let summary: String
    public let relevance: Double
    public let isMaterial: Bool
    public let isCurrentlyRelevant: Bool
    public let isUnresolved: Bool
    public let clarificationQuestion: String?
    public let clarificationValue: Double
    public let sourceReferences: [UUIDv7]

    public init(
        id: UUIDv7 = UUIDv7(),
        occurredAt: Date,
        summary: String,
        relevance: Double,
        isMaterial: Bool = true,
        isCurrentlyRelevant: Bool = true,
        isUnresolved: Bool = false,
        clarificationQuestion: String? = nil,
        clarificationValue: Double = 0,
        sourceReferences: [UUIDv7] = []
    ) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ReentryError.invalidClock
        }
        guard Self.validText(summary, maximum: 500),
              Self.validOptionalText(clarificationQuestion, maximum: 500)
        else {
            throw ReentryError.invalidText
        }
        guard relevance.isFinite,
              (0 ... 1).contains(relevance),
              clarificationValue.isFinite,
              (0 ... 1).contains(clarificationValue),
              clarificationQuestion != nil || clarificationValue == 0
        else {
            throw ReentryError.invalidRelevance
        }
        self.id = id
        self.occurredAt = occurredAt
        self.summary = summary
        self.relevance = relevance
        self.isMaterial = isMaterial
        self.isCurrentlyRelevant = isCurrentlyRelevant
        self.isUnresolved = isUnresolved
        self.clarificationQuestion = clarificationQuestion
        self.clarificationValue = clarificationValue
        self.sourceReferences = sourceReferences
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validOptionalText(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return true }
        return validText(value, maximum: maximum)
    }
}

public struct ReentryOpportunity: Codable, Hashable, Sendable {
    public let id: UUIDv7
    public let expiresAt: Date
    public let isActive: Bool

    public init(
        id: UUIDv7 = UUIDv7(),
        expiresAt: Date,
        isActive: Bool = true
    ) throws {
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ReentryError.invalidClock
        }
        self.id = id
        self.expiresAt = expiresAt
        self.isActive = isActive
    }
}

public struct ReentryPolicy: Codable, Hashable, Sendable {
    public let minimumAbsence: TimeInterval
    public let minimumMaterialRelevance: Double
    public let maximumSummaryItems: Int
    public let policyVersion: String

    public init(
        minimumAbsence: TimeInterval = 3 * 24 * 60 * 60,
        minimumMaterialRelevance: Double = 0.5,
        maximumSummaryItems: Int = 3,
        policyVersion: String = "reentry-policy-1.0"
    ) throws {
        guard minimumAbsence.isFinite,
              minimumAbsence > 0,
              minimumMaterialRelevance.isFinite,
              (0 ... 1).contains(minimumMaterialRelevance),
              (1 ... 3).contains(maximumSummaryItems),
              (1 ... 100).contains(policyVersion.count),
              policyVersion
                == policyVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw ReentryError.invalidPolicy
        }
        self.minimumAbsence = minimumAbsence
        self.minimumMaterialRelevance = minimumMaterialRelevance
        self.maximumSummaryItems = maximumSummaryItems
        self.policyVersion = policyVersion
    }
}

public struct ReentrySummaryItem: Codable, Hashable, Sendable {
    public let changeID: UUIDv7
    public let summary: String
    public let sourceReferences: [UUIDv7]
}

public struct ReentrySurface: Codable, Hashable, Sendable {
    public let summary: [ReentrySummaryItem]
    public let oneQuestion: String?
    public let options: [ReentryOption]
    public let expiredOpportunityIDs: [UUIDv7]
    public let suppressBacklog: Bool
    public let noAbsencePenalty: Bool
    public let reasons: [ReentryReason]
    public let policyVersion: String
}

public struct ReentryProjector: Sendable {
    public init() {}

    public func shouldEnter(
        lastSeen: Date?,
        now: Date
    ) throws -> Bool {
        try shouldEnter(
            lastSeen: lastSeen,
            now: now,
            policy: ReentryPolicy()
        )
    }

    public func shouldEnter(
        lastSeen: Date?,
        now: Date,
        policy: ReentryPolicy
    ) throws -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ReentryError.invalidClock
        }
        guard let lastSeen else { return false }
        guard lastSeen.timeIntervalSinceReferenceDate.isFinite else {
            throw ReentryError.invalidClock
        }
        guard lastSeen <= now else { throw ReentryError.futureLastSeen }
        return now.timeIntervalSince(lastSeen) >= policy.minimumAbsence
    }

    public func project(
        lastSeen: Date,
        now: Date,
        changes: [ReentryMaterialChange],
        opportunities: [ReentryOpportunity]
    ) throws -> ReentrySurface {
        try project(
            lastSeen: lastSeen,
            now: now,
            changes: changes,
            opportunities: opportunities,
            policy: ReentryPolicy()
        )
    }

    public func project(
        lastSeen: Date,
        now: Date,
        changes: [ReentryMaterialChange],
        opportunities: [ReentryOpportunity],
        policy: ReentryPolicy
    ) throws -> ReentrySurface {
        guard try shouldEnter(lastSeen: lastSeen, now: now, policy: policy) else {
            throw ReentryError.invalidPolicy
        }
        let eligible = changes.filter {
            $0.occurredAt > lastSeen
                && $0.occurredAt <= now
                && $0.isMaterial
                && $0.isCurrentlyRelevant
                && $0.relevance >= policy.minimumMaterialRelevance
        }.sorted(by: rankChanges)
        let summary = eligible.prefix(policy.maximumSummaryItems).map {
            ReentrySummaryItem(
                changeID: $0.id,
                summary: $0.summary,
                sourceReferences: $0.sourceReferences
            )
        }
        let unresolved = eligible.filter {
            $0.isUnresolved && $0.clarificationQuestion != nil
        }.sorted {
            if $0.clarificationValue != $1.clarificationValue {
                return $0.clarificationValue > $1.clarificationValue
            }
            return rankChanges($0, $1)
        }
        let question = unresolved.first?.clarificationQuestion
        let expired = opportunities.filter {
            $0.isActive && $0.expiresAt <= now
        }.map(\.id).sorted { $0.description < $1.description }
        var reasons: [ReentryReason] = [.absenceThresholdMet]
        reasons.append(summary.isEmpty
            ? .noCurrentMaterialChange
            : .materialChangesSummarized)
        if !expired.isEmpty { reasons.append(.staleOpportunitiesExpired) }
        if question != nil { reasons.append(.oneClarificationSelected) }
        return ReentrySurface(
            summary: summary,
            oneQuestion: question,
            options: [.continue, .reviseSeason, .stayQuiet],
            expiredOpportunityIDs: expired,
            suppressBacklog: true,
            noAbsencePenalty: true,
            reasons: reasons,
            policyVersion: policy.policyVersion
        )
    }

    private func rankChanges(
        _ left: ReentryMaterialChange,
        _ right: ReentryMaterialChange
    ) -> Bool {
        if left.relevance != right.relevance { return left.relevance > right.relevance }
        if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
        return left.id.description < right.id.description
    }
}
