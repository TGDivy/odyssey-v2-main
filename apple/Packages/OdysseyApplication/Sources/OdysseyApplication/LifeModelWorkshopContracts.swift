import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public enum LifeModelWorkshopError: Error, Equatable, Sendable {
    case invalidDraft(String)
    case draftNotFound(UUIDv7)
    case staleDraft(expectedRevision: Int, actualRevision: Int)
    case reviewRequired
    case reviewChanged
    case noSemanticChanges
    case openDraftAlreadyExists(LifeModelKind)
    case acceptedVersionUnavailable(UUIDv7)
}

extension LifeModelWorkshopError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidDraft(message):
            message
        case .draftNotFound:
            "The selected Workshop draft no longer exists."
        case let .staleDraft(expectedRevision, actualRevision):
            "This draft changed from revision \(expectedRevision) to \(actualRevision); review the latest version."
        case .reviewRequired:
            "Review the complete semantic change before accepting it."
        case .reviewChanged:
            "The reviewed draft changed. Open review again before accepting it."
        case .noSemanticChanges:
            "This revision does not change the accepted life model."
        case .openDraftAlreadyExists:
            "Finish or abandon the existing draft of this kind first."
        case .acceptedVersionUnavailable:
            "The accepted base version is not available in the immutable local history cache."
        }
    }
}

public enum LifeModelDraftPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case editing
    case reviewed
    case queued
    case abandoned
}

public struct LifeModelDraftProposal: Hashable, Sendable {
    public let kind: LifeModelKind
    public let versionID: UUIDv7
    public let logicalID: UUIDv7
    public let versionNumber: Int
    public let baseVersionID: UUIDv7?
    public let acceptanceMethod: LifeModelAcceptanceMethod
    public let document: [String: JSONValue]

    public init(
        kind: LifeModelKind,
        versionID: UUIDv7,
        logicalID: UUIDv7,
        versionNumber: Int,
        baseVersionID: UUIDv7?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        document: [String: JSONValue]
    ) throws {
        guard versionNumber >= 1,
              !document.isEmpty,
              ((try? SyncJSONCoding.makeEncoder().encode(document).count) ?? 0)
                <= 768 * 1_024
        else {
            throw LifeModelWorkshopError.invalidDraft(
                "A Workshop draft requires a positive version and a bounded JSON document."
            )
        }
        self.kind = kind
        self.versionID = versionID
        self.logicalID = logicalID
        self.versionNumber = versionNumber
        self.baseVersionID = baseVersionID
        self.acceptanceMethod = acceptanceMethod
        self.document = document
    }
}

public struct LifeModelDraftRecord: Codable, Hashable, Sendable {
    public let draftID: UUIDv7
    public let kind: LifeModelKind
    public let versionID: UUIDv7
    public let logicalID: UUIDv7
    public let versionNumber: Int
    public let baseVersionID: UUIDv7?
    public let acceptanceMethod: LifeModelAcceptanceMethod
    public let document: [String: JSONValue]
    public let documentSHA256: String
    public let contentRevision: Int
    public let stateRevision: Int
    public let phase: LifeModelDraftPhase
    public let reviewedDocumentSHA256: String?
    public let reviewedAt: Date?
    public let queuedEventID: UUIDv7?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        draftID: UUIDv7,
        kind: LifeModelKind,
        versionID: UUIDv7,
        logicalID: UUIDv7,
        versionNumber: Int,
        baseVersionID: UUIDv7?,
        acceptanceMethod: LifeModelAcceptanceMethod,
        document: [String: JSONValue],
        contentRevision: Int,
        stateRevision: Int,
        phase: LifeModelDraftPhase,
        reviewedDocumentSHA256: String? = nil,
        reviewedAt: Date? = nil,
        queuedEventID: UUIDv7? = nil,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let encoded = try SyncJSONCoding.makeEncoder().encode(document)
        let hash = SHA256Digest.hexDigest(of: encoded)
        let reviewStateIsValid: Bool
        switch phase {
        case .editing, .abandoned:
            reviewStateIsValid = reviewedDocumentSHA256 == nil
                && reviewedAt == nil
                && queuedEventID == nil
        case .reviewed:
            reviewStateIsValid = reviewedDocumentSHA256 == hash
                && reviewedAt != nil
                && queuedEventID == nil
        case .queued:
            reviewStateIsValid = reviewedDocumentSHA256 == hash
                && reviewedAt != nil
                && queuedEventID != nil
        }
        guard versionNumber >= 1,
              contentRevision >= 1,
              stateRevision >= contentRevision,
              !document.isEmpty,
              encoded.count <= 768 * 1_024,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              (reviewedAt?.timeIntervalSinceReferenceDate.isFinite ?? true),
              updatedAt >= createdAt,
              reviewStateIsValid
        else {
            throw LifeModelWorkshopError.invalidDraft(
                "The Workshop draft has inconsistent version, review, or queue metadata."
            )
        }
        self.draftID = draftID
        self.kind = kind
        self.versionID = versionID
        self.logicalID = logicalID
        self.versionNumber = versionNumber
        self.baseVersionID = baseVersionID
        self.acceptanceMethod = acceptanceMethod
        self.document = document
        documentSHA256 = hash
        self.contentRevision = contentRevision
        self.stateRevision = stateRevision
        self.phase = phase
        self.reviewedDocumentSHA256 = reviewedDocumentSHA256
        self.reviewedAt = reviewedAt
        self.queuedEventID = queuedEventID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validated() throws -> Self {
        let validated = try Self(
            draftID: draftID,
            kind: kind,
            versionID: versionID,
            logicalID: logicalID,
            versionNumber: versionNumber,
            baseVersionID: baseVersionID,
            acceptanceMethod: acceptanceMethod,
            document: document,
            contentRevision: contentRevision,
            stateRevision: stateRevision,
            phase: phase,
            reviewedDocumentSHA256: reviewedDocumentSHA256,
            reviewedAt: reviewedAt,
            queuedEventID: queuedEventID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        guard validated.documentSHA256 == documentSHA256 else {
            throw LifeModelWorkshopError.invalidDraft(
                "The Workshop draft document hash does not match its content."
            )
        }
        return validated
    }
}

public enum LifeModelSemanticChangeKind: String, Codable, Hashable, Sendable {
    case added
    case removed
    case changed
}

public struct LifeModelSemanticChange: Codable, Hashable, Sendable {
    public let path: String
    public let label: String
    public let kind: LifeModelSemanticChangeKind
    public let before: String?
    public let after: String?

    public init(
        path: String,
        label: String,
        kind: LifeModelSemanticChangeKind,
        before: String?,
        after: String?
    ) {
        self.path = path
        self.label = label
        self.kind = kind
        self.before = before
        self.after = after
    }
}

public struct LifeModelDraftReview: Codable, Hashable, Sendable {
    public let draft: LifeModelDraftRecord
    public let changes: [LifeModelSemanticChange]
    public let warnings: [String]
    public let reviewDigest: String

    public init(
        draft: LifeModelDraftRecord,
        changes: [LifeModelSemanticChange],
        warnings: [String],
        reviewDigest: String
    ) {
        self.draft = draft
        self.changes = changes
        self.warnings = warnings
        self.reviewDigest = reviewDigest
    }
}

public struct LifeModelWorkshopSnapshot: Codable, Hashable, Sendable {
    public let drafts: [LifeModelDraftRecord]
    public let acceptanceCommands: [StoredLifeModelAcceptance]
    public let acceptedVersions: [CachedLifeModelVersion]
    public let queueDiagnostics: LifeModelQueueDiagnostics

    public init(
        drafts: [LifeModelDraftRecord],
        acceptanceCommands: [StoredLifeModelAcceptance],
        acceptedVersions: [CachedLifeModelVersion],
        queueDiagnostics: LifeModelQueueDiagnostics
    ) {
        self.drafts = drafts
        self.acceptanceCommands = acceptanceCommands
        self.acceptedVersions = acceptedVersions
        self.queueDiagnostics = queueDiagnostics
    }
}

public enum LifeModelSemanticDiffer {
    public static func changes(
        from before: [String: JSONValue]?,
        to after: [String: JSONValue]
    ) -> [LifeModelSemanticChange] {
        diff(
            before: before.map(JSONValue.object),
            after: .object(after),
            path: []
        ).sorted {
            if $0.label == $1.label {
                return $0.path < $1.path
            }
            return $0.label < $1.label
        }
    }

    private static func diff(
        before: JSONValue?,
        after: JSONValue?,
        path: [String]
    ) -> [LifeModelSemanticChange] {
        if shouldIgnore(path) || before == after {
            return []
        }
        if before == nil || before == .null,
           case let .object(afterObject)? = after
        {
            return afterObject.keys.sorted().flatMap {
                diff(before: nil, after: afterObject[$0], path: path + [$0])
            }
        }
        if after == nil || after == .null,
           case let .object(beforeObject)? = before
        {
            return beforeObject.keys.sorted().flatMap {
                diff(before: beforeObject[$0], after: nil, path: path + [$0])
            }
        }
        if case let .object(beforeObject)? = before,
           case let .object(afterObject)? = after
        {
            let keys = Set(beforeObject.keys).union(afterObject.keys).sorted()
            return keys.flatMap {
                diff(
                    before: beforeObject[$0],
                    after: afterObject[$0],
                    path: path + [$0]
                )
            }
        }
        let kind: LifeModelSemanticChangeKind
        if before == nil || before == .null {
            kind = .added
        } else if after == nil || after == .null {
            kind = .removed
        } else {
            kind = .changed
        }
        let renderedPath = path.joined(separator: ".")
        return [
            LifeModelSemanticChange(
                path: renderedPath,
                label: label(for: path),
                kind: kind,
                before: summary(before, path: path),
                after: summary(after, path: path)
            ),
        ]
    }

    private static func shouldIgnore(_ path: [String]) -> Bool {
        if path.first == "metadata" {
            return true
        }
        guard path.count == 1, let key = path.first else { return false }
        return [
            "accepted_at",
            "charter_id",
            "charter_revision_id",
            "stage_id",
            "supersedes_season_id",
            "supersedes_version_id",
            "version_number",
        ].contains(key)
    }

    private static func label(for path: [String]) -> String {
        let key = path.last ?? "Life model"
        let labels = [
            "accepted_at": "Acceptance time",
            "anti_optimization_statements": "Must-never-optimize statements",
            "care_responsibilities": "Care responsibilities",
            "career_context": "Career context",
            "constraints": "Constraints",
            "created_from": "Creation source",
            "desired_ways_of_being": "Desired ways of being",
            "effective_interval": "Effective interval",
            "explicit_non_goals": "Not-now areas",
            "failure_guardrails": "Failure guardrails",
            "financial_context": "Financial context",
            "geography_context": "Geography context",
            "good_week_description": "What a good week feels like",
            "health_capability_context": "Health and capability context",
            "horizons": "Major horizons",
            "identity_transitions": "Identity transitions",
            "interpretation_notes": "Interpretation notes",
            "known_tradeoffs": "Known trade-offs",
            "non_negotiable_boundaries": "Non-negotiable boundaries",
            "opportunity_budgets": "Opportunity budgets",
            "outgoing_summary": "Frozen outgoing-season summary",
            "partnership_family_context": "Partnership and family context",
            "people_and_experiences_that_mattered": "People and experiences that mattered",
            "portfolio_items": "Season portfolio",
            "practices_to_carry_forward": "Practices to carry forward",
            "progress_signals": "Progress signals",
            "protected_experiences": "Protected experiences",
            "rationale": "Rationale",
            "retrospective": "Optional retrospective",
            "responsibilities": "Responsibilities",
            "review_cadence": "Review cadence",
            "status": "Status",
            "title": "Title",
            "transition_notes": "Transition notes",
            "transition_triggers": "Transition triggers",
            "triggering_context": "Triggering context",
            "uncertainties": "Uncertainties",
            "values": "Chosen values",
        ]
        if let label = labels[key] {
            return label
        }
        return key
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func summary(
        _ value: JSONValue?,
        path: [String]
    ) -> String? {
        guard let value, value != .null else { return nil }
        if path.last?.hasSuffix("_id") == true || path.last == "id" {
            return "Accepted reference"
        }
        switch value {
        case let .string(string):
            return bounded(string)
        case let .number(number):
            return number.formatted(.number.precision(.fractionLength(0 ... 3)))
        case let .bool(boolean):
            return boolean ? "Yes" : "No"
        case let .array(values):
            let rendered = values.prefix(3).compactMap { summary($0, path: path) }
            if rendered.isEmpty {
                return values.isEmpty ? "None" : "\(values.count) items"
            }
            let suffix = values.count > rendered.count ? ", and more" : ""
            return bounded(rendered.joined(separator: ", ") + suffix)
        case .object:
            return "Updated details"
        case .null:
            return nil
        }
    }

    private static func bounded(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= 160 {
            return normalized
        }
        return String(normalized.prefix(157)) + "…"
    }
}
