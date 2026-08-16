import Foundation
import OdysseyIntelligence

public enum NowWidgetSnapshotStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidSnapshot
    case payloadTooLarge(maximumBytes: Int)
}

public final class NowWidgetSnapshotStore: @unchecked Sendable {
    public static let widgetKind = "OdysseyNowWidget"
    public static let maximumPayloadBytes = 16 * 1_024

    private let fileManager: FileManager
    private let snapshotURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard rootDirectory.isFileURL else {
            throw NowWidgetSnapshotStoreError.invalidRoot
        }
        self.fileManager = fileManager
        let directory = rootDirectory
            .appendingPathComponent("NowWidgetSnapshot", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        snapshotURL = directory.appendingPathComponent("current.json")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: attributes
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(resourceValues)
    }

    public func read() throws -> NowWidgetSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
        let data = try Data(contentsOf: snapshotURL, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw NowWidgetSnapshotStoreError.invalidSnapshot }
        guard data.count <= Self.maximumPayloadBytes else {
            throw NowWidgetSnapshotStoreError.payloadTooLarge(
                maximumBytes: Self.maximumPayloadBytes
            )
        }
        do {
            return try decoder.decode(NowWidgetSnapshot.self, from: data)
        } catch let error as NowWidgetSnapshotStoreError {
            throw error
        } catch {
            throw NowWidgetSnapshotStoreError.invalidSnapshot
        }
    }

    public func write(_ snapshot: NowWidgetSnapshot) throws {
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumPayloadBytes else {
            throw NowWidgetSnapshotStoreError.payloadTooLarge(
                maximumBytes: Self.maximumPayloadBytes
            )
        }
        try data.write(to: snapshotURL, options: .atomic)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try fileManager.setAttributes(attributes, ofItemAtPath: snapshotURL.path)
    }

    @discardableResult
    public func remove() throws -> Bool {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return false }
        try fileManager.removeItem(at: snapshotURL)
        return true
    }
}
