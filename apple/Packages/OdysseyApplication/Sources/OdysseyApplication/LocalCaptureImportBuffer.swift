import Foundation
import OdysseyDomain

public enum LocalCaptureImportBufferError: Error, Equatable, Sendable {
    case invalidConfiguration
    case sourceUnavailable
    case emptyImport
    case importTooLarge(maximumBytes: Int64)
    case importIdentityConflict
    case invalidPreparedImport
    case preparationFailed
    case dataProtectionUnavailable
}

extension LocalCaptureImportBufferError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Capture imports require an absolute local directory and a positive size limit."
        case .sourceUnavailable:
            "The selected item is not a readable regular file."
        case .emptyImport:
            "The selected item is empty."
        case let .importTooLarge(maximumBytes):
            "The selected item exceeds the local \(maximumBytes)-byte limit."
        case .importIdentityConflict:
            "The temporary capture import identity is already in use."
        case .invalidPreparedImport:
            "The temporary capture import reference is invalid."
        case .preparationFailed:
            "The selected item could not be copied into protected temporary storage."
        case .dataProtectionUnavailable:
            "The selected item could not be buffered with the required device protection."
        }
    }
}

public struct LocalCaptureImportBufferConfiguration: Hashable, Sendable {
    public let rootDirectory: URL
    public let maximumBytes: Int64

    public init(
        rootDirectory: URL,
        maximumBytes: Int64 = LocalCaptureAttachmentStoreConfiguration.defaultMaximumBytes
    ) throws {
        guard rootDirectory.isFileURL,
              rootDirectory.path.hasPrefix("/"),
              maximumBytes > 0
        else {
            throw LocalCaptureImportBufferError.invalidConfiguration
        }
        self.rootDirectory = rootDirectory
        self.maximumBytes = maximumBytes
    }
}

public struct LocalCapturePreparedImport: Hashable, Sendable {
    public let importID: UUIDv7
    public let fileURL: URL
    public let byteCount: Int64

    fileprivate init(importID: UUIDv7, fileURL: URL, byteCount: Int64) {
        self.importID = importID
        self.fileURL = fileURL
        self.byteCount = byteCount
    }
}

public final class LocalCaptureImportBuffer: @unchecked Sendable {
    private let configuration: LocalCaptureImportBufferConfiguration
    private let identifier: @Sendable () -> UUIDv7
    private let lock = NSLock()

    public init(
        configuration: LocalCaptureImportBufferConfiguration,
        identifier: @escaping @Sendable () -> UUIDv7 = UUIDv7.init
    ) throws {
        self.configuration = configuration
        self.identifier = identifier
        try FileManager.default.createDirectory(
            at: configuration.rootDirectory,
            withIntermediateDirectories: true
        )
        try Self.secureDirectory(configuration.rootDirectory)
        try Self.excludeFromBackupIfAvailable(configuration.rootDirectory)
        try Self.removeAbandonedImports(in: configuration.rootDirectory)
    }

    public func prepareFile(at sourceURL: URL) throws -> LocalCapturePreparedImport {
        try withLock {
            guard sourceURL.isFileURL else {
                throw LocalCaptureImportBufferError.sourceUnavailable
            }
            #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
            let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            #endif
            let values: URLResourceValues
            do {
                values = try sourceURL.resourceValues(forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                throw LocalCaptureImportBufferError.sourceUnavailable
            }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let sourceSize = values.fileSize
            else {
                throw LocalCaptureImportBufferError.sourceUnavailable
            }
            guard sourceSize > 0 else {
                throw LocalCaptureImportBufferError.emptyImport
            }
            guard Int64(sourceSize) <= configuration.maximumBytes else {
                throw LocalCaptureImportBufferError.importTooLarge(
                    maximumBytes: configuration.maximumBytes
                )
            }

            let importID = identifier()
            let destinationURL = fileURL(for: importID)
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw LocalCaptureImportBufferError.importIdentityConflict
            }
            guard FileManager.default.createFile(
                atPath: destinationURL.path,
                contents: nil
            ) else {
                throw LocalCaptureImportBufferError.preparationFailed
            }
            var shouldRemoveDestination = true
            defer {
                if shouldRemoveDestination {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
            }
            try Self.secureFile(destinationURL)
            let byteCount = try copyFile(
                from: sourceURL,
                to: destinationURL,
                maximumBytes: configuration.maximumBytes
            )
            try Self.synchronizeFile(destinationURL)
            shouldRemoveDestination = false
            return LocalCapturePreparedImport(
                importID: importID,
                fileURL: destinationURL,
                byteCount: byteCount
            )
        }
    }

    public func discard(_ preparedImport: LocalCapturePreparedImport) throws {
        try withLock {
            let expectedURL = fileURL(for: preparedImport.importID)
            guard preparedImport.fileURL.standardizedFileURL == expectedURL.standardizedFileURL,
                  expectedURL.deletingLastPathComponent().standardizedFileURL
                      == configuration.rootDirectory.standardizedFileURL
            else {
                throw LocalCaptureImportBufferError.invalidPreparedImport
            }
            guard FileManager.default.fileExists(atPath: expectedURL.path) else { return }
            try FileManager.default.removeItem(at: expectedURL)
        }
    }

    private func fileURL(for importID: UUIDv7) -> URL {
        configuration.rootDirectory.appendingPathComponent(
            importID.description,
            isDirectory: false
        )
    }

    private func copyFile(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int64
    ) throws -> Int64 {
        let source: FileHandle
        do {
            source = try FileHandle(forReadingFrom: sourceURL)
        } catch {
            throw LocalCaptureImportBufferError.sourceUnavailable
        }
        defer { try? source.close() }
        let destination: FileHandle
        do {
            destination = try FileHandle(forWritingTo: destinationURL)
        } catch {
            throw LocalCaptureImportBufferError.preparationFailed
        }
        defer { try? destination.close() }
        var byteCount: Int64 = 0
        do {
            while let chunk = try source.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                byteCount += Int64(chunk.count)
                guard byteCount <= maximumBytes else {
                    throw LocalCaptureImportBufferError.importTooLarge(
                        maximumBytes: maximumBytes
                    )
                }
                try destination.write(contentsOf: chunk)
            }
        } catch let error as LocalCaptureImportBufferError {
            throw error
        } catch {
            throw LocalCaptureImportBufferError.preparationFailed
        }
        guard byteCount > 0 else {
            throw LocalCaptureImportBufferError.emptyImport
        }
        return byteCount
    }

    private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func removeAbandonedImports(in rootDirectory: URL) throws {
        for entry in try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.removeItem(at: entry)
        }
    }

    private static func secureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
            try applyDataProtectionIfAvailable(to: url)
        } catch let error as LocalCaptureImportBufferError {
            throw error
        } catch {
            throw LocalCaptureImportBufferError.preparationFailed
        }
    }

    private static func secureFile(_ url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            try applyDataProtectionIfAvailable(to: url)
        } catch let error as LocalCaptureImportBufferError {
            throw error
        } catch {
            throw LocalCaptureImportBufferError.preparationFailed
        }
    }

    private static func synchronizeFile(_ url: URL) throws {
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch {
            throw LocalCaptureImportBufferError.preparationFailed
        }
    }

    private static func applyDataProtectionIfAvailable(to url: URL) throws {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        } catch {
            throw LocalCaptureImportBufferError.dataProtectionUnavailable
        }
        #endif
    }

    private static func excludeFromBackupIfAvailable(_ url: URL) throws {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS) || os(macOS)
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            throw LocalCaptureImportBufferError.preparationFailed
        }
        #endif
    }
}
