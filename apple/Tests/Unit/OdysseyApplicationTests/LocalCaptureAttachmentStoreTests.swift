import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import Testing

private let attachmentStoreDate = Date(timeIntervalSince1970: 1_735_689_600)

@Test
func protectedAttachmentStoreCopiesOpaqueContentAndVerifiesCommittedBytes() async throws {
    let directory = attachmentStoreTemporaryDirectory("durability")
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent(
        "source-name-should-not-persist.m4a",
        isDirectory: false
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = Data("synthetic audio bytes".utf8)
    try original.write(to: sourceURL)
    let attachmentID = try attachmentStoreIdentifier(1)
    let root = directory.appendingPathComponent("Attachments", isDirectory: true)
    let configuration = try LocalCaptureAttachmentStoreConfiguration(rootDirectory: root)
    let store = try LocalCaptureAttachmentStore(
        configuration: configuration,
        clock: { attachmentStoreDate },
        identifier: { attachmentID }
    )

    let staged = try await store.stageFile(
        at: sourceURL,
        kind: .audio,
        mediaType: "audio/mp4"
    )
    try FileManager.default.removeItem(at: sourceURL)

    #expect(staged.state == .staged)
    #expect(staged.retention == .localOnly)
    #expect(staged.byteCount == Int64(original.count))
    #expect(staged.contentHash == SHA256Digest.hexDigest(of: original))
    #expect(staged.objectReference == "odyssey-attachment:v1:\(attachmentID)")
    #expect(!staged.objectReference.contains(directory.path))
    await #expect(throws: LocalCaptureAttachmentError.integrityFailure) {
        try await store.verifiedContentURL(for: staged.captureReference)
    }

    let committed = try await store.markCommitted(attachmentID)
    let contentURL = try await store.verifiedContentURL(for: committed.captureReference)
    #expect(try Data(contentsOf: contentURL) == original)
    #expect(try permissionBits(at: contentURL) == 0o600)
    #expect(try permissionBits(at: contentURL.deletingLastPathComponent()) == 0o700)
    let manifestData = try Data(contentsOf: contentURL.deletingLastPathComponent()
        .appendingPathComponent("manifest.json"))
    let manifestText = try #require(String(data: manifestData, encoding: .utf8))
    #expect(!manifestText.contains("source-name-should-not-persist"))
    #expect(!manifestText.contains(directory.path))

    let reopened = try LocalCaptureAttachmentStore(configuration: configuration)
    #expect(try await reopened.manifests() == [committed])
    await #expect(throws: LocalCaptureAttachmentError.committedAttachmentCannotBeDiscarded) {
        try await reopened.discardStaged(attachmentID)
    }
}

@Test
func protectedAttachmentStoreRejectsUnsafeInputsAndDetectsTampering() async throws {
    let directory = attachmentStoreTemporaryDirectory("validation")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("Attachments", isDirectory: true)
    let store = try LocalCaptureAttachmentStore(
        configuration: LocalCaptureAttachmentStoreConfiguration(
            rootDirectory: root,
            maximumBytes: 4
        ),
        clock: { attachmentStoreDate },
        identifier: { try! attachmentStoreIdentifier(2) }
    )

    await #expect(throws: LocalCaptureAttachmentError.emptyAttachment) {
        try await store.stageData(Data(), kind: .audio, mediaType: "audio/mp4")
    }
    await #expect(throws: LocalCaptureAttachmentError.attachmentTooLarge(maximumBytes: 4)) {
        try await store.stageData(
            Data("12345".utf8),
            kind: .audio,
            mediaType: "audio/mp4"
        )
    }
    await #expect(throws: LocalCaptureAttachmentError.unsupportedKind) {
        try await store.stageData(Data("1234".utf8), kind: .text, mediaType: "text/plain")
    }
    await #expect(throws: LocalCaptureAttachmentError.invalidMediaType) {
        try await store.stageData(Data("1234".utf8), kind: .audio, mediaType: "Audio/MP4")
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("source.bin")
    let symlink = directory.appendingPathComponent("source-link.bin")
    try Data("1234".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    await #expect(throws: LocalCaptureAttachmentError.sourceUnavailable) {
        try await store.stageFile(at: symlink, kind: .audio, mediaType: "audio/mp4")
    }

    let staged = try await store.stageData(
        Data("good".utf8),
        kind: .audio,
        mediaType: "audio/mp4"
    )
    let committed = try await store.markCommitted(staged.attachmentID)
    let contentURL = try await store.verifiedContentURL(for: committed.captureReference)
    try Data("evil".utf8).write(to: contentURL)
    await #expect(throws: LocalCaptureAttachmentError.integrityFailure) {
        try await store.verifiedContentURL(for: committed.captureReference)
    }
}

@Test
func protectedAttachmentStoreReconcilesOnlyOpaqueLocalStagingReferences() async throws {
    let directory = attachmentStoreTemporaryDirectory("recovery")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("Attachments", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".staging-abandoned", isDirectory: true),
        withIntermediateDirectories: true
    )
    let identifiers = AttachmentStoreIdentifiers(startingAt: 20)
    let store = try LocalCaptureAttachmentStore(
        configuration: LocalCaptureAttachmentStoreConfiguration(rootDirectory: root),
        clock: { attachmentStoreDate },
        identifier: { identifiers.next() }
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".staging-abandoned").path
        )
    )
    let referenced = try await store.stageData(
        Data("first".utf8),
        kind: .imageReference,
        mediaType: "image/jpeg"
    )
    let abandoned = try await store.stageData(
        Data("second".utf8),
        kind: .fileReference,
        mediaType: "application/pdf"
    )
    let missingID = try attachmentStoreIdentifier(99)
    let report = try await store.reconcile(referencedObjectReferences: [
        referenced.objectReference,
        LocalCaptureAttachmentManifest.objectReference(for: missingID),
        "https://objects.example.test/external",
    ])

    #expect(report.stagedAttachmentsCommitted == 1)
    #expect(report.stagedAttachmentsDiscarded == 1)
    #expect(report.missingReferencedAttachments == 1)
    #expect(try await store.manifest(for: referenced.attachmentID).state == .committed)
    await #expect(throws: LocalCaptureAttachmentError.attachmentNotFound) {
        try await store.manifest(for: abandoned.attachmentID)
    }
}

private func attachmentStoreTemporaryDirectory(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-attachment-store-\(suffix)-\(UUID().uuidString)",
        isDirectory: true
    )
}

private func attachmentStoreIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}

private func permissionBits(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}

private final class AttachmentStoreIdentifiers: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(startingAt value: Int) {
        self.value = value
    }

    func next() -> UUIDv7 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return try! attachmentStoreIdentifier(value)
    }
}
