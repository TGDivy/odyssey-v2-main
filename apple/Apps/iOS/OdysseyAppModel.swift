import AuthenticationServices
import BackgroundTasks
import Combine
import CoreLocation
import Foundation
import OdysseyApplication
import OdysseyAuth
import OdysseyData
import OdysseySync
import UIKit

@MainActor
final class OdysseyAppModel: ObservableObject {
    @Published private(set) var state = ApplicationFeatureState()

    private var localServices: NativeLocalServices?
    private var remoteServices: NativeRemoteServices?
    private var isBootstrapping = false

    static var backgroundRefreshIdentifier: String {
        if let configured = Bundle.main.object(
            forInfoDictionaryKey: "ODYSSEY_BACKGROUND_REFRESH_IDENTIFIER"
        ) as? String,
            !configured.isEmpty
        {
            return configured
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.example.odyssey.app"
        if bundleIdentifier.hasSuffix(".app") {
            return String(bundleIdentifier.dropLast(4)) + ".refresh"
        }
        return bundleIdentifier + ".refresh"
    }

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        apply(.bootstrapStarted)
        localServices = nil
        remoteServices = nil

        let local: NativeLocalServices
        do {
            let localConfiguration = try makeLocalConfiguration()
            local = try await NativeLocalServices.bootstrap(
                configuration: localConfiguration
            )
            localServices = local
            apply(.localReady)
            await refreshDiagnostics()
            refreshRecentCaptures()
        } catch {
            apply(.localUnavailable(
                "Local storage could not be opened safely. No capture was attempted."
            ))
            return
        }

        do {
            let storedCredential = try await local.credentialVault.refreshCredential()
            apply(.enrollmentObserved(stored: storedCredential != nil))
        } catch {
            apply(.enrollmentFailed(
                "The local enrollment credential could not be read from Keychain."
            ))
        }

        do {
            let remoteConfiguration = try makeRemoteConfiguration()
            remoteServices = try NativeRemoteServices(
                localServices: local,
                configuration: remoteConfiguration
            )
            apply(.remoteReady)
            await refreshDiagnostics()
        } catch let error as NativeApplicationConfigurationError {
            apply(.remoteUnavailable(error.localizedDescription))
        } catch {
            apply(.remoteUnavailable(
                "Remote services could not be configured. Offline capture remains available."
            ))
        }

        if state.canSynchronize {
            await synchronize()
        }
    }

    func captureText(_ text: String) async -> Bool {
        guard let localServices, state.canCapture else { return false }
        apply(.captureStarted)
        do {
            let draft = try ManualCaptureDraft.text(
                text,
                timeZoneID: TimeZone.current.identifier,
                locationPermissionState: currentLocationPermissionState(),
                invokingSurface: .iPhoneNow
            )
            let receipt = try await localServices.captureService.record(draft)
            apply(.captureSucceeded(
                captureID: receipt.capture.metadata.id,
                at: receipt.capture.capturedAt
            ))
            await refreshDiagnostics()
            refreshRecentCaptures()
            scheduleBackgroundRefresh()
            if state.canSynchronize {
                Task { [weak self] in
                    await self?.synchronize()
                }
            }
            return true
        } catch let error as LocalizedError {
            apply(.captureFailed(error.errorDescription ?? "The capture was not saved."))
        } catch {
            apply(.captureFailed("The capture was not saved."))
        }
        return false
    }

    func dismissCaptureStatus() {
        apply(.captureDismissed)
    }

    func enrollWithApple() async {
        guard let remoteServices else { return }
        apply(.enrollmentStarted)
        guard state.enrollmentPhase == .authorizing else { return }
        do {
            let authorizer = SystemAppleAuthorizationPerformer {
                Self.presentationAnchor()
            }
            let coordinator = remoteServices.appleEnrollmentCoordinator(
                authorizer: authorizer
            )
            let metadata = try DeviceEnrollmentMetadata(
                displayName: UIDevice.current.model,
                platform: .iOS,
                appVersion: try appVersion()
            )
            _ = try await coordinator.enroll(metadata: metadata)
            apply(.enrollmentSucceeded)
            await refreshDiagnostics()
            await synchronize()
        } catch AppleEnrollmentError.cancelled {
            apply(.enrollmentFailed("Apple authorization was cancelled."))
        } catch let error as LocalizedError {
            apply(.enrollmentFailed(
                error.errorDescription ?? "This device was not enrolled."
            ))
        } catch {
            apply(.enrollmentFailed("This device was not enrolled."))
        }
    }

    func removeLocalEnrollment() async {
        guard let localServices else { return }
        do {
            if let remoteServices {
                try await remoteServices.tokenSession.clearEnrollment()
            } else {
                try await localServices.credentialVault.clearRefreshCredential()
            }
            apply(.enrollmentObserved(stored: false))
        } catch {
            apply(.enrollmentFailed(
                "The local enrollment credential could not be removed."
            ))
        }
    }

    func synchronize() async {
        guard let remoteServices, state.canSynchronize else { return }
        apply(.syncStarted)
        do {
            let report = try await remoteServices.syncCoordinator.synchronize()
            apply(.syncSucceeded(report))
            await refreshDiagnostics()
            refreshRecentCaptures()
            scheduleBackgroundRefresh()
        } catch AuthSessionError.notEnrolled,
                AuthSessionError.refreshCredentialExpired
        {
            apply(.enrollmentObserved(stored: false))
            apply(.syncFailed("This device needs Apple enrollment before it can sync."))
        } catch let error as LocalizedError {
            apply(.syncFailed(error.errorDescription ?? "Sync did not complete."))
            await refreshDiagnostics()
        } catch {
            apply(.syncFailed("Sync did not complete. Local changes remain queued."))
            await refreshDiagnostics()
        }
    }

    func performBackgroundRefresh() async {
        guard let remoteServices, state.canSynchronize else { return }
        await withTaskCancellationHandler {
            await synchronize()
        } onCancel: {
            Task {
                await remoteServices.syncCoordinator.cancelSynchronization()
            }
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(
            identifier: Self.backgroundRefreshIdentifier
        )
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func verifyLocalData() async {
        guard let localServices else { return }
        apply(.maintenanceStarted)
        do {
            try await localServices.ledgerStore.verifyIntegrity()
            apply(.maintenanceSucceeded("Local ledger integrity verified."))
        } catch {
            apply(.maintenanceFailed(
                "Local integrity verification failed. No repair was attempted."
            ))
        }
    }

    func rebuildLocalProjections() async {
        guard let localServices else { return }
        apply(.maintenanceStarted)
        do {
            try await localServices.ledgerStore.rebuildAll()
            apply(.maintenanceSucceeded("Local projections rebuilt from the ledger."))
            await refreshDiagnostics()
            refreshRecentCaptures()
        } catch {
            apply(.maintenanceFailed(
                "Projection rebuild failed. The immutable ledger was not changed."
            ))
        }
    }

    func dismissMaintenanceStatus() {
        apply(.maintenanceDismissed)
    }

    private func refreshDiagnostics() async {
        guard let localServices else { return }
        do {
            let diagnostics: NativeSyncDiagnostics
            if let remoteServices {
                diagnostics = try await remoteServices.syncCoordinator.localDiagnostics()
            } else {
                diagnostics = try await localServices.localDiagnostics()
            }
            apply(.diagnosticsUpdated(diagnostics))
        } catch {
            return
        }
    }

    private func refreshRecentCaptures() {
        guard let localServices else { return }
        do {
            apply(.recentCapturesUpdated(try localServices.recentCaptures()))
        } catch {
            return
        }
    }

    private func makeLocalConfiguration() throws -> NativeLocalConfiguration {
        guard let applicationIdentifier = Bundle.main.bundleIdentifier else {
            throw NativeApplicationConfigurationError.invalidApplicationIdentifier
        }
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try NativeLocalConfiguration(
            applicationIdentifier: applicationIdentifier,
            applicationSupportDirectory: applicationSupport.appendingPathComponent(
                "Odyssey",
                isDirectory: true
            )
        )
    }

    private func makeRemoteConfiguration() throws -> NativeRemoteConfiguration {
        guard let baseURLValue = Bundle.main.object(
            forInfoDictionaryKey: "ODYSSEY_API_BASE_URL"
        ) as? String,
            let baseURL = URL(string: baseURLValue)
        else {
            throw NativeApplicationConfigurationError.invalidRemoteBaseURL
        }
        guard let environmentValue = Bundle.main.object(
            forInfoDictionaryKey: "ODYSSEY_ENVIRONMENT"
        ) as? String,
            let environment = NativeDeploymentEnvironment(rawValue: environmentValue)
        else {
            throw NativeApplicationConfigurationError.invalidRemoteEnvironment
        }
        return try NativeRemoteConfiguration(
            baseURL: baseURL,
            environment: environment,
            platform: .iOS,
            appVersion: try appVersion()
        )
    }

    private func appVersion() throws -> String {
        guard let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
            let buildVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        else {
            throw NativeApplicationConfigurationError.invalidAppVersion
        }
        return "\(shortVersion) (\(buildVersion))"
    }

    private func currentLocationPermissionState() -> CaptureLocationPermissionState {
        switch CLLocationManager().authorizationStatus {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorizedWhenInUse:
            .authorizedWhenInUse
        case .authorizedAlways:
            .authorizedAlways
        @unknown default:
            .unavailable
        }
    }

    private func apply(_ action: ApplicationFeatureAction) {
        ApplicationFeatureReducer.reduce(state: &state, action: action)
    }

    private static func presentationAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap {
            $0 as? UIWindowScene
        }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let keyWindow = scene.windows.first(where: \.isKeyWindow) {
                return keyWindow
            }
            if let window = scene.windows.first {
                return window
            }
        }
        return UIWindow()
    }
}
