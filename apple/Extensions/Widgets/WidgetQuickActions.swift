import AppIntents
import Foundation
import OdysseyExtensionBridge
import SwiftUI
import WidgetKit

private enum WidgetCommandQueue {
    static func make() throws -> ExtensionCommandQueue {
        guard let appGroup = Bundle.main.object(
            forInfoDictionaryKey: "ODYSSEY_APP_GROUP"
        ) as? String,
            !appGroup.isEmpty
        else {
            throw ExtensionCommandError.appGroupUnavailable
        }
        return try ExtensionCommandQueue(
            rootDirectory: ExtensionCommandQueue.appGroupRoot(identifier: appGroup)
        )
    }
}

struct OpenCaptureFromWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Capture"
    static let description = IntentDescription(
        "Open Odyssey's private local capture sheet."
    )
    static let isDiscoverable = false
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let queue = try WidgetCommandQueue.make()
        let command = try ExtensionCommand.presentCapture(invokingSurface: .widget)
        try await queue.enqueue(command)
        return .result()
    }
}

struct OpenFoodFromWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Food Log"
    static let description = IntentDescription(
        "Open Odyssey's private ranked food sheet without exposing preset names."
    )
    static let isDiscoverable = false
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let queue = try WidgetCommandQueue.make()
        let command = try ExtensionCommand.presentFood(invokingSurface: .widget)
        try await queue.enqueue(command)
        return .result()
    }
}

struct OpenCaptureFromControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Odyssey Capture"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let queue = try WidgetCommandQueue.make()
        let command = try ExtensionCommand.presentCapture(invokingSurface: .control)
        try await queue.enqueue(command)
        return .result()
    }
}

struct OpenFoodFromControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Odyssey Food Log"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let queue = try WidgetCommandQueue.make()
        let command = try ExtensionCommand.presentFood(invokingSurface: .control)
        try await queue.enqueue(command)
        return .result()
    }
}

struct OdysseyCaptureControl: ControlWidget {
    static let kind = "OdysseyCaptureControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenCaptureFromControlIntent()) {
                Label("Capture", systemImage: "square.and.pencil")
            }
        }
        .displayName("Odyssey Capture")
        .description("Open private local capture in Odyssey.")
    }
}

struct OdysseyFoodControl: ControlWidget {
    static let kind = "OdysseyFoodControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenFoodFromControlIntent()) {
                Label("Log Food", systemImage: "fork.knife")
            }
        }
        .displayName("Odyssey Food")
        .description("Open Odyssey's private ranked food sheet.")
    }
}
