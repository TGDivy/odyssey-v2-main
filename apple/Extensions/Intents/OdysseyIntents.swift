import AppIntents
import Foundation
import OdysseyExtensionBridge

struct CaptureToOdysseyIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Odyssey"
    static let description = IntentDescription(
        "Save a thought locally for later interpretation."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let queue = try Self.queue()
        try await queue.enqueue(ExtensionCommand.captureText(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            invokingSurface: .appIntent
        ))
        return .result(
            dialog: "Saved securely for Odyssey. It will enter your local ledger when Odyssey next opens."
        )
    }

    private static func queue() throws -> ExtensionCommandQueue {
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

struct LogFoodInOdysseyIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Food"
    static let description = IntentDescription(
        "Open Odyssey's private ranked food presets without exposing food names to system suggestions."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Opening Odyssey's private food presets.")
    }
}

struct PauseOdysseyIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Odyssey"
    static let description = IntentDescription(
        "Open the global proactive-intelligence control."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Opening Odyssey's proactive controls.")
    }
}

struct OdysseyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogFoodInOdysseyIntent(),
            phrases: ["Log food in \(.applicationName)"],
            shortTitle: "Log Food",
            systemImageName: "fork.knife"
        )
        AppShortcut(
            intent: CaptureToOdysseyIntent(),
            phrases: [
                "Capture in \(.applicationName)",
                "Remember this in \(.applicationName)",
            ],
            shortTitle: "Capture",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: PauseOdysseyIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause",
            systemImageName: "pause.circle"
        )
    }
}
