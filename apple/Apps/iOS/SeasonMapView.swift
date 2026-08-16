import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import SwiftUI

private enum SeasonMapPresentation: String, CaseIterable, Identifiable {
    case landscape
    case plainLanguage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape:
            "Landscape"
        case .plainLanguage:
            "Plain Language"
        }
    }
}

struct SeasonMapView: View {
    @EnvironmentObject private var model: OdysseyAppModel
    @State private var presentation: SeasonMapPresentation = .landscape

    let openWorkshop: () -> Void

    var body: some View {
        Group {
            if let version = acceptedSeasonVersion {
                if let season = try? SyncJSONCoding.makeDecoder().decode(
                    Season.self,
                    from: version.document
                ) {
                    mapContent(SeasonMapProjector.project(season))
                } else {
                    ContentUnavailableView(
                        "Accepted season unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(
                            "The immutable local history could not be decoded safely. "
                                + "Reload history before using it for orientation."
                        )
                    )
                }
            } else if model.state.workshopSnapshot == nil {
                ProgressView("Loading accepted season…")
            } else {
                ContentUnavailableView {
                    Label("No accepted season", systemImage: "map")
                } description: {
                    Text(
                        "The Map uses only immutable accepted Season history. Drafts and "
                            + "queued proposals never become orientation by implication."
                    )
                } actions: {
                    Button("Open Workshop", action: openWorkshop)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Map")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.refreshWorkshop() }
                }
                .disabled(model.state.workshopPhase.isBusy)
            }
        }
    }

    private var acceptedSeasonVersion: CachedLifeModelVersion? {
        model.state.workshopSnapshot?.acceptedVersions
            .filter { $0.kind == .season }
            .max { $0.acceptanceSequence < $1.acceptanceSequence }
    }

    private func mapContent(_ projection: SeasonMapProjection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(projection.title)
                        .font(.title2.weight(.semibold))
                    Text(projection.orientationStatement)
                        .font(.headline)
                    HStack {
                        Label(seasonStatusName(projection.status), systemImage: "sailboat")
                        Spacer()
                        Button("Revise in Workshop", action: openWorkshop)
                            .buttonStyle(.bordered)
                    }
                    .font(.subheadline)
                }
                .accessibilityElement(children: .combine)

                Picker("Map presentation", selection: $presentation) {
                    ForEach(SeasonMapPresentation.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                switch presentation {
                case .landscape:
                    SeasonLandscapePrototype(projection: projection)
                case .plainLanguage:
                    SeasonPlainLanguageMap(projection: projection)
                }

                Text(
                    "This prototype visualizes an accepted decision policy. It does not score "
                        + "the person, infer progress, or turn paths into a task list."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .refreshable { await model.refreshWorkshop() }
    }
}

private struct SeasonLandscapePrototype: View {
    let projection: SeasonMapProjection

    private var visiblePaths: [SeasonMapPath] {
        Array(projection.paths.prefix(5))
    }

    private var visibleLandmarks: [SeasonMapLandmark] {
        Array(projection.landmarks.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.indigo.opacity(0.16),
                                Color.teal.opacity(0.10),
                                Color(uiColor: .secondarySystemBackground),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                GeometryReader { proxy in
                    Canvas { context, size in
                        drawContours(context: &context, size: size)
                        drawProtectedTerrain(context: &context, size: size)
                        drawPaths(context: &context, size: size)
                        drawLandmarks(context: &context, size: size)
                    }
                    .accessibilityHidden(true)

                    ForEach(Array(visiblePaths.enumerated()), id: \.element.id) { entry in
                        MapPathLabel(path: entry.element)
                            .position(pathEndpoint(
                                index: entry.offset,
                                count: visiblePaths.count,
                                size: proxy.size
                            ))
                    }

                    ForEach(Array(visibleLandmarks.enumerated()), id: \.element.id) { entry in
                        MapLandmarkLabel(landmark: entry.element)
                            .position(landmarkPosition(
                                index: entry.offset,
                                count: visibleLandmarks.count,
                                size: proxy.size
                            ))
                    }

                    Label("Protected terrain", systemImage: "shield.lefthalf.filled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .position(x: proxy.size.width * 0.24, y: proxy.size.height * 0.90)
                }
                .padding(8)
            }
            .frame(height: 390)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Accepted season landscape")

            if projection.paths.count > visiblePaths.count {
                Text(
                    "The calm prototype shows five paths here; Plain Language lists all "
                        + "\(projection.paths.count)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            mapLegend
            landscapeContext
        }
    }

    private var mapLegend: some View {
        HStack(spacing: 12) {
            legendItem("Foreground", color: .indigo)
            legendItem("Supporting", color: .teal)
            legendItem("Dormant", color: .secondary)
            legendItem("Landmark", color: .orange)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var landscapeContext: some View {
        VStack(alignment: .leading, spacing: 10) {
            mapList(
                title: "Protected terrain",
                symbol: "shield",
                values: projection.protectedTerrain
            )
            mapList(
                title: "Open horizon",
                symbol: "sun.horizon",
                values: projection.openHorizon
            )
            mapList(
                title: "Deliberately not now",
                symbol: "moon.zzz",
                values: projection.deliberatelyDormant
            )
        }
    }

    private func drawContours(context: inout GraphicsContext, size: CGSize) {
        for offset in 0 ..< 4 {
            let inset = CGFloat(18 + offset * 24)
            let rect = CGRect(
                x: inset,
                y: inset * 0.7,
                width: max(0, size.width - inset * 2),
                height: max(0, size.height - inset * 1.5)
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Color.secondary.opacity(0.08)),
                lineWidth: 1
            )
        }
    }

    private func drawProtectedTerrain(context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(
            x: size.width * 0.04,
            y: size.height * 0.80,
            width: size.width * 0.55,
            height: size.height * 0.15
        )
        context.fill(
            Path(roundedRect: rect, cornerRadius: 22),
            with: .color(Color.teal.opacity(0.12))
        )
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 22),
            with: .color(Color.teal.opacity(0.35)),
            style: StrokeStyle(lineWidth: 1, dash: [5, 5])
        )
    }

    private func drawPaths(context: inout GraphicsContext, size: CGSize) {
        let origin = CGPoint(x: size.width * 0.12, y: size.height * 0.78)
        for (index, mapPath) in visiblePaths.enumerated() {
            let endpoint = pathEndpoint(index: index, count: visiblePaths.count, size: size)
            var path = Path()
            path.move(to: origin)
            path.addCurve(
                to: endpoint,
                control1: CGPoint(x: size.width * 0.30, y: origin.y - CGFloat(index * 12)),
                control2: CGPoint(x: endpoint.x - size.width * 0.20, y: endpoint.y + 20)
            )
            context.stroke(
                path,
                with: .color(mapPath.color.opacity(mapPath.emphasis == .background ? 0.45 : 0.8)),
                style: StrokeStyle(
                    lineWidth: mapPath.lineWidth,
                    lineCap: .round,
                    dash: mapPath.emphasis == .background ? [7, 7] : []
                )
            )
            context.fill(
                Path(ellipseIn: CGRect(
                    x: endpoint.x - 6,
                    y: endpoint.y - 6,
                    width: 12,
                    height: 12
                )),
                with: .color(mapPath.color)
            )
        }
    }

    private func drawLandmarks(context: inout GraphicsContext, size: CGSize) {
        for index in visibleLandmarks.indices {
            let point = landmarkPosition(
                index: index,
                count: visibleLandmarks.count,
                size: size
            )
            let outer = CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
            context.fill(Path(ellipseIn: outer), with: .color(Color.orange.opacity(0.18)))
            context.stroke(
                Path(ellipseIn: outer),
                with: .color(.orange),
                lineWidth: 2
            )
        }
    }

    private func pathEndpoint(index: Int, count: Int, size: CGSize) -> CGPoint {
        let denominator = CGFloat(max(count - 1, 1))
        let progress = CGFloat(index) / denominator
        return CGPoint(
            x: size.width * (0.55 + progress * 0.08),
            y: size.height * (0.18 + progress * 0.48)
        )
    }

    private func landmarkPosition(index: Int, count: Int, size: CGSize) -> CGPoint {
        let denominator = CGFloat(max(count - 1, 1))
        let progress = CGFloat(index) / denominator
        return CGPoint(
            x: size.width * 0.83,
            y: size.height * (0.20 + progress * 0.43)
        )
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    private func mapList(title: String, symbol: String, values: [String]) -> some View {
        DisclosureGroup {
            if values.isEmpty {
                Text("None recorded").foregroundStyle(.secondary)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { entry in
                    Text(entry.element)
                }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

private struct MapPathLabel: View {
    let path: SeasonMapPath

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path.title)
                .font(.caption.weight(.semibold))
            Text(path.detail)
                .font(.caption2)
                .lineLimit(2)
        }
        .padding(7)
        .frame(width: 132, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            Capsule().fill(path.color).frame(width: 3).padding(.vertical, 5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(path.title). \(path.detail)")
    }
}

private struct MapLandmarkLabel: View {
    let landmark: SeasonMapLandmark

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Landmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
            Text(landmark.title)
                .font(.caption)
                .lineLimit(2)
            if let detail = landmark.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .frame(width: 120, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct SeasonPlainLanguageMap: View {
    let projection: SeasonMapProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            plainGroup("Where am I?", symbol: "location.fill") {
                Text(projection.rationale)
                LabeledContent("Season status", value: seasonStatusName(projection.status))
                LabeledContent("Review cadence", value: projection.reviewCadence)
            }
            plainGroup("What matters now?", symbol: "point.topleft.down.to.point.bottomright.curvepath") {
                if projection.paths.isEmpty {
                    Text("No direction paths are recorded.").foregroundStyle(.secondary)
                } else {
                    ForEach(projection.paths) { path in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(path.color).frame(width: 8, height: 8)
                                Text(path.title).font(.headline)
                                Spacer()
                                Text(allocationName(path.allocationBand))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(path.detail)
                            if let boundary = path.boundary {
                                Label(boundary, systemImage: "shield")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            plainListGroup(
                "What must remain protected?",
                symbol: "shield.lefthalf.filled",
                values: projection.protectedTerrain
            )
            plainListGroup(
                "What is available?",
                symbol: "sun.horizon",
                values: projection.openHorizon
            )
            plainGroup("What landmarks could change the season?", symbol: "mappin.and.ellipse") {
                if projection.landmarks.isEmpty {
                    Text("No landmarks are recorded.").foregroundStyle(.secondary)
                } else {
                    ForEach(projection.landmarks) { landmark in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(landmark.title)
                            if let detail = landmark.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            plainListGroup(
                "What can be ignored for now?",
                symbol: "moon.zzz",
                values: projection.deliberatelyDormant
            )
        }
    }

    private func plainListGroup(
        _ title: String,
        symbol: String,
        values: [String]
    ) -> some View {
        plainGroup(title, symbol: symbol) {
            if values.isEmpty {
                Text("None recorded").foregroundStyle(.secondary)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { entry in
                    Text(entry.element)
                }
            }
        }
    }

    private func plainGroup<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

private extension SeasonMapPath {
    var color: Color {
        switch role {
        case .primary:
            .indigo
        case .foundation:
            .teal
        case .maintenance:
            .blue
        case .exploration:
            .purple
        case .dormant:
            .secondary
        }
    }

    var lineWidth: CGFloat {
        switch allocationBand {
        case .minimal:
            2
        case .low:
            3
        case .moderate:
            4
        case .high:
            5
        case .dominant:
            7
        }
    }
}

private func allocationName(_ allocation: AllocationBand) -> String {
    switch allocation {
    case .minimal:
        "Minimal attention"
    case .low:
        "Low attention"
    case .moderate:
        "Moderate attention"
    case .high:
        "High attention"
    case .dominant:
        "Dominant attention"
    }
}

private func seasonStatusName(_ status: SeasonStatus) -> String {
    switch status {
    case .draft:
        "Draft"
    case .calibration:
        "Calibration"
    case .active:
        "Active"
    case .transitioning:
        "Transitioning"
    case .complete:
        "Complete"
    case .abandoned:
        "Abandoned"
    }
}
