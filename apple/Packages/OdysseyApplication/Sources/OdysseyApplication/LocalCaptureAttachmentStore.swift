import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public enum LocalCaptureAttachmentError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case unsupportedKind
    case emptyAttachment
    case attachmentTooLarge(maximumBytes: Int64)
    case invalidMediaType
    case invalidClock
    case sourceUnavailable
    case attachmentIdentityConflict
    case attachmentNotFound
    case invalidObjectReference
    case invalidManifest
    case integrityFailure
    case dataProtectionUnavailable
    case committedAttachmentCannotBeDiscarded
}

extension LocalCaptureAttachmentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case .unsupportedKind:
            "Only audio, image, and file attachments can enter protected capture storage."
        case .emptyAttachment:
            "The selected attachment is empty."
        case let .attachmentTooLarge(maximumBytes):
            "The selected attachment exceeds the local \(maximumBytes)-byte limit."
        case .invalidMediaType:
            "The selected attachment has an invalid media type."
        case .invalidClock:
            "The attachment clock is invalid."
        case .sourceUnavailable:
            "The selected attachment is not a readable regular file."
        case .attachmentIdentityConflict:
            "The attachment identity already belongs to another local object."
        case .attachmentNotFound:
            "The protected attachment is not available on this device."
        case .invalidObjectReference:
            "The local attachment reference is invalid."
        case .invalidManifest:
            "The protected attachment manifest is invalid."
        case .integrityFailure:
            "The protected attachment no longer matches its immutable manifest."
        case .dataProtectionUnavailable:
            "The attachment could not be stored with the required device protection."
        case .committedAttachmentCannotBeDiscarded:
            "A committed attachment cannot be removed as abandoned staging data."
        }
    }
}

public enum LocalCaptureAttachmentState: String, Codable, Hashable, Sendable {
    case staged
    case committed
}

public enum LocalCaptureAttachmentRetention: String, Codable, Hashable, Sendable {
    case localOnly = "local_only"
}

public enum LocalCaptureAttachmentProtection: String, Codable, Hashable, Sendable {
    case platformDataProtection = "platform_data_protection"
}

public struct LocalCaptureAttachmentManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let objectReferencePrefix = "odyssey-local-attachment:v1:"

    public let schemaVersion: Int
    public let attachmentID: UUIDv7
    public let kind: CapturePayloadKind
    public let objectReference: String
    public let contentHash: String
    public let byteCount: Int64
    public let mediaType: String
    public let createdAt: Date
    public let state: LocalCaptureAttachmentState
    public let retention: LocalCaptureAttachmentRetention
    public let protection: LocalCaptureAttachmentProtection
    public let sensitivity: DataClass

    public init(
        attachmentID: UUIDv7,
        kind: CapturePayloadKind,
        contentHash: String,
        byteCount: Int64,
        mediaType: String,
        createdAt: Date,
        state: LocalCaptureAttachmentState,
        retention: LocalCaptureAttachmentRetention,
        sensitivity: DataClass
    ) throws {
        guard kind == .audio || kind == .imageReference || kind == .fileReference else {
            throw LocalCaptureAttachmentError.unsupportedKind
        }
        guard Self.isSHA256(contentHash), byteCount > 0 else {
            throw LocalCaptureAttachmentError.invalidManifest
        }
        guard Self.isMediaType(mediaType) else {
            throw LocalCaptureAttachmentError.invalidMediaType
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LocalCaptureAttachmentError.invalidClock
        }
        guard sensitivity != .operationalSecret else {
            throw LocalCaptureAttachmentError.invalidManifest
        }
        schemaVersion = Self.currentSchemaVersion
        self.attachmentID = attachmentID
        self.kind = kind
        objectReference = Self.objectReference(for: attachmentID)
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.state = state
        self.retention = retention
        protection = .platformDataProtection
        self.sensitivity = sensitivity
    }

    public var captureReference: CaptureAttachmentReference {
        get throws {
            try CaptureAttachmentReference(
                attachmentID: attachmentID,
                kind: kind,
                objectRef: objectReference,
                contentHash: contentHash
            )
        }
    }

    public static func objectReference(for attachmentID: UUIDv7) -> String {
        objectReferencePrefix + attachmentID.description
    }

    public static func attachmentID(from objectReference: String) -> UUIDv7? {
        guard objectReference.hasPrefix(objectReferencePrefix) else { return nil }
        let value = String(objectReference.dropFirst(objectReferencePrefix.count))
        guard let identifier = UUID(uuidString: value) else { return nil }
        return try? UUIDv7(validating: identifier)
    }

    fileprivate func changingState(
        to state: LocalCaptureAttachmentState
    ) throws -> Self {
        try Self(
            attachmentID: attachmentID,
            kind: kind,
            contentHash: contentHash,
            byteCount: byteCount,
            mediaType: mediaType,
            createdAt: createdAt,
            state: state,
            retention: retention,
            sensitivity: sensitivity
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    fileprivate static func isMediaType(_ value: String) -> Bool {
        guard (3 ... 255).contains(value.count),
              value == value.lowercased(),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.filter({ $0 == "/" }).count == 1
        else { return false }
        return value.utf8.allSatisfy {
            (48 ... 57).contains($0)
                || (97 ... 122).contains($0)
                || [43, 45, 46, 47].contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case attachmentID
        case kind
        case objectReference
        case contentHash
        case byteCount
        case mediaType
        case createdAt
        case state
        case retention
        case protection
        case sensitivity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        let attachmentID = try values.decode(UUIDv7.self, forKey: .attachmentID)
        let objectReference = try values.decode(String.self, forKey: .objectReference)
        let protection = try values.decode(
            LocalCaptureAttachmentProtection.self,
            forKey: .protection
        )
        guard schemaVersion == Self.currentSchemaVersion,
              objectReference == Self.objectReference(for: attachmentID),
              protection == .platformDataProtection
        else {
            throw LocalCaptureAttachmentError.invalidManifest
        }
        try self.init(
            attachmentID: attachmentID,
            kind: values.decode(CapturePayloadKind.self, forKey: .kind),
            contentHash: values.decode(String.self, forKey: .contentHash),
            byteCount: values.decode(Int64.self, forKey: .byteCount),
            mediaType: values.decode(String.self, forKey: .mediaType),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            state: values.decode(LocalCaptureAttachmentState.self, forKey: .state),
            retention: values.decode(
                LocalCaptureAttachmentRetention.self,
                forKey: .retention
            ),
            sensitivity: values.decode(DataClass.self, forKey: .sensitivity)
        )
    }
}

public struct LocalCaptureAttachmentStoreConfiguration: Hashable, Sendable {
    public static let defaultMaximumBytes: Int64 = 128 * 1_024 * 1_024

    public let rootDirectory: URL
    public let maximumBytes: Int64

    public init(
        rootDirectory: URL,
        maximumBytes: Int64 = Self.defaultMaximumBytes
    ) throws {
        guard rootDirectory.isFileURL,
              rootDirectory.path.hasPrefix("/"),
              maximumBytes > 0
        else {
            throw LocalCaptureAttachmentError.invalidConfiguration(
                "Protected attachment storage requires an absolute file URL and a positive limit."
            )
        }
        self.rootDirectory = rootDirectory
        self.maximumBytes = maximumBytes
    }
}

public struct LocalCaptureAttachmentReconciliationReport: Hashable, Sendable {
    public let stagedAttachmentsCommitted: Int
    public let stagedAttachmentsAwaitingReview: Int
    public let missingReferencedAttachments: Int

    public init(
        stagedAttachmentsCommitted: Int,
        stagedAttachmentsAwaitingReview: Int,
        missingReferencedAttachments: Int
    ) {
        self.stagedAttachmentsCommitted = stagedAttachmentsCommitted
        self.stagedAttachmentsAwaitingReview = stagedAttachmentsAwaitingReview
        self.missingReferencedAttachments = missingReferencedAttachments
    }
}

public enum LocalCaptureAttachmentRecoveryState: Hashable, Sendable {
    case completed(LocalCaptureAttachmentReconciliationReport)
    case requiresRepair
}

public actor LocalCaptureAttachmentStore {
    private static let contentFileName = "content"
    private static let manifestFileName = "manifest.json"
    private static let stagingPrefix = ".staging-"

    private let configuration: LocalCaptureAttachmentStoreConfiguration
    private let clock: @Sendable () -> Date
    private let identifier: @Sendable () -> UUIDv7

    public init(
        configuration: LocalCaptureAttachmentStoreConfiguration,
        clock: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> UUIDv7 = UUIDv7.init
    ) throws {
        self.configuration = configuration
        self.clock = clock
        self.identifier = identifier
        try FileManager.default.createDirectory(
            at: configuration.rootDirectory,
            withIntermediateDirectories: true
        )
        try Self.secureDirectory(configuration.rootDirectory)
        try Self.removeAbandonedTemporaryDirectories(in: configuration.rootDirectory)
    }

    public func stageFile(
        at sourceURL: URL,
        kind: CapturePayloadKind,
        mediaType: String,
        retention: LocalCaptureAttachmentRetention = .localOnly,
        sensitivity: DataClass = .private
    ) throws -> LocalCaptureAttachmentManifest {
        guard sourceURL.isFileURL else {
            throw LocalCaptureAttachmentError.sourceUnavailable
        }
        let sourceValues = try sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let sourceSize = sourceValues.fileSize,
              sourceSize > 0
        else {
            throw LocalCaptureAttachmentError.sourceUnavailable
        }
        guard Int64(sourceSize) <= configuration.maximumBytes else {
            throw LocalCaptureAttachmentError.attachmentTooLarge(
                maximumBytes: configuration.maximumBytes
            )
        }
        return try stage(
            kind: kind,
            mediaType: mediaType,
            retention: retention,
            sensitivity: sensitivity
        ) { contentURL in
            try Self.copyFile(
                from: sourceURL,
                to: contentURL,
                maximumBytes: configuration.maximumBytes
            )
        }
    }

    public func stageData(
        _ data: Data,
        kind: CapturePayloadKind,
        mediaType: String,
        retention: LocalCaptureAttachmentRetention = .localOnly,
        sensitivity: DataClass = .private
    ) throws -> LocalCaptureAttachmentManifest {
        guard !data.isEmpty else {
            throw LocalCaptureAttachmentError.emptyAttachment
        }
        guard Int64(data.count) <= configuration.maximumBytes else {
            throw LocalCaptureAttachmentError.attachmentTooLarge(
                maximumBytes: configuration.maximumBytes
            )
        }
        return try stage(
            kind: kind,
            mediaType: mediaType,
            retention: retention,
            sensitivity: sensitivity
        ) { contentURL in
            try data.write(to: contentURL, options: .atomic)
        }
    }

    public func markCommitted(
        _ attachmentID: UUIDv7
    ) throws -> LocalCaptureAttachmentManifest {
        let manifest = try readManifest(attachmentID)
        guard manifest.state != .committed else { return manifest }
        let committed = try manifest.changingState(to: .committed)
        try writeManifest(committed, in: attachmentDirectory(attachmentID))
        return committed
    }

    public func discardStaged(_ attachmentID: UUIDv7) throws {
        let directory = attachmentDirectory(attachmentID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let manifest = try readManifest(attachmentID)
        guard manifest.state == .staged else {
            throw LocalCaptureAttachmentError.committedAttachmentCannotBeDiscarded
        }
        try FileManager.default.removeItem(at: directory)
    }

    public func manifest(
        for attachmentID: UUIDv7
    ) throws -> LocalCaptureAttachmentManifest {
        try readManifest(attachmentID)
    }

    public func manifests() throws -> [LocalCaptureAttachmentManifest] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: configuration.rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.map { entry in
            guard entry.lastPathComponent.first != ".",
                  let identifier = UUID(uuidString: entry.lastPathComponent),
                  let attachmentID = try? UUIDv7(validating: identifier)
            else {
                throw LocalCaptureAttachmentError.invalidManifest
            }
            return try readManifest(attachmentID)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func verifiedContentURL(
        for reference: CaptureAttachmentReference
    ) throws -> URL {
        let manifest = try readManifest(reference.attachmentID)
        guard try manifest.captureReference == reference,
              manifest.state == .committed
        else {
            throw LocalCaptureAttachmentError.integrityFailure
        }
        let contentURL = contentURL(reference.attachmentID)
        let values = try contentURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == manifest.byteCount,
              try SHA256Digest.hexDigest(ofFileAt: contentURL) == manifest.contentHash
        else {
            throw LocalCaptureAttachmentError.integrityFailure
        }
        return contentURL
    }

    public func reconcile(
        referencedObjectReferences: Set<String>
    ) throws -> LocalCaptureAttachmentReconciliationReport {
        var committedCount = 0
        var awaitingReviewCount = 0
        var knownReferences = Set<String>()
        for manifest in try manifests() {
            knownReferences.insert(manifest.objectReference)
            guard manifest.state == .staged else { continue }
            if referencedObjectReferences.contains(manifest.objectReference) {
                _ = try markCommitted(manifest.attachmentID)
                committedCount += 1
            } else {
                awaitingReviewCount += 1
            }
        }
        let expectedLocalReferences = Set(referencedObjectReferences.filter {
            $0.hasPrefix(LocalCaptureAttachmentManifest.objectReferencePrefix)
        })
        return LocalCaptureAttachmentReconciliationReport(
            stagedAttachmentsCommitted: committedCount,
            stagedAttachmentsAwaitingReview: awaitingReviewCount,
            missingReferencedAttachments: expectedLocalReferences.subtracting(
                knownReferences
            ).count
        )
    }

    private func stage(
        kind: CapturePayloadKind,
        mediaType: String,
        retention: LocalCaptureAttachmentRetention,
        sensitivity: DataClass,
        writeContent: (URL) throws -> Void
    ) throws -> LocalCaptureAttachmentManifest {
        guard kind == .audio || kind == .imageReference || kind == .fileReference else {
            throw LocalCaptureAttachmentError.unsupportedKind
        }
        guard LocalCaptureAttachmentManifest.isMediaType(mediaType) else {
            throw LocalCaptureAttachmentError.invalidMediaType
        }
        guard sensitivity != .operationalSecret else {
            throw LocalCaptureAttachmentError.invalidManifest
        }
        let attachmentID = identifier()
        let createdAt = clock()
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LocalCaptureAttachmentError.invalidClock
        }
        let destination = attachmentDirectory(attachmentID)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LocalCaptureAttachmentError.attachmentIdentityConflict
        }
        let staging = configuration.rootDirectory.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        try Self.secureDirectory(staging)
        let stagedContentURL = staging.appendingPathComponent(
            Self.contentFileName,
            isDirectory: false
        )
        try writeContent(stagedContentURL)
        try Self.secureFile(stagedContentURL)
        try Self.synchronizeFile(stagedContentURL)
        let values = try stagedContentURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0
        else {
            throw LocalCaptureAttachmentError.emptyAttachment
        }
        guard Int64(size) <= configuration.maximumBytes else {
            throw LocalCaptureAttachmentError.attachmentTooLarge(
                maximumBytes: configuration.maximumBytes
            )
        }
        let manifest = try LocalCaptureAttachmentManifest(
            attachmentID: attachmentID,
            kind: kind,
            contentHash: SHA256Digest.hexDigest(ofFileAt: stagedContentURL),
            byteCount: Int64(size),
            mediaType: mediaType,
            createdAt: createdAt,
            state: .staged,
            retention: retention,
            sensitivity: sensitivity
        )
        try writeManifest(manifest, in: staging)
        try Self.excludeFromBackupIfAvailable(staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        shouldRemoveStaging = false
        return manifest
    }

    private func readManifest(_ attachmentID: UUIDv7) throws -> LocalCaptureAttachmentManifest {
        let directory = attachmentDirectory(attachmentID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw LocalCaptureAttachmentError.attachmentNotFound
        }
        let manifestURL = directory.appendingPathComponent(
            Self.manifestFileName,
            isDirectory: false
        )
        let manifest: LocalCaptureAttachmentManifest
        do {
            manifest = try SyncJSONCoding.makeDecoder().decode(
                LocalCaptureAttachmentManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch let error as LocalCaptureAttachmentError {
            throw error
        } catch {
            throw LocalCaptureAttachmentError.invalidManifest
        }
        guard manifest.attachmentID == attachmentID else {
            throw LocalCaptureAttachmentError.invalidManifest
        }
        return manifest
    }

    private func writeManifest(
        _ manifest: LocalCaptureAttachmentManifest,
        in directory: URL
    ) throws {
        let manifestURL = directory.appendingPathComponent(
            Self.manifestFileName,
            isDirectory: false
        )
        let data = try SyncJSONCoding.makeEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        try Self.secureFile(manifestURL)
        try Self.synchronizeFile(manifestURL)
    }

    private func attachmentDirectory(_ attachmentID: UUIDv7) -> URL {
        configuration.rootDirectory.appendingPathComponent(
            attachmentID.description,
            isDirectory: true
        )
    }

    private func contentURL(_ attachmentID: UUIDv7) -> URL {
        attachmentDirectory(attachmentID).appendingPathComponent(
            Self.contentFileName,
            isDirectory: false
        )
    }

    private static func removeAbandonedTemporaryDirectories(in root: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(stagingPrefix) {
            try FileManager.default.removeItem(at: entry)
        }
    }

    private static func copyFile(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int64
    ) throws {
        guard FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil
        ) else {
            throw LocalCaptureAttachmentError.sourceUnavailable
        }
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? destination.close() }
        var byteCount: Int64 = 0
        while let chunk = try source.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            byteCount += Int64(chunk.count)
            guard byteCount <= maximumBytes else {
                throw LocalCaptureAttachmentError.attachmentTooLarge(
                    maximumBytes: maximumBytes
                )
            }
            try destination.write(contentsOf: chunk)
        }
    }

    private static func secureDirectory(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        try applyDataProtectionIfAvailable(to: url)
    }

    private static func secureFile(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        try applyDataProtectionIfAvailable(to: url)
    }

    private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func applyDataProtectionIfAvailable(to url: URL) throws {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            throw LocalCaptureAttachmentError.dataProtectionUnavailable
        }
        #endif
    }

    private static func excludeFromBackupIfAvailable(_ url: URL) throws {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS) || os(macOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        #endif
    }
}
