import AppIntents

struct CaptureToOdysseyIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture to Odyssey"
    static let description = IntentDescription("Save a thought locally for later interpretation.")
    static let openAppWhenRun = true

    @Parameter(title: "Text")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Open Odyssey to confirm this capture.")
    }
}

struct PauseOdysseyIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Odyssey"
    static let description = IntentDescription("Open the global proactive-intelligence control.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Opening Odyssey's proactive controls.")
    }
}

struct OdysseyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureToOdysseyIntent(),
            phrases: ["Capture in \(.applicationName)", "Remember this in \(.applicationName)"],
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

