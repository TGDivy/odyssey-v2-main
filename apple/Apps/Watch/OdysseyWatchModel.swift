import Foundation
import OdysseyDomain
import OdysseyExtensionBridge
import OdysseyWatchConnectivity
import SwiftUI

@MainActor
final class OdysseyWatchModel: ObservableObject {
    @Published private(set) var foodSnapshot: WatchFoodPresetSnapshot?
    @Published private(set) var transportStatus = WatchCommandSenderStatus(
        activationState: .inactive,
        isReachable: false,
        pendingCommandCount: 0
    )
    @Published private(set) var confirmation: String?
    @Published private(set) var isSubmitting = false

    private var sender: WatchCommandSender?

    init() {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let queue = try ExtensionCommandQueue(
                rootDirectory: applicationSupport.appendingPathComponent(
                    "OdysseyWatch",
                    isDirectory: true
                )
            )
            guard let sender = WatchCommandSender(
                outbox: WatchCommandOutbox(queue: queue)
            ) else {
                transportStatus = WatchCommandSenderStatus(
                    activationState: .unavailable,
                    isReachable: false,
                    pendingCommandCount: 0
                )
                confirmation = "Watch transfer is unavailable on this device."
                return
            }
            self.sender = sender
            sender.onStatusChange = { [weak self] status in
                self?.transportStatus = status
            }
            sender.onFoodSnapshot = { [weak self] snapshot in
                self?.foodSnapshot = snapshot
            }
            sender.activate()
        } catch {
            transportStatus = WatchCommandSenderStatus(
                activationState: .unavailable,
                isReachable: false,
                pendingCommandCount: 0
            )
            confirmation = "Protected Watch storage could not be opened."
        }
    }

    var availableFoodPresets: [WatchFoodPresetReference] {
        guard let foodSnapshot,
              foodSnapshot.isFresh(at: Date())
        else {
            return []
        }
        return foodSnapshot.presets
    }

    var foodFreshnessMessage: String {
        guard let foodSnapshot else {
            return "Open Food on iPhone to send ranked presets."
        }
        guard foodSnapshot.isFresh(at: Date()) else {
            return "Food choices expired. Open Food on iPhone to refresh them."
        }
        return "From iPhone · updated \(foodSnapshot.generatedAt.formatted(date: .omitted, time: .shortened))"
    }

    var deliveryMessage: String {
        let pending = transportStatus.pendingCommandCount
        if pending > 0 {
            return "\(pending) protected command\(pending == 1 ? "" : "s") waiting for iPhone acceptance."
        }
        switch transportStatus.activationState {
        case .activated:
            return transportStatus.isReachable
                ? "iPhone is reachable."
                : "No pending commands. Background delivery remains available."
        case .activating:
            return "Connecting to iPhone…"
        case .inactive:
            return "Watch transfer is not active yet."
        case .unavailable:
            return "Watch transfer is unavailable."
        }
    }

    func activate() async {
        sender?.activate()
        await sender?.flush()
    }

    func capture(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let sender
        else {
            confirmation = "Enter a short note first."
            return false
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let command = try ExtensionCommand.captureText(
                trimmed,
                invokingSurface: .watch
            )
            try await sender.submit(command)
            confirmation = "Saved on Watch. Delivery does not block this capture."
            return true
        } catch {
            confirmation = "The note was not saved to protected Watch storage."
            return false
        }
    }

    func logFood(_ preset: WatchFoodPresetReference) async {
        guard availableFoodPresets.contains(preset),
              let sender
        else {
            confirmation = "Refresh food choices from iPhone before logging."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let now = Date()
            let command = try ExtensionCommand.logFood(
                presetID: preset.presetID,
                expectedPresetRevision: preset.revision,
                occurredAt: now,
                timeZoneID: TimeZone.current.identifier,
                createdAt: now,
                invokingSurface: .watch
            )
            try await sender.submit(command)
            confirmation = "Saved on Watch for protected iPhone handoff."
        } catch {
            confirmation = "The food command was not saved on Watch."
        }
    }
}
