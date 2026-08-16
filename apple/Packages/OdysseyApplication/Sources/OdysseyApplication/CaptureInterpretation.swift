import Foundation
import OdysseyDomain
import OdysseySync

public enum CaptureInterpretationReviewDisposition: String, Codable, CaseIterable, Hashable,
    Sendable
{
    case accepted
    case corrected
    case dismissed
}

public struct CaptureInterpretedField: Codable, Hashable, Sendable {
    public static let maximumSourceReferenceCount = 16

    public let value: JSONValue
    public let sourceSpanRefs: [String]

    public init(
        value: JSONValue,
        sourceSpanRefs: [String]
    ) throws {
        guard !sourceSpanRefs.isEmpty,
              sourceSpanRefs.count <= Self.maximumSourceReferenceCount,
              Set(sourceSpanRefs).count == sourceSpanRefs.count,
              sourceSpanRefs.allSatisfy(Self.isValidSourceReference)
        else {
            throw CaptureContractError.invalidInterpretation("field source references")
        }
        self.value = value
        self.sourceSpanRefs = sourceSpanRefs
    }

    private static func isValidSourceReference(_ value: String) -> Bool {
        (1 ... 500).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public struct CaptureInterpretationVersion: Codable, Hashable, Sendable {
    public static let maximumProposedFieldCount = 100

    public let id: UUIDv7
    public let interpreter: String
    public let interpreterVersion: String
    public let createdAt: Date
    public let status: CaptureInterpretationStatus
    public let proposedFields: [String: CaptureInterpretedField]
    public let sourceSpanRefs: [String]
    public let supersedesInterpretationVersionID: UUIDv7?
    public let ownerReviewDisposition: CaptureInterpretationReviewDisposition?
    public let ownerReviewNote: String?

    public init(
        id: UUIDv7 = UUIDv7(),
        interpreter: String,
        interpreterVersion: String,
        createdAt: Date,
        status: CaptureInterpretationStatus,
        proposedFields: [String: CaptureInterpretedField] = [:],
        supersedesInterpretationVersionID: UUIDv7? = nil,
        ownerReviewDisposition: CaptureInterpretationReviewDisposition? = nil,
        ownerReviewNote: String? = nil
    ) throws {
        guard Self.isValidIdentifier(interpreter, maximum: 100) else {
            throw CaptureContractError.invalidInterpretation("interpreter")
        }
        guard Self.isValidIdentifier(interpreterVersion, maximum: 100) else {
            throw CaptureContractError.invalidInterpretation("interpreter version")
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CaptureContractError.invalidInterpretation("creation time")
        }
        guard status == .interpreted || status == .needsClarification || status == .failed
            || status == .dismissed
        else {
            throw CaptureContractError.invalidInterpretation("status")
        }
        guard proposedFields.count <= Self.maximumProposedFieldCount,
              proposedFields.keys.allSatisfy(Self.isValidFieldName)
        else {
            throw CaptureContractError.invalidInterpretation("proposed fields")
        }
        guard status != .failed || proposedFields.isEmpty else {
            throw CaptureContractError.invalidInterpretation("failed result fields")
        }
        if let ownerReviewNote {
            guard (1 ... 500).contains(ownerReviewNote.count),
                  ownerReviewNote == ownerReviewNote.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ),
                  !ownerReviewNote.unicodeScalars.contains(where: { $0.value == 0 })
            else {
                throw CaptureContractError.invalidInterpretation("owner review note")
            }
        }
        if let ownerReviewDisposition {
            guard let supersedesInterpretationVersionID,
                  supersedesInterpretationVersionID != id
            else {
                throw CaptureContractError.invalidInterpretation("owner review lineage")
            }
            switch ownerReviewDisposition {
            case .accepted:
                guard status == .interpreted, !proposedFields.isEmpty else {
                    throw CaptureContractError.invalidInterpretation("accepted review fields")
                }
            case .corrected:
                guard status == .interpreted, !proposedFields.isEmpty else {
                    throw CaptureContractError.invalidInterpretation("corrected review fields")
                }
            case .dismissed:
                guard status == .dismissed, proposedFields.isEmpty else {
                    throw CaptureContractError.invalidInterpretation("dismissed review fields")
                }
            }
        } else {
            guard supersedesInterpretationVersionID == nil,
                  ownerReviewNote == nil,
                  status != .dismissed
            else {
                throw CaptureContractError.invalidInterpretation("owner review metadata")
            }
        }
        let sourceSpanRefs = proposedFields.values
            .flatMap(\.sourceSpanRefs)
            .reduce(into: [String]()) { values, sourceReference in
                if !values.contains(sourceReference) {
                    values.append(sourceReference)
                }
            }
        self.id = id
        self.interpreter = interpreter
        self.interpreterVersion = interpreterVersion
        self.createdAt = createdAt
        self.status = status
        self.proposedFields = proposedFields
        self.sourceSpanRefs = sourceSpanRefs
        self.supersedesInterpretationVersionID = supersedesInterpretationVersionID
        self.ownerReviewDisposition = ownerReviewDisposition
        self.ownerReviewNote = ownerReviewNote
    }

    private static func isValidIdentifier(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "._+-"))
                    .contains($0)
            }
    }

    private static func isValidFieldName(_ value: String) -> Bool {
        (1 ... 100).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "._-"))
                    .contains($0)
            }
    }
}

public struct CaptureInterpretationReviewDraft: Hashable, Sendable {
    public let reviewVersionID: UUIDv7
    public let targetInterpretationVersionID: UUIDv7
    public let expectedCaptureRevision: Int
    public let disposition: CaptureInterpretationReviewDisposition
    public let replacementValues: [String: JSONValue]
    public let note: String?

    public init(
        reviewVersionID: UUIDv7 = UUIDv7(),
        targetInterpretationVersionID: UUIDv7,
        expectedCaptureRevision: Int,
        disposition: CaptureInterpretationReviewDisposition,
        replacementValues: [String: JSONValue] = [:],
        note: String? = nil
    ) throws {
        guard expectedCaptureRevision >= 1 else {
            throw CaptureContractError.invalidInterpretation("review revision")
        }
        guard replacementValues.count <= CaptureInterpretationVersion.maximumProposedFieldCount
        else {
            throw CaptureContractError.invalidInterpretation("review replacement fields")
        }
        switch disposition {
        case .accepted, .dismissed:
            guard replacementValues.isEmpty else {
                throw CaptureContractError.invalidInterpretation("review replacement fields")
            }
        case .corrected:
            guard !replacementValues.isEmpty else {
                throw CaptureContractError.invalidInterpretation("review replacement fields")
            }
        }
        if let note {
            guard (1 ... 500).contains(note.count),
                  note == note.trimmingCharacters(in: .whitespacesAndNewlines),
                  !note.unicodeScalars.contains(where: { $0.value == 0 })
            else {
                throw CaptureContractError.invalidInterpretation("owner review note")
            }
        }
        self.reviewVersionID = reviewVersionID
        self.targetInterpretationVersionID = targetInterpretationVersionID
        self.expectedCaptureRevision = expectedCaptureRevision
        self.disposition = disposition
        self.replacementValues = replacementValues
        self.note = note
    }
}

public struct CaptureInterpretationInput: Hashable, Sendable {
    public let captureID: UUIDv7
    public let capturedAt: Date
    public let originalPayload: CaptureOriginalPayload
    public let initialContext: CaptureInitialContext
    public let attachments: [CaptureAttachmentReference]

    public init(
        captureID: UUIDv7,
        capturedAt: Date,
        originalPayload: CaptureOriginalPayload,
        initialContext: CaptureInitialContext,
        attachments: [CaptureAttachmentReference]
    ) {
        self.captureID = captureID
        self.capturedAt = capturedAt
        self.originalPayload = originalPayload
        self.initialContext = initialContext
        self.attachments = attachments
    }

    public init(capture: CaptureRecord) {
        self.init(
            captureID: capture.metadata.id,
            capturedAt: capture.capturedAt,
            originalPayload: capture.originalPayload,
            initialContext: capture.initialContext,
            attachments: capture.attachments
        )
    }
}

public struct CaptureInterpretationProposal: Hashable, Sendable {
    public let status: CaptureInterpretationStatus
    public let proposedFields: [String: CaptureInterpretedField]

    public init(
        status: CaptureInterpretationStatus,
        proposedFields: [String: CaptureInterpretedField]
    ) throws {
        guard status == .interpreted || status == .needsClarification else {
            throw CaptureContractError.invalidInterpretation("proposal status")
        }
        guard proposedFields.count <= CaptureInterpretationVersion.maximumProposedFieldCount else {
            throw CaptureContractError.invalidInterpretation("proposal fields")
        }
        self.status = status
        self.proposedFields = proposedFields
    }
}

public enum CaptureInterpretationDeferralReason: String, Codable, Hashable, Sendable {
    case mediaContentUnavailable = "media_content_unavailable"
    case unsupportedPayload = "unsupported_payload"
}

public enum CaptureInterpretationAttempt: Hashable, Sendable {
    case proposed(CaptureInterpretationProposal)
    case deferred(CaptureInterpretationDeferralReason)
}

public protocol CaptureInterpreting: Sendable {
    var interpreterID: String { get }
    var interpreterVersion: String { get }

    func interpret(_ input: CaptureInterpretationInput) async throws
        -> CaptureInterpretationAttempt
}

public struct DeterministicCaptureInterpreter: CaptureInterpreting {
    public let interpreterID = "odyssey.explicit-prefix"
    public let interpreterVersion = "1"

    public init() {}

    public func interpret(_ input: CaptureInterpretationInput) async throws
        -> CaptureInterpretationAttempt
    {
        switch input.originalPayload.kind {
        case .text:
            try textInterpretation(input)
        case .structuredQuickAction:
            try proposal(
                captureType: "quick_action",
                input: input,
                explicitOwnerReview: true
            )
        case .audio, .imageReference, .fileReference:
            .deferred(.mediaContentUnavailable)
        }
    }

    private func textInterpretation(
        _ input: CaptureInterpretationInput
    ) throws -> CaptureInterpretationAttempt {
        let text = input.originalPayload.contentOrObjectRef
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = text.lowercased()
        let prefixes: [(String, String)] = [
            ("food:", "food"),
            ("caffeine:", "caffeine"),
            ("alcohol:", "alcohol"),
            ("decision:", "decision"),
            ("commitment:", "commitment"),
            ("observation:", "observation"),
            ("symptom:", "symptom"),
            ("outcome:", "outcome"),
            ("person:", "person_moment"),
            ("idea:", "idea"),
        ]
        if let match = prefixes.first(where: { lowercased.hasPrefix($0.0) }) {
            let body = text.dropFirst(match.0.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                return try proposal(
                    captureType: "note",
                    input: input,
                    explicitOwnerReview: false
                )
            }
            return try proposal(
                captureType: match.1,
                input: input,
                explicitOwnerReview: true
            )
        }
        return try proposal(
            captureType: "note",
            input: input,
            explicitOwnerReview: false
        )
    }

    private func proposal(
        captureType: String,
        input: CaptureInterpretationInput,
        explicitOwnerReview: Bool
    ) throws -> CaptureInterpretationAttempt {
        let sourceReference = "capture:\(input.captureID)#original_payload"
        let fields = [
            "capture_type": try CaptureInterpretedField(
                value: .string(captureType),
                sourceSpanRefs: [sourceReference]
            ),
            "requires_owner_review": try CaptureInterpretedField(
                value: .bool(explicitOwnerReview),
                sourceSpanRefs: [sourceReference]
            ),
        ]
        return try .proposed(CaptureInterpretationProposal(
            status: .interpreted,
            proposedFields: fields
        ))
    }
}
