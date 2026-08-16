import Foundation
import OdysseyApplication
import OdysseyDomain
import Testing

@Test
func captureImportBufferCopiesOpaqueProtectedBytesAndDiscardsThem() throws {
    let directory = captureImportTemporaryDirectory("copy")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceURL = directory.appendingPathComponent(
        "owner-selected-name-should-not-persist.jpeg",
        isDirectory: false
    )
    let content = Data("synthetic selected photo".utf8)
    try content.write(to: sourceURL)
    let root = directory.appendingPathComponent("Imports", isDirectory: true)
    let importID = try captureImportIdentifier(1)
    let buffer = try LocalCaptureImportBuffer(
        configuration: LocalCaptureImportBufferConfiguration(rootDirectory: root),
        identifier: { importID }
    )

    let prepared = try buffer.prepareFile(at: sourceURL)

    #expect(prepared.importID == importID)
    #expect(prepared.fileURL.lastPathComponent == importID.description)
    #expect(prepared.byteCount == Int64(content.count))
    #expect(try Data(contentsOf: prepared.fileURL) == content)
    #expect(!prepared.fileURL.path.contains("owner-selected-name"))
    #expect(try captureImportPermissionBits(at: root) == 0o700)
    #expect(try captureImportPermissionBits(at: prepared.fileURL) == 0o600)
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))

    try buffer.discard(prepared)
    #expect(!FileManager.default.fileExists(atPath: prepared.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
}

@Test
func captureImportBufferRejectsUnsafeOrOversizedSourcesWithoutResidue() throws {
    let directory = captureImportTemporaryDirectory("validation")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let root = directory.appendingPathComponent("Imports", isDirectory: true)
    let buffer = try LocalCaptureImportBuffer(
        configuration: LocalCaptureImportBufferConfiguration(
            rootDirectory: root,
            maximumBytes: 4
        ),
        identifier: { try! captureImportIdentifier(2) }
    )
    let emptyURL = directory.appendingPathComponent("empty.bin")
    let oversizedURL = directory.appendingPathComponent("oversized.bin")
    let sourceURL = directory.appendingPathComponent("source.bin")
    let symlinkURL = directory.appendingPathComponent("source-link.bin")
    try Data().write(to: emptyURL)
    try Data("12345".utf8).write(to: oversizedURL)
    try Data("1234".utf8).write(to: sourceURL)
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: sourceURL)

    #expect(throws: LocalCaptureImportBufferError.emptyImport) {
        try buffer.prepareFile(at: emptyURL)
    }
    #expect(throws: LocalCaptureImportBufferError.importTooLarge(maximumBytes: 4)) {
        try buffer.prepareFile(at: oversizedURL)
    }
    #expect(throws: LocalCaptureImportBufferError.sourceUnavailable) {
        try buffer.prepareFile(at: symlinkURL)
    }
    #expect(throws: LocalCaptureImportBufferError.sourceUnavailable) {
        try buffer.prepareFile(at: URL(string: "https://example.test/file")!)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test
func captureImportBufferClearsOnlyItsAbandonedTemporaryRootOnBootstrap() throws {
    let directory = captureImportTemporaryDirectory("cleanup")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceURL = directory.appendingPathComponent("selected.pdf")
    let outsideURL = directory.appendingPathComponent("outside-owner-file.txt")
    let root = directory.appendingPathComponent("Imports", isDirectory: true)
    try Data("selected".utf8).write(to: sourceURL)
    try Data("outside".utf8).write(to: outsideURL)
    let configuration = try LocalCaptureImportBufferConfiguration(rootDirectory: root)
    let first = try LocalCaptureImportBuffer(
        configuration: configuration,
        identifier: { try! captureImportIdentifier(3) }
    )
    let prepared = try first.prepareFile(at: sourceURL)
    #expect(FileManager.default.fileExists(atPath: prepared.fileURL.path))

    _ = try LocalCaptureImportBuffer(configuration: configuration)

    #expect(!FileManager.default.fileExists(atPath: prepared.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(FileManager.default.fileExists(atPath: outsideURL.path))
}

private func captureImportTemporaryDirectory(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-capture-import-\(suffix)-\(UUID().uuidString)",
        isDirectory: true
    )
}

private func captureImportIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}

private func captureImportPermissionBits(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}
