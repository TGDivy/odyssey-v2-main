import SwiftUI

@main
struct OdysseyMacApp: App {
    var body: some Scene {
        WindowGroup {
            MacWorkspaceView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Capture") {}
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}

private struct MacWorkspaceView: View {
    @State private var selection = "Workshop"
    private let spaces = ["Now", "Map", "Archive", "Workshop", "Diagnostics"]

    var body: some View {
        NavigationSplitView {
            List(spaces, id: \.self, selection: $selection) { space in
                Label(space, systemImage: symbol(for: space))
            }
        } detail: {
            ContentUnavailableView(
                selection,
                systemImage: symbol(for: selection),
                description: Text("A durable desktop workspace for review and repair.")
            )
        }
    }

    private func symbol(for space: String) -> String {
        switch space {
        case "Now": "location.fill"
        case "Map": "map"
        case "Archive": "books.vertical"
        case "Diagnostics": "stethoscope"
        default: "slider.horizontal.3"
        }
    }
}

