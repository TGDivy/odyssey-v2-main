import Foundation
import OdysseyApplication
import OdysseyDomain
import SwiftUI

struct FoodQuickLogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: OdysseyAppModel
    @State private var searchText = ""
    @State private var isCreatingPreset = false
    @State private var selectedOccurrence: FoodOccurrenceSelection?

    private var snapshot: FoodQuickLogSnapshot? {
        model.state.foodSnapshot
    }

    private var visiblePresets: [FoodPreset] {
        guard let snapshot else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshot.activePresets }
        return snapshot.activePresets.filter { preset in
            preset.name.localizedCaseInsensitiveContains(query)
                || preset.servingDescription.localizedCaseInsensitiveContains(query)
                || preset.aliases.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var isBusy: Bool {
        model.state.foodPhase.isBusy
    }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot {
                    foodList(snapshot)
                } else if case let .failed(message) = model.state.foodPhase {
                    ContentUnavailableView {
                        Label("Food library unavailable", systemImage: "fork.knife")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") {
                            Task { await model.refreshFoodQuickLog() }
                        }
                    }
                } else {
                    ProgressView("Loading food presets…")
                }
            }
            .navigationTitle("Log Food")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search presets"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isBusy)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreatingPreset = true
                    } label: {
                        Label("New Preset", systemImage: "plus")
                    }
                    .disabled(isBusy)
                }
            }
            .task {
                await model.refreshFoodQuickLog()
            }
            .sheet(isPresented: $isCreatingPreset) {
                FoodPresetEditorView()
                    .environmentObject(model)
            }
            .sheet(item: $selectedOccurrence) { selection in
                FoodOccurrenceCorrectionView(occurrence: selection.occurrence)
                    .environmentObject(model)
            }
        }
    }

    private func foodList(_ snapshot: FoodQuickLogSnapshot) -> some View {
        List {
            if case let .failed(message) = model.state.foodPhase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Dismiss Error") { model.dismissFoodStatus() }
                }
            }

            if snapshot.activePresets.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No food presets", systemImage: "fork.knife")
                    } description: {
                        Text("Create a reusable serving before logging it. Presets stay available offline.")
                    } actions: {
                        Button("Create Preset") { isCreatingPreset = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    ForEach(snapshot.rankedPresets, id: \.preset.metadata.id) { ranked in
                        quickLogButton(ranked.preset, reason: reasonText(ranked))
                    }
                } header: {
                    Text("Likely Now")
                } footer: {
                    Text("Up to four presets are ranked locally from recent and repeated context. Tap once to log one serving.")
                }
            }

            if !snapshot.activePresets.isEmpty {
                Section(searchText.isEmpty ? "All Presets" : "Search Results") {
                    if visiblePresets.isEmpty {
                        Text("No preset matches this search.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visiblePresets, id: \.metadata.id) { preset in
                            quickLogButton(preset, reason: nil)
                        }
                    }
                }
            }

            if !snapshot.recentOccurrences.isEmpty && searchText.isEmpty {
                Section {
                    ForEach(snapshot.recentOccurrences, id: \.metadata.id) { occurrence in
                        Button {
                            selectedOccurrence = FoodOccurrenceSelection(
                                occurrence: occurrence
                            )
                        } label: {
                            FoodOccurrenceRow(occurrence: occurrence)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                        .accessibilityHint("Opens correction and void actions")
                    }
                } header: {
                    Text("Recent Logs")
                } footer: {
                    Text("Corrections append a new revision. Voids preserve history as a tombstone.")
                }
            }
        }
        .refreshable { await model.refreshFoodQuickLog() }
    }

    private func quickLogButton(_ preset: FoodPreset, reason: String?) -> some View {
        Button {
            Task {
                if await model.logFood(preset: preset) {
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(preset.servingDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                nutrientSummary(preset.nutrients)
            }
            .contentShape(Rectangle())
        }
        .disabled(isBusy)
        .accessibilityLabel("Log one serving of \(preset.name)")
        .accessibilityHint("Saves locally before synchronization")
    }

    private func reasonText(_ ranked: RankedFoodPreset) -> String {
        switch ranked.reason {
        case .oftenInSimilarContext:
            "Often logged around this time"
        case .frequentRecently:
            "Logged recently"
        case .frequentOverall:
            "Logged often"
        case .notUsedYet:
            "Not logged yet"
        }
    }

    @ViewBuilder
    private func nutrientSummary(_ nutrients: FoodNutrientProfile?) -> some View {
        if let energy = nutrients?.energyKilocalories {
            Text("\(energy.formatted(.number.precision(.fractionLength(0)))) kcal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FoodOccurrenceSelection: Identifiable {
    let occurrence: FoodOccurrence

    var id: UUIDv7 { occurrence.metadata.id }
}

private struct FoodOccurrenceRow: View {
    let occurrence: FoodOccurrence

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.presetNameSnapshot)
                    .font(.headline)
                Text("\(occurrence.quantity.formatted()) × \(occurrence.servingDescriptionSnapshot)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(occurrence.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct FoodPresetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: OdysseyAppModel
    @State private var name = ""
    @State private var serving = ""
    @State private var aliases = ""
    @State private var energy = ""
    @State private var protein = ""
    @State private var caffeine = ""
    @State private var alcohol = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset") {
                    TextField("Name", text: $name)
                    TextField("Serving, for example 1 bowl", text: $serving)
                    TextField("Aliases, comma separated", text: $aliases)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    nutrientField("Energy", unit: "kcal", text: $energy)
                    nutrientField("Protein", unit: "g", text: $protein)
                    nutrientField("Caffeine", unit: "mg", text: $caffeine)
                    nutrientField("Alcohol", unit: "g", text: $alcohol)
                } header: {
                    Text("Optional Per-Serving Values")
                } footer: {
                    Text("Values are stored as your estimate. Creating a preset does not request Health access or write to Apple Health.")
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if case let .failed(message) = model.state.foodPhase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Food Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.state.foodPhase.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            model.state.foodPhase.isBusy
                                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || serving.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
    }

    private func nutrientField(
        _ title: String,
        unit: String,
        text: Binding<String>
    ) -> some View {
        HStack {
            TextField(title, text: text)
                .keyboardType(.decimalPad)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        do {
            let values = try [energy, protein, caffeine, alcohol].map(parseNumber)
            let nutrients: FoodNutrientProfile?
            if values.contains(where: { $0 != nil }) {
                nutrients = try FoodNutrientProfile(
                    energyKilocalories: values[0],
                    proteinGrams: values[1],
                    caffeineMilligrams: values[2],
                    alcoholGrams: values[3],
                    sourceKind: .ownerEstimate
                )
            } else {
                nutrients = nil
            }
            let aliasValues = aliases.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let draft = FoodPresetDraft(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                servingDescription: serving.trimmingCharacters(in: .whitespacesAndNewlines),
                aliases: aliasValues,
                nutrients: nutrients
            )
            validationMessage = nil
            Task {
                if await model.createFoodPreset(draft) {
                    dismiss()
                }
            }
        } catch {
            validationMessage = "Enter each nutrient as a nonnegative number, or leave it blank."
        }
    }

    private func parseNumber(_ source: String) throws -> Double? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let number = Double(value.replacingOccurrences(of: ",", with: ".")),
              number.isFinite,
              number >= 0
        else {
            throw FoodPresetValidationError.invalidNutrientValue("numeric")
        }
        return number
    }
}

private struct FoodOccurrenceCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: OdysseyAppModel
    let occurrence: FoodOccurrence
    @State private var selectedPresetID: UUIDv7
    @State private var quantity: Double
    @State private var occurredAt: Date
    @State private var confirmsVoid = false

    init(occurrence: FoodOccurrence) {
        self.occurrence = occurrence
        _selectedPresetID = State(initialValue: occurrence.presetID)
        _quantity = State(initialValue: occurrence.quantity)
        _occurredAt = State(initialValue: occurrence.occurredAt)
    }

    private var presets: [FoodPreset] {
        model.state.foodSnapshot?.activePresets ?? []
    }

    private var selectedPreset: FoodPreset? {
        presets.first { $0.metadata.id == selectedPresetID } ?? presets.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Correction") {
                    Picker("Preset", selection: $selectedPresetID) {
                        ForEach(presets, id: \.metadata.id) { preset in
                            Text(preset.name).tag(preset.metadata.id)
                        }
                    }
                    HStack {
                        Text("Quantity")
                        Spacer()
                        TextField("Quantity", value: $quantity, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    DatePicker(
                        "Occurred",
                        selection: $occurredAt,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                Section {
                    Button("Void This Log", role: .destructive) {
                        confirmsVoid = true
                    }
                } footer: {
                    Text("Save appends a correction revision. Void hides the log while preserving its immutable history.")
                }
                if case let .failed(message) = model.state.foodPhase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Correct Food Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.state.foodPhase.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            selectedPreset == nil
                                || !quantity.isFinite
                                || quantity <= 0
                                || quantity > FoodOccurrence.maximumQuantity
                                || model.state.foodPhase.isBusy
                        )
                }
            }
            .confirmationDialog(
                "Void this food log?",
                isPresented: $confirmsVoid,
                titleVisibility: .visible
            ) {
                Button("Void Log", role: .destructive) {
                    Task {
                        if await model.voidFoodOccurrence(occurrence) {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("The log will disappear from active history, but its revisions remain auditable.")
            }
            .onAppear {
                if !presets.contains(where: { $0.metadata.id == selectedPresetID }),
                   let first = presets.first
                {
                    selectedPresetID = first.metadata.id
                }
            }
        }
    }

    private func save() {
        guard let selectedPreset else { return }
        Task {
            if await model.correctFoodOccurrence(
                occurrence,
                preset: selectedPreset,
                quantity: quantity,
                occurredAt: occurredAt
            ) {
                dismiss()
            }
        }
    }
}
