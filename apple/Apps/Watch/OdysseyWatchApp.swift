import SwiftUI

@main
struct OdysseyWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = OdysseyWatchModel()

    var body: some Scene {
        WindowGroup {
            WatchCaptureView()
                .environmentObject(model)
                .task {
                    await model.activate()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await model.activate()
                    }
                }
        }
    }
}

private struct WatchCaptureView: View {
    @EnvironmentObject private var model: OdysseyWatchModel
    @State private var note = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Capture") {
                    TextField("Short note", text: $note)
                    Button {
                        Task {
                            if await model.capture(note) {
                                note = ""
                            }
                        }
                    } label: {
                        Label("Save note", systemImage: "square.and.pencil")
                    }
                    .disabled(
                        model.isSubmitting
                            || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                Section("Food") {
                    if model.availableFoodPresets.isEmpty {
                        Text(model.foodFreshnessMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.availableFoodPresets, id: \.presetID) { preset in
                            Button {
                                Task { await model.logFood(preset) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                    Text(preset.servingDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .privacySensitive()
                            }
                            .disabled(model.isSubmitting)
                        }
                        Text(model.foodFreshnessMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Delivery") {
                    Text(model.deliveryMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let confirmation = model.confirmation {
                    Text(confirmation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Odyssey")
        }
    }
}
