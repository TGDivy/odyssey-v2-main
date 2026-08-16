import Foundation
import OdysseyDomain

public enum WatchCommandTransportError: Error, Equatable, Sendable {
    case invalidCommand
    case invalidAcknowledgment
    case invalidSnapshot
    case invalidLimit
    case payloadTooLarge(maximumBytes: Int)
}

public enum WatchCommandAcknowledgmentDisposition: String, Codable, Hashable, Sendable {
    case accepted
    case rejected
    case retry
}

public struct WatchCommandAcknowledgment: Codable, Hashable, Sendable {
    public let commandID: UUIDv7
    public let disposition: WatchCommandAcknowledgmentDisposition

    public init(
        commandID: UUIDv7,
        disposition: WatchCommandAcknowledgmentDisposition
    ) {
        self.commandID = commandID
        self.disposition = disposition
    }
}

public struct WatchFoodPresetReference: Codable, Hashable, Sendable {
    public let presetID: UUIDv7
    public let revision: Int
    public let name: String
    public let servingDescription: String

    public init(
        presetID: UUIDv7,
        revision: Int,
        name: String,
        servingDescription: String
    ) throws {
        guard revision >= 1,
              Self.validText(name),
              Self.validText(servingDescription)
        else {
            throw WatchCommandTransportError.invalidSnapshot
        }
        self.presetID = presetID
        self.revision = revision
        self.name = name
        self.servingDescription = servingDescription
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            presetID: container.decode(UUIDv7.self, forKey: .presetID),
            revision: container.decode(Int.self, forKey: .revision),
            name: container.decode(String.self, forKey: .name),
            servingDescription: container.decode(String.self, forKey: .servingDescription)
        )
    }

    private static func validText(_ value: String) -> Bool {
        (1 ... 100).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public struct WatchFoodPresetSnapshot: Codable, Hashable, Sendable {
    public static let maximumPresetCount = 4
    public static let maximumLifetime: TimeInterval = 24 * 60 * 60

    public let schemaVersion: Int
    public let generatedAt: Date
    public let expiresAt: Date
    public let timeZoneID: String
    public let presets: [WatchFoodPresetReference]

    public init(
        generatedAt: Date,
        expiresAt: Date,
        timeZoneID: String,
        presets: [WatchFoodPresetReference]
    ) throws {
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt >= generatedAt,
              expiresAt.timeIntervalSince(generatedAt) <= Self.maximumLifetime,
              TimeZone(identifier: timeZoneID) != nil,
              (1 ... 100).contains(timeZoneID.count),
              timeZoneID == timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines),
              presets.count <= Self.maximumPresetCount,
              Set(presets.map(\.presetID)).count == presets.count
        else {
            throw WatchCommandTransportError.invalidSnapshot
        }
        schemaVersion = 1
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.timeZoneID = timeZoneID
        self.presets = presets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw WatchCommandTransportError.invalidSnapshot
        }
        try self.init(
            generatedAt: container.decode(Date.self, forKey: .generatedAt),
            expiresAt: container.decode(Date.self, forKey: .expiresAt),
            timeZoneID: container.decode(String.self, forKey: .timeZoneID),
            presets: container.decode([WatchFoodPresetReference].self, forKey: .presets)
        )
    }

    public func isFresh(at date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && date >= generatedAt.addingTimeInterval(-60)
            && date <= expiresAt
    }
}

public enum WatchCommandTransportCodec {
    public static let commandDataKey = "odyssey_watch_command_v1"
    public static let acknowledgmentDataKey = "odyssey_watch_ack_v1"
    public static let foodSnapshotDataKey = "odyssey_watch_food_snapshot_v1"
    public static let maximumCommandBytes = ExtensionCommandQueue.maximumPayloadBytes
    public static let maximumAcknowledgmentBytes = 4 * 1_024
    public static let maximumSnapshotBytes = 32 * 1_024

    public static func encodeCommand(_ command: ExtensionCommand) throws -> Data {
        guard command.invokingSurface == .watch,
              command.kind == .captureText || command.kind == .logFood
        else {
            throw WatchCommandTransportError.invalidCommand
        }
        return try encode(
            command,
            maximumBytes: maximumCommandBytes
        )
    }

    public static func decodeCommand(_ data: Data) throws -> ExtensionCommand {
        let command: ExtensionCommand = try decode(
            data,
            maximumBytes: maximumCommandBytes,
            invalidError: .invalidCommand
        )
        guard command.invokingSurface == .watch,
              command.kind == .captureText || command.kind == .logFood
        else {
            throw WatchCommandTransportError.invalidCommand
        }
        return command
    }

    public static func encodeAcknowledgment(
        _ acknowledgment: WatchCommandAcknowledgment
    ) throws -> Data {
        try encode(
            acknowledgment,
            maximumBytes: maximumAcknowledgmentBytes
        )
    }

    public static func decodeAcknowledgment(
        _ data: Data
    ) throws -> WatchCommandAcknowledgment {
        try decode(
            data,
            maximumBytes: maximumAcknowledgmentBytes,
            invalidError: .invalidAcknowledgment
        )
    }

    public static func encodeFoodSnapshot(
        _ snapshot: WatchFoodPresetSnapshot
    ) throws -> Data {
        try encode(snapshot, maximumBytes: maximumSnapshotBytes)
    }

    public static func decodeFoodSnapshot(
        _ data: Data
    ) throws -> WatchFoodPresetSnapshot {
        try decode(
            data,
            maximumBytes: maximumSnapshotBytes,
            invalidError: .invalidSnapshot
        )
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        maximumBytes: Int
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else {
            throw WatchCommandTransportError.payloadTooLarge(maximumBytes: maximumBytes)
        }
        return data
    }

    private static func decode<Value: Decodable>(
        _ data: Data,
        maximumBytes: Int,
        invalidError: WatchCommandTransportError
    ) throws -> Value {
        guard !data.isEmpty else { throw invalidError }
        guard data.count <= maximumBytes else {
            throw WatchCommandTransportError.payloadTooLarge(maximumBytes: maximumBytes)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: data)
        } catch let error as WatchCommandTransportError {
            throw error
        } catch {
            throw invalidError
        }
    }
}

public actor WatchCommandOutbox {
    public static let maximumTransferBatch = 20

    private let queue: ExtensionCommandQueue

    public init(queue: ExtensionCommandQueue) {
        self.queue = queue
    }

    public func submit(_ command: ExtensionCommand) async throws {
        _ = try WatchCommandTransportCodec.encodeCommand(command)
        try await queue.enqueue(command)
    }

    public func commandsReadyForTransfer(
        excluding outstandingCommandIDs: Set<UUIDv7>,
        limit: Int = maximumTransferBatch
    ) async throws -> [ExtensionCommand] {
        guard (1 ... Self.maximumTransferBatch).contains(limit) else {
            throw WatchCommandTransportError.invalidLimit
        }
        _ = try await queue.recoverInterruptedClaims()
        let pendingCount = try await queue.pendingCount()
        var ready = [ExtensionCommand]()
        var inspectedClaims = [ClaimedExtensionCommand]()
        for _ in 0 ..< pendingCount {
            guard let claim = try await queue.claimNext() else { break }
            inspectedClaims.append(claim)
            guard !outstandingCommandIDs.contains(claim.command.commandID) else {
                continue
            }
            ready.append(claim.command)
            if ready.count == limit { break }
        }
        for claim in inspectedClaims {
            try await queue.retry(claim)
        }
        return ready
    }

    public func resolve(_ acknowledgment: WatchCommandAcknowledgment) async throws {
        switch acknowledgment.disposition {
        case .accepted:
            _ = try await queue.acknowledge(commandID: acknowledgment.commandID)
        case .rejected:
            _ = try await queue.reject(commandID: acknowledgment.commandID)
        case .retry:
            break
        }
    }

    public func pendingCount() async throws -> Int {
        try await queue.pendingCount()
    }
}
