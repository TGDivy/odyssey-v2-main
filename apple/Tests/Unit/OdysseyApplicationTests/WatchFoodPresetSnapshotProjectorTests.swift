import Foundation
import OdysseyApplication
import OdysseyDomain
import Testing

private let watchSnapshotDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func watchFoodProjectorPreservesRankOrderAndBoundsLifetime() throws {
    let presets = try (1 ... 5).map { value in
        try watchSnapshotPreset(value)
    }
    let snapshot = try FoodQuickLogProjector.project(
        presets: presets,
        usages: [],
        recentOccurrences: [],
        at: watchSnapshotDate,
        timeZoneID: "UTC"
    )

    let projected = try WatchFoodPresetSnapshotProjector.project(snapshot)

    #expect(projected.presets.count == 4)
    #expect(projected.presets.map(\.presetID) == snapshot.rankedPresets.map(\.preset.metadata.id))
    #expect(
        projected.expiresAt.timeIntervalSince(projected.generatedAt)
            == WatchFoodPresetSnapshotProjector.defaultLifetime
    )
    #expect(throws: WatchFoodPresetSnapshotProjectorError.invalidLifetime) {
        try WatchFoodPresetSnapshotProjector.project(snapshot, lifetime: 0)
    }
}

private func watchSnapshotPreset(_ value: Int) throws -> FoodPreset {
    let date = watchSnapshotDate.addingTimeInterval(TimeInterval(-value))
    return try FoodPreset(
        metadata: EntityMetadata(
            id: watchSnapshotIdentifier(value),
            createdAt: date,
            createdBy: ActorRef(actorType: .user, actorID: "owner"),
            lastRevisedAt: date,
            revision: 1,
            sensitivity: .sensitive,
            provenanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        ),
        name: "Preset \(value)",
        servingDescription: "1 portion",
        aliases: [],
        nutrients: nil
    )
}

private func watchSnapshotIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
