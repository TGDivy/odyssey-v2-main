import Foundation
@testable import OdysseyApplication
import OdysseyData
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

@Test
func captureInterpretationCommitsDerivativeProjectionAndOutboxAtomically() async throws {
    let fixture = try CaptureInterpretationFixture()
    defer { fixture.remove() }
    let original = try await fixture.captureService.record(.text(
        "Food: oatmeal and berries",
        timeZoneID: "UTC",
        locationPermissionState: .denied,
        invokingSurface: .iPhoneGlobalCapture
    ))

    let execution = try await fixture.interpretationService.interpret(
        captureID: original.capture.metadata.id,
        using: DeterministicCaptureInterpreter()
    )

    guard case let .recorded(receipt) = execution else {
        Issue.record("Expected a durable interpretation")
        return
    }
    #expect(receipt.capture.metadata.revision == 2)
    #expect(receipt.capture.originalPayload == original.capture.originalPayload)
    #expect(receipt.capture.interpretationStatus == .interpreted)
    #expect(receipt.capture.interpretationVersions == [receipt.interpretation])
    #expect(receipt.deviceSequence == 2)

    let storedProjection = try fixture.store.projectedEntity(
        entityType: ManualCaptureService.entityType,
        entityID: original.capture.metadata.id
    )
    let projection = try #require(storedProjection)
    let projectedCapture = try SyncJSONCoding.makeDecoder().decode(
        CaptureRecord.self,
        from: projection.document
    )
    let entries = try fixture.store.storedEntries()
    let pending = try await fixture.store.pendingSyncOperations()
    #expect(projectedCapture == receipt.capture)
    #expect(entries.map(\.entry.eventType) == [
        ManualCaptureService.eventType,
        CaptureInterpretationService.eventType,
    ])
    #expect(pending.count == 2)
    #expect(pending[1].mutationType == .update)
    #expect(pending[1].baseRevision == 1)
    #expect(pending[1].payload == projection.document)
    #expect(try await fixture.interpretationService.pendingCaptureIDs().isEmpty)

    let repeated = try await fixture.interpretationService.interpret(
        captureID: original.capture.metadata.id,
        using: DeterministicCaptureInterpreter()
    )
    #expect(repeated == .alreadyRecorded(receipt.interpretation))
    #expect(try fixture.store.storedEntries().count == 2)
}

@Test
func captureInterpretationDeferralRemainsPendingForRestartRecovery() async throws {
    let fixture = try CaptureInterpretationFixture()
    defer { fixture.remove() }
    let original = try await fixture.captureService.record(ManualCaptureDraft(
        kind: .audio,
        contentOrObjectReference: "attachments/local-audio.m4a",
        timeZoneID: "UTC",
        locationPermissionState: .denied,
        invokingSurface: .iPhoneGlobalCapture
    ))

    let before = try await fixture.interpretationService.pendingCaptureIDs()
    let execution = try await fixture.interpretationService.interpret(
        captureID: original.capture.metadata.id,
        using: DeterministicCaptureInterpreter()
    )
    let after = try await fixture.interpretationService.pendingCaptureIDs()

    #expect(before == [original.capture.metadata.id])
    #expect(execution == .deferred(.mediaContentUnavailable))
    #expect(after == before)
    #expect(try fixture.store.storedEntries().count == 1)
    #expect(try await fixture.store.pendingSyncOperations().count == 1)
}

@Test
func captureInterpretationRejectsForeignSourcesWithoutPartialMutation() async throws {
    let fixture = try CaptureInterpretationFixture()
    defer { fixture.remove() }
    let original = try await fixture.captureService.record(.text(
        "Food: synthetic meal",
        timeZoneID: "UTC",
        locationPermissionState: .denied,
        invokingSurface: .iPhoneGlobalCapture
    ))
    let foreignReference = "capture:018f0000-0000-7000-8000-000000000999#original_payload"

    await #expect(
        throws: CaptureInterpretationServiceError.foreignSourceReference(foreignReference)
    ) {
        try await fixture.interpretationService.interpret(
            captureID: original.capture.metadata.id,
            using: ForeignSourceCaptureInterpreter(sourceReference: foreignReference)
        )
    }

    let storedProjection = try fixture.store.projectedEntity(
        entityType: ManualCaptureService.entityType,
        entityID: original.capture.metadata.id
    )
    let projection = try #require(storedProjection)
    #expect(projection.revision == 1)
    #expect(try fixture.store.storedEntries().count == 1)
    #expect(try await fixture.store.pendingSyncOperations().count == 1)
}

@Test
func captureInterpretationCoalescesConcurrentAdapterExecution() async throws {
    let fixture = try CaptureInterpretationFixture()
    defer { fixture.remove() }
    let original = try await fixture.captureService.record(.text(
        "Decision: choose a bounded next step",
        timeZoneID: "UTC",
        locationPermissionState: .denied,
        invokingSurface: .iPhoneGlobalCapture
    ))
    let counter = CaptureInterpretationCallCounter()
    let interpreter = CountingCaptureInterpreter(counter: counter)

    async let first = fixture.interpretationService.interpret(
        captureID: original.capture.metadata.id,
        using: interpreter
    )
    async let second = fixture.interpretationService.interpret(
        captureID: original.capture.metadata.id,
        using: interpreter
    )
    let results = try await (first, second)

    #expect(results.0 == results.1)
    #expect(await counter.value() == 1)
    #expect(try fixture.store.storedEntries().count == 2)
    #expect(try await fixture.store.pendingSyncOperations().count == 2)
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

private struct ForeignSourceCaptureInterpreter: CaptureInterpreting {
    let interpreterID = "odyssey.foreign-source-test"
    let interpreterVersion = "1"
    let sourceReference: String

    func interpret(_ input: CaptureInterpretationInput) async throws
        -> CaptureInterpretationAttempt
    {
        try .proposed(CaptureInterpretationProposal(
            status: .interpreted,
            proposedFields: [
                "capture_type": CaptureInterpretedField(
                    value: .string("food"),
                    sourceSpanRefs: [sourceReference]
                ),
            ]
        ))
    }
}

private struct CountingCaptureInterpreter: CaptureInterpreting {
    let interpreterID = "odyssey.counting-test"
    let interpreterVersion = "1"
    let counter: CaptureInterpretationCallCounter

    func interpret(_ input: CaptureInterpretationInput) async throws
        -> CaptureInterpretationAttempt
    {
        await counter.increment()
        try await Task.sleep(for: .milliseconds(25))
        return try await DeterministicCaptureInterpreter().interpret(input)
    }
}

private actor CaptureInterpretationCallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private final class CaptureInterpretationFixture: @unchecked Sendable {
    let directory: URL
    let store: SQLiteLedgerStore
    let captureService: ManualCaptureService
    let interpretationService: CaptureInterpretationService

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-capture-interpretation-\(UUID().uuidString)",
            isDirectory: true
        )
        let deviceID = try captureInterpretationIdentifier(100)
        store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: deviceID,
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { captureInterpretationDate }
        ))
        let identifiers = CaptureInterpretationIdentifiers()
        captureService = try ManualCaptureService(
            store: store,
            deviceID: deviceID,
            clock: { captureInterpretationDate },
            identifier: identifiers.next
        )
        interpretationService = CaptureInterpretationService(
            store: store,
            clock: { captureInterpretationDate.addingTimeInterval(60) },
            identifier: identifiers.next
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class CaptureInterpretationIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 200

    func next() -> UUIDv7 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return try! captureInterpretationIdentifier(value)
    }
}
