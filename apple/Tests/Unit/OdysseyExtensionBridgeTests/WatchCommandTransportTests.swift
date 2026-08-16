import Foundation
import OdysseyDomain
import OdysseyExtensionBridge
import Testing

private let watchTransportDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func watchTransportRoundTripsValidatedCommandsAndAcknowledgments() throws {
    let command = try ExtensionCommand.captureText(
        "Short Watch note",
        commandID: watchTransportIdentifier(1),
        createdAt: watchTransportDate,
        invokingSurface: .watch
    )
    let encoded = try WatchCommandTransportCodec.encodeCommand(command)
    #expect(try WatchCommandTransportCodec.decodeCommand(encoded) == command)

    let acknowledgment = WatchCommandAcknowledgment(
        commandID: command.commandID,
        disposition: .accepted
    )
    let acknowledgmentData = try WatchCommandTransportCodec.encodeAcknowledgment(
        acknowledgment
    )
    #expect(
        try WatchCommandTransportCodec.decodeAcknowledgment(acknowledgmentData)
            == acknowledgment
    )

    let phoneCommand = try ExtensionCommand.captureText(
        "Not a Watch command",
        commandID: watchTransportIdentifier(2),
        createdAt: watchTransportDate,
        invokingSurface: .appIntent
    )
    #expect(throws: WatchCommandTransportError.invalidCommand) {
        try WatchCommandTransportCodec.encodeCommand(phoneCommand)
    }
}

@Test
func watchFoodSnapshotIsBoundedFreshAndRoundTrips() throws {
    let presets = try (1 ... 4).map { value in
        try WatchFoodPresetReference(
            presetID: watchTransportIdentifier(10 + value),
            revision: value,
            name: "Synthetic preset \(value)",
            servingDescription: "1 portion"
        )
    }
    let snapshot = try WatchFoodPresetSnapshot(
        generatedAt: watchTransportDate,
        expiresAt: watchTransportDate.addingTimeInterval(12 * 60 * 60),
        timeZoneID: "UTC",
        presets: presets
    )
    let data = try WatchCommandTransportCodec.encodeFoodSnapshot(snapshot)

    #expect(try WatchCommandTransportCodec.decodeFoodSnapshot(data) == snapshot)
    #expect(snapshot.isFresh(at: watchTransportDate.addingTimeInterval(60)))
    #expect(!snapshot.isFresh(at: snapshot.expiresAt.addingTimeInterval(1)))
    #expect(throws: WatchCommandTransportError.invalidSnapshot) {
        try WatchFoodPresetSnapshot(
            generatedAt: watchTransportDate,
            expiresAt: watchTransportDate.addingTimeInterval(60),
            timeZoneID: "UTC",
            presets: presets + [presets[0]]
        )
    }
}

@Test
func watchOutboxPersistsSkipsOutstandingAndResolvesReceipts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-watch-outbox-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try ExtensionCommandQueue(rootDirectory: directory)
    let outbox = WatchCommandOutbox(queue: queue)
    let first = try ExtensionCommand.captureText(
        "First Watch note",
        commandID: watchTransportIdentifier(30),
        createdAt: watchTransportDate,
        invokingSurface: .watch
    )
    let second = try ExtensionCommand.captureText(
        "Second Watch note",
        commandID: watchTransportIdentifier(31),
        createdAt: watchTransportDate.addingTimeInterval(1),
        invokingSurface: .watch
    )

    try await outbox.submit(first)
    try await outbox.submit(second)
    let ready = try await outbox.commandsReadyForTransfer(
        excluding: [first.commandID]
    )
    #expect(ready == [second])
    try await outbox.resolve(WatchCommandAcknowledgment(
        commandID: first.commandID,
        disposition: .accepted
    ))
    try await outbox.resolve(WatchCommandAcknowledgment(
        commandID: second.commandID,
        disposition: .rejected
    ))
    #expect(try await outbox.pendingCount() == 0)
}

private func watchTransportIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
