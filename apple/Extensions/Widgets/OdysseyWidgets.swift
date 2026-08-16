import AppIntents
import OdysseyExtensionBridge
import OdysseyIntelligence
import SwiftUI
import WidgetKit

enum OdysseyWidgetFreshness: Equatable {
    case preview
    case current
    case stale
    case unavailable
}

struct OdysseyWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: NowWidgetSnapshot?
    let freshness: OdysseyWidgetFreshness
}

struct OdysseyWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> OdysseyWidgetEntry {
        OdysseyWidgetEntry(date: Date(), snapshot: nil, freshness: .preview)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (OdysseyWidgetEntry) -> Void
    ) {
        let date = Date()
        completion(context.isPreview ? placeholder(in: context) : entry(at: date))
    }

    func getTimeline(
        in _: Context,
        completion: @escaping (Timeline<OdysseyWidgetEntry>) -> Void
    ) {
        let date = Date()
        let current = entry(at: date)
        var entries = [current]
        if current.freshness == .current,
           let snapshot = current.snapshot
        {
            let staleDate = max(
                snapshot.expiresAt.addingTimeInterval(1),
                date.addingTimeInterval(5 * 60)
            )
            entries.append(OdysseyWidgetEntry(
                date: staleDate,
                snapshot: snapshot,
                freshness: .stale
            ))
        }
        let reloadAfter = max(
            entries.last?.date.addingTimeInterval(30 * 60)
                ?? date.addingTimeInterval(30 * 60),
            date.addingTimeInterval(30 * 60)
        )
        completion(Timeline(entries: entries, policy: .after(reloadAfter)))
    }

    private func entry(at date: Date) -> OdysseyWidgetEntry {
        guard let snapshot = Self.loadSnapshot() else {
            return OdysseyWidgetEntry(
                date: date,
                snapshot: nil,
                freshness: .unavailable
            )
        }
        return OdysseyWidgetEntry(
            date: date,
            snapshot: snapshot,
            freshness: snapshot.isFresh(at: date) ? .current : .stale
        )
    }

    private static func loadSnapshot() -> NowWidgetSnapshot? {
        guard let appGroup = Bundle.main.object(
            forInfoDictionaryKey: "ODYSSEY_APP_GROUP"
        ) as? String,
            !appGroup.isEmpty,
            let root = try? ExtensionCommandQueue.appGroupRoot(identifier: appGroup),
            let store = try? NowWidgetSnapshotStore(rootDirectory: root)
        else {
            return nil
        }
        return try? store.read()
    }
}

struct OdysseyWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: OdysseyWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Now", systemImage: "location.fill")
                .font(.caption.weight(.semibold))

            snapshotContent
                .privacySensitive(entry.snapshot?.privacySensitive ?? false)

            if family != .accessoryRectangular {
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Button(intent: OpenCaptureFromWidgetIntent()) {
                        Label("Capture", systemImage: "square.and.pencil")
                    }
                    Button(intent: OpenFoodFromWidgetIntent()) {
                        Label("Food", systemImage: "fork.knife")
                    }
                }
                .font(.caption.weight(.semibold))
                .labelStyle(.iconOnly)
                .accessibilityElement(children: .contain)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var snapshotContent: some View {
        switch entry.freshness {
        case .preview:
            Text("Nothing requires attention")
                .font(.headline)
            Text("Private local preview")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .redacted(reason: .placeholder)
        case .unavailable:
            Text("Open Odyssey to prepare Now")
                .font(.headline)
            Text("No private local snapshot is available.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .stale:
            Label("Context is stale", systemImage: "clock.badge.exclamationmark")
                .font(.headline)
            Text("Open Odyssey to refresh the private local snapshot.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            freshnessLabel(prefix: "Last updated")
        case .current:
            if let snapshot = entry.snapshot {
                Label(snapshot.state.ownerTitle, systemImage: snapshot.state.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.state.tint)
                Text(snapshot.summary)
                    .font(.headline)
                    .lineLimit(family == .systemMedium ? 3 : 2)
                if family == .systemMedium,
                   let tomorrowSummary = snapshot.tomorrowSummary
                {
                    Text(tomorrowSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                freshnessLabel(prefix: "Updated")
            }
        }
    }

    private func freshnessLabel(prefix: String) -> some View {
        HStack(spacing: 3) {
            Text(prefix)
            if let generatedAt = entry.snapshot?.generatedAt {
                Text(generatedAt, style: .relative)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private extension NowState {
    var ownerTitle: String {
        switch self {
        case .clear: "Clear"
        case .choice: "Choice"
        case .preparation: "Preparation"
        case .recovery: "Recovery"
        case .open: "Open"
        case .disrupted: "Disrupted"
        }
    }

    var systemImage: String {
        switch self {
        case .clear: "water.waves"
        case .choice: "arrow.triangle.branch"
        case .preparation: "checklist"
        case .recovery: "heart.text.square"
        case .open: "wind"
        case .disrupted: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .clear: .teal
        case .choice: .orange
        case .preparation: .blue
        case .recovery: .mint
        case .open: .green
        case .disrupted: .red
        }
    }
}

struct OdysseyNowWidget: Widget {
    let kind = NowWidgetSnapshotStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OdysseyWidgetProvider()) { entry in
            OdysseyWidgetView(entry: entry)
        }
        .configurationDisplayName("Odyssey Now")
        .description("A cached, freshness-aware view of what deserves attention.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct OdysseyWidgetBundle: WidgetBundle {
    var body: some Widget {
        OdysseyNowWidget()
        OdysseyCaptureControl()
        OdysseyFoodControl()
    }
}
