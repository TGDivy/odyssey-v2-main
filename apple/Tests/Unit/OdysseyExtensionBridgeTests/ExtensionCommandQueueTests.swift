import Foundation
import OdysseyDomain
import OdysseyExtensionBridge
import Testing

private let extensionDate = Date(timeIntervalSince1970: 1_786_752_000)

@Test
func extensionCommandsValidateSensitivePayloadShapes() throws {
    let food = try ExtensionCommand.logFood(
        presetID: extensionIdentifier(1),
        expectedPresetRevision: 2,
        quantity: 1.5,
        occurredAt: extensionDate,
        timeZoneID: "UTC",
        commandID: extensionIdentifier(2),
        createdAt: extensionDate,
        invokingSurface: .appIntent
    )
    #expect(food.kind == .logFood)
    #expect(food.text == nil)
    #expect(food.quantity == 1.5)
    #expect(throws: ExtensionCommandError.invalidText) {
        try ExtensionCommand.captureText(
            " ",
            createdAt: extensionDate,
            invokingSurface: .widget
        )
    }
}

@Test
func extensionQueueClaimsRetriesAndAcknowledgesAtomicFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-extension-queue-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try ExtensionCommandQueue(rootDirectory: directory)
    let command = try ExtensionCommand.captureText(
        "Synthetic extension capture",
        commandID: extensionIdentifier(10),
        createdAt: extensionDate,
        invokingSurface: .appIntent
    )

    try await queue.enqueue(command)
    try await queue.enqueue(command)
    #expect(try await queue.pendingCount() == 1)
    let first = try #require(try await queue.claimNext())
    #expect(first.command == command)
    #expect(try await queue.pendingCount() == 0)
    #expect(try await queue.recoverInterruptedClaims() == 1)
    #expect(try await queue.pendingCount() == 1)
    let retried = try #require(try await queue.claimNext())
    try await queue.retry(retried)
    let retriedAgain = try #require(try await queue.claimNext())
    try await queue.acknowledge(retriedAgain)
    #expect(try await queue.pendingCount() == 0)
    #expect(try await queue.claimNext() == nil)
}

@Test
func extensionQueueQuarantinesPermanentlyRejectedClaims() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-extension-reject-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try ExtensionCommandQueue(rootDirectory: directory)
    let command = try ExtensionCommand.captureText(
        "Synthetic rejected capture",
        commandID: extensionIdentifier(11),
        createdAt: extensionDate,
        invokingSurface: .widget
    )

    try await queue.enqueue(command)
    let claim = try #require(try await queue.claimNext())
    try await queue.reject(claim)

    let rejectedURL = directory
        .appendingPathComponent("ExtensionCommands/v1/rejected", isDirectory: true)
        .appendingPathComponent("\(command.commandID.description).json")
    #expect(FileManager.default.fileExists(atPath: rejectedURL.path))
    #expect(try await queue.pendingCount() == 0)
    #expect(try await queue.claimNext() == nil)
}

private func extensionIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
