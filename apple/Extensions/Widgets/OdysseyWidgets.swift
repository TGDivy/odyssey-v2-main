import AppIntents
import SwiftUI
import WidgetKit

struct OdysseyWidgetEntry: TimelineEntry {
    let date: Date
    let summary: String
    let freshness: String
}

struct OdysseyWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> OdysseyWidgetEntry {
        OdysseyWidgetEntry(date: Date(), summary: "Nothing requires attention", freshness: "Preview")
    }

    func getSnapshot(in _: Context, completion: @escaping (OdysseyWidgetEntry) -> Void) {
        completion(OdysseyWidgetEntry(date: Date(), summary: "Nothing requires attention", freshness: "Cached now"))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<OdysseyWidgetEntry>) -> Void) {
        let entry = OdysseyWidgetEntry(date: Date(), summary: "Nothing requires attention", freshness: "Cached now")
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct OdysseyWidgetView: View {
    let entry: OdysseyWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Now", systemImage: "location.fill")
                .font(.caption.weight(.semibold))
            Text(entry.summary)
                .font(.headline)
            Text(entry.freshness)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct OdysseyNowWidget: Widget {
    let kind = "OdysseyNowWidget"

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
