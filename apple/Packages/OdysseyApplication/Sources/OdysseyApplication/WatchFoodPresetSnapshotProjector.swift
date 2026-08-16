import Foundation
import OdysseyExtensionBridge

public enum WatchFoodPresetSnapshotProjectorError: Error, Equatable, Sendable {
    case invalidLifetime
}

public enum WatchFoodPresetSnapshotProjector {
    public static let defaultLifetime: TimeInterval = 12 * 60 * 60

    public static func project(
        _ snapshot: FoodQuickLogSnapshot,
        lifetime: TimeInterval = defaultLifetime
    ) throws -> WatchFoodPresetSnapshot {
        guard lifetime.isFinite,
              lifetime > 0,
              lifetime <= WatchFoodPresetSnapshot.maximumLifetime
        else {
            throw WatchFoodPresetSnapshotProjectorError.invalidLifetime
        }
        let presets = try snapshot.rankedPresets
            .prefix(WatchFoodPresetSnapshot.maximumPresetCount)
            .map { ranked in
                try WatchFoodPresetReference(
                    presetID: ranked.preset.metadata.id,
                    revision: ranked.preset.metadata.revision,
                    name: ranked.preset.name,
                    servingDescription: ranked.preset.servingDescription
                )
            }
        return try WatchFoodPresetSnapshot(
            generatedAt: snapshot.generatedAt,
            expiresAt: snapshot.generatedAt.addingTimeInterval(lifetime),
            timeZoneID: snapshot.timeZoneID,
            presets: presets
        )
    }
}
