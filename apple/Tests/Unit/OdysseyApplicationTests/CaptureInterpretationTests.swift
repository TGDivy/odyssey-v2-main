import Foundation
@testable import OdysseyApplication
import OdysseyDomain
import OdysseySync
import Testing

private let captureInterpretationDate = Date(timeIntervalSince1970: 1_786_752_000)

@Test
func deterministicCaptureInterpreterUsesOnlyExplicitSourceLinkedLabels() async throws {
    let input = try captureInterpretationInput(
        kind: .text,
        content: "Food: oatmeal and berries"
    )
    let interpreter = DeterministicCaptureInterpreter()

    let attempt = try await interpreter.interpret(input)

    guard case let .proposed(proposal) = attempt else {
        Issue.record("Expected a deterministic proposal")
        return
    }
    #expect(proposal.status == .interpreted)
    #expect(proposal.proposedFields["capture_type"]?.value == .string("food"))
    #expect(proposal.proposedFields["requires_owner_review"]?.value == .bool(true))
    let expectedReference = "capture:\(input.captureID)#original_payload"
    #expect(proposal.proposedFields.values.allSatisfy {
        $0.sourceSpanRefs == [expectedReference]
    })
}

@Test
func deterministicCaptureInterpreterDoesNotGuessAtUnlabeledTextOrUnavailableMedia() async throws {
    let interpreter = DeterministicCaptureInterpreter()
    let note = try await interpreter.interpret(captureInterpretationInput(
        kind: .text,
        content: "A quiet unstructured thought"
    ))
    let audio = try await interpreter.interpret(captureInterpretationInput(
        kind: .audio,
        content: "attachments/local-audio.m4a"
    ))

    guard case let .proposed(noteProposal) = note else {
        Issue.record("Expected an unstructured note proposal")
        return
    }
    #expect(noteProposal.proposedFields["capture_type"]?.value == .string("note"))
    #expect(noteProposal.proposedFields["requires_owner_review"]?.value == .bool(false))
    #expect(audio == .deferred(.mediaContentUnavailable))
}

@Test
func captureInterpretationVersionRoundTripsFullBackendShapedContent() throws {
    let sourceReference = "capture:018f0000-0000-7000-8000-000000000001#original_payload"
    let version = try CaptureInterpretationVersion(
        id: captureInterpretationIdentifier(2),
        interpreter: "odyssey.explicit-prefix",
        interpreterVersion: "1",
        createdAt: captureInterpretationDate,
        status: .interpreted,
        proposedFields: [
            "capture_type": try CaptureInterpretedField(
                value: .string("food"),
                sourceSpanRefs: [sourceReference]
            ),
        ]
    )

    let encoded = try SyncJSONCoding.makeEncoder().encode(version)
    let decoded = try SyncJSONCoding.makeDecoder().decode(
        CaptureInterpretationVersion.self,
        from: encoded
    )
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(decoded == version)
    #expect(version.sourceSpanRefs == [sourceReference])
    #expect(object["interpreter_version"] as? String == "1")
    #expect(object["proposed_fields"] as? [String: Any] != nil)
}

@Test
func captureInterpretationVersionRejectsTransientOrUnlinkedResults() throws {
    #expect(throws: CaptureContractError.invalidInterpretation("status")) {
        try CaptureInterpretationVersion(
            interpreter: "odyssey.test",
            interpreterVersion: "1",
            createdAt: captureInterpretationDate,
            status: .processing
        )
    }
    #expect(throws: CaptureContractError.invalidInterpretation("field source references")) {
        try CaptureInterpretedField(value: .string("food"), sourceSpanRefs: [])
    }
}

private func captureInterpretationInput(
    kind: CapturePayloadKind,
    content: String
) throws -> CaptureInterpretationInput {
    CaptureInterpretationInput(
        captureID: try captureInterpretationIdentifier(1),
        capturedAt: captureInterpretationDate,
        originalPayload: CaptureOriginalPayload(
            kind: kind,
            contentOrObjectRef: content,
            contentHash: String(repeating: "a", count: 64)
        ),
        initialContext: CaptureInitialContext(
            deviceID: try captureInterpretationIdentifier(3),
            timeZoneID: "UTC",
            locationPermissionState: .denied,
            broadLocation: nil,
            invokingSurface: .iPhoneGlobalCapture
        ),
        attachments: []
    )
}

private func captureInterpretationIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
