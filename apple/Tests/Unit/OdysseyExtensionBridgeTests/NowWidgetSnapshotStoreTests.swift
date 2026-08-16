import Foundation
import OdysseyExtensionBridge
import OdysseyIntelligence
import Testing

private let widgetStoreDate = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func nowWidgetSnapshotStoreAtomicallyRoundTripsAndRemovesCache() throws {
    let directory = try widgetStoreDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try NowWidgetSnapshotStore(rootDirectory: directory)
    let snapshot = try NowWidgetSnapshot(
        generatedAt: widgetStoreDate,
        expiresAt: widgetStoreDate.addingTimeInterval(3_600),
        timeZoneID: "UTC",
        state: .clear,
        summary: "Nothing requires attention."
    )

    #expect(try store.read() == nil)
    try store.write(snapshot)
    #expect(try store.read() == snapshot)
    #expect(try store.remove())
    #expect(!(try store.remove()))
}

@Test
func nowWidgetSnapshotStoreRejectsMalformedAndOversizedCache() throws {
    let directory = try widgetStoreDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try NowWidgetSnapshotStore(rootDirectory: directory)
    let snapshotDirectory = directory
        .appendingPathComponent("NowWidgetSnapshot", isDirectory: true)
        .appendingPathComponent("v1", isDirectory: true)
    let snapshotURL = snapshotDirectory.appendingPathComponent("current.json")

    try Data("not json".utf8).write(to: snapshotURL)
    #expect(throws: NowWidgetSnapshotStoreError.invalidSnapshot) {
        try store.read()
    }
    try Data(
        repeating: 0,
        count: NowWidgetSnapshotStore.maximumPayloadBytes + 1
    ).write(to: snapshotURL)
    #expect(throws: NowWidgetSnapshotStoreError.payloadTooLarge(
        maximumBytes: NowWidgetSnapshotStore.maximumPayloadBytes
    )) {
        try store.read()
    }
}

private func widgetStoreDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-now-widget-store-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}
