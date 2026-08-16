import Foundation
import OdysseyDomain

public enum ExtensionInvokingSurface: String, Codable, CaseIterable, Hashable, Sendable {
    case appIntent = "app_intent"
    case control
    case widget
    case watch
}

public enum ExtensionCommandKind: String, Codable, CaseIterable, Hashable, Sendable {
    case captureText = "capture_text"
    case logFood = "log_food"
    case presentCapture = "present_capture"
    case presentFood = "present_food"
}

public enum ExtensionCommandError: Error, Equatable, Sendable {
    case invalidCommand
    case invalidText
    case invalidFoodLog
    case payloadTooLarge(maximumBytes: Int)
    case unsafeClaimToken
    case appGroupUnavailable
}

public struct ExtensionCommand: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumTextLength = 10_000

    public let schemaVersion: Int
    public let commandID: UUIDv7
    public let createdAt: Date
    public let invokingSurface: ExtensionInvokingSurface
    public let kind: ExtensionCommandKind
    public let text: String?
    public let presetID: UUIDv7?
    public let expectedPresetRevision: Int?
    public let quantity: Double?
    public let occurredAt: Date?
    public let timeZoneID: String?

    public static func captureText(
        _ text: String,
        commandID: UUIDv7 = UUIDv7(),
        createdAt: Date = Date(),
        invokingSurface: ExtensionInvokingSurface
    ) throws -> Self {
        try Self(
            schemaVersion: currentSchemaVersion,
            commandID: commandID,
            createdAt: createdAt,
            invokingSurface: invokingSurface,
            kind: .captureText,
            text: text,
            presetID: nil,
            expectedPresetRevision: nil,
            quantity: nil,
            occurredAt: nil,
            timeZoneID: nil
        )
    }

    public static func logFood(
        presetID: UUIDv7,
        expectedPresetRevision: Int,
        quantity: Double = 1,
        occurredAt: Date = Date(),
        timeZoneID: String,
        commandID: UUIDv7 = UUIDv7(),
        createdAt: Date = Date(),
        invokingSurface: ExtensionInvokingSurface
    ) throws -> Self {
        try Self(
            schemaVersion: currentSchemaVersion,
            commandID: commandID,
            createdAt: createdAt,
            invokingSurface: invokingSurface,
            kind: .logFood,
            text: nil,
            presetID: presetID,
            expectedPresetRevision: expectedPresetRevision,
            quantity: quantity,
            occurredAt: occurredAt,
            timeZoneID: timeZoneID
        )
    }

    public static func presentCapture(
        commandID: UUIDv7 = UUIDv7(),
        createdAt: Date = Date(),
        invokingSurface: ExtensionInvokingSurface
    ) throws -> Self {
        try presentation(
            kind: .presentCapture,
            commandID: commandID,
            createdAt: createdAt,
            invokingSurface: invokingSurface
        )
    }

    public static func presentFood(
        commandID: UUIDv7 = UUIDv7(),
        createdAt: Date = Date(),
        invokingSurface: ExtensionInvokingSurface
    ) throws -> Self {
        try presentation(
            kind: .presentFood,
            commandID: commandID,
            createdAt: createdAt,
            invokingSurface: invokingSurface
        )
    }

    private static func presentation(
        kind: ExtensionCommandKind,
        commandID: UUIDv7,
        createdAt: Date,
        invokingSurface: ExtensionInvokingSurface
    ) throws -> Self {
        try Self(
            schemaVersion: currentSchemaVersion,
            commandID: commandID,
            createdAt: createdAt,
            invokingSurface: invokingSurface,
            kind: kind,
            text: nil,
            presetID: nil,
            expectedPresetRevision: nil,
            quantity: nil,
            occurredAt: nil,
            timeZoneID: nil
        )
    }

    private init(
        schemaVersion: Int,
        commandID: UUIDv7,
        createdAt: Date,
        invokingSurface: ExtensionInvokingSurface,
        kind: ExtensionCommandKind,
        text: String?,
        presetID: UUIDv7?,
        expectedPresetRevision: Int?,
        quantity: Double?,
        occurredAt: Date?,
        timeZoneID: String?
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              createdAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw ExtensionCommandError.invalidCommand
        }
        switch kind {
        case .captureText:
            guard let text,
                  (1 ... Self.maximumTextLength).contains(text.count),
                  text == text.trimmingCharacters(in: .whitespacesAndNewlines),
                  presetID == nil,
                  expectedPresetRevision == nil,
                  quantity == nil,
                  occurredAt == nil,
                  timeZoneID == nil
            else {
                throw ExtensionCommandError.invalidText
            }
        case .logFood:
            guard text == nil,
                  presetID != nil,
                  let expectedPresetRevision,
                  expectedPresetRevision >= 1,
                  let quantity,
                  quantity.isFinite,
                  quantity > 0,
                  quantity <= 100,
                  let occurredAt,
                  occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  occurredAt <= createdAt,
                  let timeZoneID,
                  (1 ... 100).contains(timeZoneID.count),
                  timeZoneID == timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines),
                  TimeZone(identifier: timeZoneID) != nil
            else {
                throw ExtensionCommandError.invalidFoodLog
            }
        case .presentCapture, .presentFood:
            guard text == nil,
                  presetID == nil,
                  expectedPresetRevision == nil,
                  quantity == nil,
                  occurredAt == nil,
                  timeZoneID == nil
            else {
                throw ExtensionCommandError.invalidCommand
            }
        }
        self.schemaVersion = schemaVersion
        self.commandID = commandID
        self.createdAt = createdAt
        self.invokingSurface = invokingSurface
        self.kind = kind
        self.text = text
        self.presetID = presetID
        self.expectedPresetRevision = expectedPresetRevision
        self.quantity = quantity
        self.occurredAt = occurredAt
        self.timeZoneID = timeZoneID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            commandID: container.decode(UUIDv7.self, forKey: .commandID),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            invokingSurface: container.decode(
                ExtensionInvokingSurface.self,
                forKey: .invokingSurface
            ),
            kind: container.decode(ExtensionCommandKind.self, forKey: .kind),
            text: container.decodeIfPresent(String.self, forKey: .text),
            presetID: container.decodeIfPresent(UUIDv7.self, forKey: .presetID),
            expectedPresetRevision: container.decodeIfPresent(
                Int.self,
                forKey: .expectedPresetRevision
            ),
            quantity: container.decodeIfPresent(Double.self, forKey: .quantity),
            occurredAt: container.decodeIfPresent(Date.self, forKey: .occurredAt),
            timeZoneID: container.decodeIfPresent(String.self, forKey: .timeZoneID)
        )
    }
}

public struct ClaimedExtensionCommand: Hashable, Sendable {
    public let command: ExtensionCommand
    fileprivate let token: String
}

public actor ExtensionCommandQueue {
    public static let maximumPayloadBytes = 64 * 1_024

    private let fileManager: FileManager
    private let pendingDirectory: URL
    private let processingDirectory: URL
    private let rejectedDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public static func appGroupRoot(
        identifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !identifier.isEmpty,
              identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw ExtensionCommandError.appGroupUnavailable
        }
        #if canImport(Darwin)
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            throw ExtensionCommandError.appGroupUnavailable
        }
        return container
        #else
        throw ExtensionCommandError.appGroupUnavailable
        #endif
    }

    public init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let root = rootDirectory
            .appendingPathComponent("ExtensionCommands", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
        processingDirectory = root.appendingPathComponent("processing", isDirectory: true)
        rejectedDirectory = root.appendingPathComponent("rejected", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for directory in [root, pendingDirectory, processingDirectory, rejectedDirectory] {
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
    }

    public func enqueue(_ command: ExtensionCommand) throws {
        let data = try encoder.encode(command)
        guard data.count <= Self.maximumPayloadBytes else {
            throw ExtensionCommandError.payloadTooLarge(
                maximumBytes: Self.maximumPayloadBytes
            )
        }
        let destination = pendingDirectory.appendingPathComponent(
            command.commandID.description + ".json",
            isDirectory: false
        )
        let temporary = pendingDirectory.appendingPathComponent(
            ".pending-" + UUID().uuidString,
            isDirectory: false
        )
        try data.write(to: temporary, options: .atomic)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try fileManager.setAttributes(attributes, ofItemAtPath: temporary.path)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                return
            }
            throw error
        }
    }

    public func claimNext() throws -> ClaimedExtensionCommand? {
        let candidates = try commandFiles(in: pendingDirectory)
        for source in candidates {
            let destination = processingDirectory.appendingPathComponent(source.lastPathComponent)
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                continue
            }
            do {
                let command = try decoder.decode(
                    ExtensionCommand.self,
                    from: Data(contentsOf: destination)
                )
                return ClaimedExtensionCommand(
                    command: command,
                    token: destination.lastPathComponent
                )
            } catch {
                let rejected = rejectedDirectory.appendingPathComponent(
                    destination.lastPathComponent
                )
                try? fileManager.moveItem(at: destination, to: rejected)
            }
        }
        return nil
    }

    public func acknowledge(_ claim: ClaimedExtensionCommand) throws {
        try fileManager.removeItem(at: try processingURL(for: claim))
    }

    @discardableResult
    public func acknowledge(commandID: UUIDv7) throws -> Bool {
        try removeCommand(commandID: commandID, quarantine: false)
    }

    public func retry(_ claim: ClaimedExtensionCommand) throws {
        let source = try processingURL(for: claim)
        let destination = pendingDirectory.appendingPathComponent(claim.token)
        try fileManager.moveItem(at: source, to: destination)
    }

    public func reject(_ claim: ClaimedExtensionCommand) throws {
        let source = try processingURL(for: claim)
        let destination = rejectedDirectory.appendingPathComponent(claim.token)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    @discardableResult
    public func reject(commandID: UUIDv7) throws -> Bool {
        try removeCommand(commandID: commandID, quarantine: true)
    }

    public func pendingCount() throws -> Int {
        try commandFiles(in: pendingDirectory).count
    }

    @discardableResult
    public func recoverInterruptedClaims() throws -> Int {
        var recoveredCount = 0
        for source in try commandFiles(in: processingDirectory) {
            let destination = pendingDirectory.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
                recoveredCount += 1
            }
        }
        return recoveredCount
    }

    private func processingURL(for claim: ClaimedExtensionCommand) throws -> URL {
        guard claim.token == URL(fileURLWithPath: claim.token).lastPathComponent,
              claim.token.hasSuffix(".json")
        else {
            throw ExtensionCommandError.unsafeClaimToken
        }
        return processingDirectory.appendingPathComponent(claim.token)
    }

    private func removeCommand(
        commandID: UUIDv7,
        quarantine: Bool
    ) throws -> Bool {
        let token = commandID.description + ".json"
        var found = false
        for directory in [pendingDirectory, processingDirectory] {
            let source = directory.appendingPathComponent(token)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            found = true
            if quarantine {
                let destination = rejectedDirectory.appendingPathComponent(token)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: source)
                } else {
                    try fileManager.moveItem(at: source, to: destination)
                }
            } else {
                try fileManager.removeItem(at: source)
            }
        }
        return found
    }

    private func commandFiles(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }
}
