import SwiftUI

@MainActor
@main
struct OdysseyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = OdysseyAppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task {
                    await model.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        model.scheduleBackgroundRefresh()
                    } else if newPhase == .active {
                        Task {
                            await model.processPendingExtensionCommands()
                        }
                    }
                }
        }
        .backgroundTask(
            .appRefresh(OdysseyAppModel.backgroundRefreshIdentifier)
        ) {
            await model.performBackgroundRefresh()
        }
    }
}
