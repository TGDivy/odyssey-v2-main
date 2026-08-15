import SwiftUI

@main
struct OdysseyWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchCaptureView()
        }
    }
}

private struct WatchCaptureView: View {
    @State private var confirmation: String?

    var body: some View {
        NavigationStack {
            List {
                Button("Capture thought") { confirmation = "Ready for a short capture." }
                Button("Log meal preset") { confirmation = "Choose a preset on iPhone." }
                Button("Mark handled") { confirmation = "Marked locally." }
                if let confirmation {
                    Text(confirmation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Odyssey")
        }
    }
}

