import OdysseyIntelligence
import SwiftUI

private enum PrimarySpace: Hashable {
    case now
    case map
    case archive
    case workshop
}

struct RootView: View {
    @State private var selection: PrimarySpace = .now

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { NowView() }
                .tabItem { Label("Now", systemImage: "location.fill") }
                .tag(PrimarySpace.now)
            NavigationStack { PlaceholderSpace(title: "Map", symbol: "map") }
                .tabItem { Label("Map", systemImage: "map") }
                .tag(PrimarySpace.map)
            NavigationStack { PlaceholderSpace(title: "Archive", symbol: "books.vertical") }
                .tabItem { Label("Archive", systemImage: "books.vertical") }
                .tag(PrimarySpace.archive)
            NavigationStack { PlaceholderSpace(title: "Workshop", symbol: "slider.horizontal.3") }
                .tabItem { Label("Workshop", systemImage: "slider.horizontal.3") }
                .tag(PrimarySpace.workshop)
        }
    }
}

private struct NowView: View {
    private let state = DeterministicContextProjector().project(
        DeterministicContextInput(
            unresolvedDecisionCount: 0,
            preparationDeadlineCount: 0,
            materialHealthConstraintCount: 0,
            disruptionCount: 0,
            explicitlyOpen: false
        )
    )

    var body: some View {
        ContentUnavailableView {
            Label("Nothing requires attention", systemImage: "water.waves")
        } description: {
            Text("Odyssey is intentionally quiet. Your current state is \(state.rawValue).")
        } actions: {
            Button("Capture") {}
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Now")
    }
}

private struct PlaceholderSpace: View {
    let title: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text("Available offline as this edition grows."))
            .navigationTitle(title)
    }
}

