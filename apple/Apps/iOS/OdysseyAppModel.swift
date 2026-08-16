import AuthenticationServices
import BackgroundTasks
import Combine
import CoreLocation
import Foundation
import OdysseyApplication
import OdysseyAuth
import OdysseyCalendar
import OdysseyData
import OdysseyDomain
import OdysseyExtensionBridge
import OdysseyHealth
import OdysseyIntelligence
import OdysseyIntegrations
import OdysseyLocation
import OdysseySync
import OdysseyTelemetry
import OdysseyWatchConnectivity
import OdysseyWeather
import UIKit
import WidgetKit

private enum CaptureReviewApplicationError: Error, LocalizedError {
    case localDataUnavailable
    case unexpectedDeferral(CaptureInterpretationDeferralReason)

    var errorDescription: String? {
        switch self {
        case .localDataUnavailable:
            "Local capture history is not available yet."
        case let .unexpectedDeferral(reason):
            "The owner review was not recorded because it was deferred: \(reason.rawValue)."
        }
    }
}

@MainActor
final class OdysseyAppModel: ObservableObject {
    @Published private(set) var state = ApplicationFeatureState()
    @Published private(set) var foodHealthAuthorization: FoodHealthAuthorizationState = .unavailable
    @Published private(set) var foodHealthMessage: String?
    @Published private(set) var foodWarmPathMeasurement: WarmPathMeasurement?
    @Published private(set) var extensionCommandMessage: String?
    @Published private(set) var extensionPresentationRequest: ExtensionCommandPresentation?
    @Published private(set) var healthContextState = HealthContextIntegrationState()
    @Published private(set) var calendarContextState = CalendarContextIntegrationState()
    @Published private(set) var locationContextState = LocationContextIntegrationState()
    @Published private(set) var weatherContextState = WeatherContextIntegrationState()
    @Published private(set) var nowContextProjection: NativeNowContextProjection?
    @Published private(set) var reentrySurface: ReentrySurface?
    @Published private(set) var nowExperienceMessage: String?
    @Published private(set) var productTelemetryMessage: String?
    @Published private(set) var weeklyProductReview: WeeklyProductReviewArtifact?
    @Published private(set) var weeklyProductReviewMessage: String?
    @Published private(set) var isLoadingWeeklyProductReview = false
    @Published private(set) var productTelemetryPrivacySnapshot: ProductTelemetryPrivacySnapshot?
    @Published private(set) var productTelemetryPrivacyMessage: String?
    @Published private(set) var isLoadingProductTelemetryPrivacy = false

    private var localServices: NativeLocalServices?
    private var remoteServices: NativeRemoteServices?
    private var workshopDraftFactory: LifeModelWorkshopDraftFactory?
    private var isBootstrapping = false
    private var isDrainingExtensionCommands = false
    private var nowRefreshGeneration: UInt64 = 0
    private var extensionCommandQueue: ExtensionCommandQueue?
    private var extensionCommandProcessor: ExtensionCommandProcessor?
    private var nowWidgetSnapshotStore: NowWidgetSnapshotStore?
    private var watchCommandReceiver: PhoneWatchCommandReceiver?
    private var tomorrowMapTelemetrySession: TomorrowMapProductTelemetrySession?
    private var isStartingTomorrowMapTelemetrySession = false
    private var tomorrowMapTelemetryGeneration: UInt64 = 0
    private let telemetryRecorder: any TelemetryRecording

    #if canImport(HealthKit)
    private let foodHealthCoordinator = FoodHealthWriteCoordinator(
        writer: HealthKitFoodWriter()
    )
    #endif

    init(telemetryRecorder: any TelemetryRecording = NoOpTelemetryRecorder()) {
        self.telemetryRecorder = telemetryRecorder
    }

    var captureImportBuffer: LocalCaptureImportBuffer? {
        localServices?.captureImportBuffer
    }

    var deviceCapabilityMatrix: DeviceCapabilityMatrix? {
        try? NativeIntegrationCapabilityMatrix.make(
            device: UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone,
            health: healthContextState.overview,
            healthNutrientWritePermission: foodHealthIntegrationPermission,
            calendar: calendarContextState.overview,
            weather: weatherContextState.overview,
            location: locationContextState.overview
        )
    }

    var integrationHealthCatalog: IntegrationHealthCatalog? {
        try? IntegrationHealthCatalog(snapshots: [
            healthContextState.integrationHealth,
            calendarContextState.integrationHealth,
            weatherContextState.integrationHealth,
            locationContextState.integrationHealth,
        ].compactMap { $0 })
    }

    private var foodHealthIntegrationPermission: IntegrationPermissionState {
        switch foodHealthAuthorization {
        case .unavailable:
            .unavailable
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        }
    }

    func verifiedCaptureContentURL(
        for reference: CaptureAttachmentReference
    ) async throws -> URL {
        guard let localServices else {
            throw CaptureReviewApplicationError.localDataUnavailable
        }
        return try await localServices.captureAttachmentStore.verifiedContentURL(
            for: reference
        )
    }

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
        await finishTomorrowMapTelemetrySession(outcome: .dismissed)
        apply(.bootstrapStarted)
        localServices = nil
        remoteServices = nil
        workshopDraftFactory = nil
        extensionCommandQueue = nil
        extensionCommandProcessor = nil
        nowWidgetSnapshotStore = nil
        watchCommandReceiver = nil
        tomorrowMapTelemetrySession = nil
        isStartingTomorrowMapTelemetrySession = false
        foodWarmPathMeasurement = nil
        extensionCommandMessage = nil
        extensionPresentationRequest = nil
        nowRefreshGeneration &+= 1
        nowContextProjection = nil
        reentrySurface = nil
        nowExperienceMessage = nil
        productTelemetryMessage = nil
        weeklyProductReview = nil
        weeklyProductReviewMessage = nil
        isLoadingWeeklyProductReview = false
        productTelemetryPrivacySnapshot = nil
        productTelemetryPrivacyMessage = nil
        isLoadingProductTelemetryPrivacy = false
        healthContextState = HealthContextIntegrationState()
        calendarContextState = CalendarContextIntegrationState()
        locationContextState = LocationContextIntegrationState()
        weatherContextState = WeatherContextIntegrationState()

        let local: NativeLocalServices
        do {
            let localConfiguration = try makeLocalConfiguration()
            workshopDraftFactory = try LifeModelWorkshopDraftFactory(
                ownerActorID: localConfiguration.ownerActorID,
                timeZoneID: TimeZone.current.identifier
            )
            local = try await NativeLocalServices.bootstrap(
                configuration: localConfiguration
            )
            localServices = local
            extensionCommandProcessor = ExtensionCommandProcessor(
                store: local.ledgerStore,
                captureService: local.captureService,
                foodOccurrenceService: local.foodOccurrenceService
            )
            do {
                let rootDirectory = try makeAppGroupRoot()
                let queue = try ExtensionCommandQueue(rootDirectory: rootDirectory)
                nowWidgetSnapshotStore = try NowWidgetSnapshotStore(
                    rootDirectory: rootDirectory
                )
                extensionCommandQueue = queue
                if let receiver = PhoneWatchCommandReceiver(commandQueue: queue) {
                    receiver.onCommandAccepted = { [weak self] in
                        await self?.processPendingExtensionCommands()
                    }
                    watchCommandReceiver = receiver
                    receiver.activate()
                }
            } catch {
                extensionCommandMessage =
                    "Extension quick capture is unavailable until the App Group is configured."
                nowExperienceMessage =
                    "The Now widget cache is unavailable until the App Group is configured."
            }
            apply(.localReady)
            await refreshDiagnostics()
            refreshRecentCaptures()
            await refreshWorkshop()
            await refreshFoodQuickLog()
            await refreshHealthContextStatus()
            await refreshCalendarContextStatus()
            await refreshLocationContextStatus()
            await refreshWeatherContextStatus()
            await drainExtensionCommands()
            await refreshNowExperience(markSeen: true)
            if foodHealthAuthorization == .authorized {
                Task { [weak self] in
                    await self?.reconcileFoodHealthWrites()
                }
            }
            Task { [weak self] in
                await self?.resumePendingCaptureInterpretations()
            }
            if NativeIntegrationActivationPolicy.shouldResumeHealthImport(
                healthContextState.overview
            ) {
                Task { [weak self] in
                    await self?.importHealthContext(
                        showCompletionMessage: false,
                        requiresExistingActivation: true
                    )
                }
            }
            if NativeIntegrationActivationPolicy.shouldResumeCalendarMirror(
                calendarContextState.overview
            ) {
                Task { [weak self] in
                    await self?.refreshCalendarContext(
                        showCompletionMessage: false,
                        requiresExistingMirror: true
                    )
                }
            }
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
            await completeCapture(receipt)
            return true
        } catch let error as LocalizedError {
            apply(.captureFailed(error.errorDescription ?? "The capture was not saved."))
        } catch {
            apply(.captureFailed("The capture was not saved."))
        }
        return false
    }

    func captureVoiceRecording(at sourceURL: URL) async -> Bool {
        await captureMediaFile(
            at: sourceURL,
            kind: .audio,
            mediaType: "audio/mp4",
            failureMessage: "The voice capture was not saved."
        )
    }

    func captureImportedMedia(
        at sourceURL: URL,
        kind: CapturePayloadKind,
        mediaType: String
    ) async -> Bool {
        guard kind == .imageReference || kind == .fileReference else { return false }
        return await captureMediaFile(
            at: sourceURL,
            kind: kind,
            mediaType: mediaType,
            failureMessage: "The selected item was not saved."
        )
    }

    private func captureMediaFile(
        at sourceURL: URL,
        kind: CapturePayloadKind,
        mediaType: String,
        failureMessage: String
    ) async -> Bool {
        guard let localServices, state.canCapture else { return false }
        apply(.captureStarted)
        do {
            let receipt = try await localServices.mediaCaptureService.record(
                LocalMediaCaptureDraft(
                    source: .file(sourceURL),
                    kind: kind,
                    mediaType: mediaType,
                    timeZoneID: TimeZone.current.identifier,
                    locationPermissionState: currentLocationPermissionState(),
                    invokingSurface: .iPhoneGlobalCapture
                )
            )
            await completeCapture(receipt.captureReceipt)
            return true
        } catch let error as LocalizedError {
            apply(.captureFailed(error.errorDescription ?? failureMessage))
        } catch {
            apply(.captureFailed(failureMessage))
        }
        return false
    }

    func dismissCaptureStatus() {
        apply(.captureDismissed)
    }

    func refreshFoodQuickLog() async {
        guard localServices != nil, state.localReadiness == .ready else { return }
        apply(.foodLoadStarted)
        do {
            let snapshot = try await foodQuickLogSnapshot(at: Date())
            apply(.foodLoaded(snapshot))
            publishWatchFoodSnapshot(snapshot)
            await refreshFoodHealthAuthorization()
        } catch let error as LocalizedError {
            apply(.foodFailed(
                error.errorDescription ?? "The food library could not be read safely."
            ))
        } catch {
            apply(.foodFailed("The food library could not be read safely."))
        }
    }

    func createFoodPreset(_ draft: FoodPresetDraft) async -> Bool {
        guard let localServices, state.canUseFoodQuickLog else { return false }
        apply(.foodMutationStarted)
        do {
            let receipt = try await localServices.foodPresetService.create(
                draft,
                sensitivity: .sensitive
            )
            await completeFoodMutation(.presetCreated(receipt.preset.metadata.id))
            await refreshFoodHealthAuthorization()
            return true
        } catch let error as LocalizedError {
            apply(.foodFailed(error.errorDescription ?? "The food preset was not saved."))
        } catch {
            apply(.foodFailed("The food preset was not saved."))
        }
        return false
    }

    func logFood(
        preset: FoodPreset,
        quantity: Double = 1,
        occurredAt: Date = Date()
    ) async -> Bool {
        guard let localServices, state.canUseFoodQuickLog else { return false }
        apply(.foodMutationStarted)
        do {
            let receipt = try await localServices.foodOccurrenceService.record(
                FoodOccurrenceDraft(
                    presetID: preset.metadata.id,
                    expectedPresetRevision: preset.metadata.revision,
                    quantity: quantity,
                    occurredAt: occurredAt,
                    timeZoneID: TimeZone.current.identifier
                )
            )
            await completeFoodMutation(.occurrenceRecorded(
                receipt.occurrence.metadata.id,
                at: receipt.occurrence.occurredAt
            ))
            Task { [weak self, occurrence = receipt.occurrence] in
                await self?.writeFoodOccurrenceToHealth(occurrence)
            }
            return true
        } catch let error as LocalizedError {
            apply(.foodFailed(error.errorDescription ?? "The food was not logged."))
        } catch {
            apply(.foodFailed("The food was not logged."))
        }
        return false
    }

    func correctFoodOccurrence(
        _ occurrence: FoodOccurrence,
        preset: FoodPreset,
        quantity: Double,
        occurredAt: Date
    ) async -> Bool {
        guard let localServices, state.canUseFoodQuickLog else { return false }
        apply(.foodMutationStarted)
        do {
            let receipt = try await localServices.foodOccurrenceService.correct(
                occurrenceID: occurrence.metadata.id,
                draft: FoodOccurrenceCorrectionDraft(
                    expectedOccurrenceRevision: occurrence.metadata.revision,
                    presetID: preset.metadata.id,
                    expectedPresetRevision: preset.metadata.revision,
                    quantity: quantity,
                    occurredAt: occurredAt,
                    timeZoneID: TimeZone.current.identifier
                )
            )
            await completeFoodMutation(.occurrenceCorrected(
                receipt.occurrence.metadata.id,
                at: receipt.occurrence.metadata.lastRevisedAt
            ))
            Task { [weak self, occurrence = receipt.occurrence] in
                await self?.writeFoodOccurrenceToHealth(
                    occurrence,
                    replacingExisting: true
                )
            }
            return true
        } catch let error as LocalizedError {
            apply(.foodFailed(error.errorDescription ?? "The correction was not saved."))
        } catch {
            apply(.foodFailed("The correction was not saved."))
        }
        return false
    }

    func voidFoodOccurrence(_ occurrence: FoodOccurrence) async -> Bool {
        guard let localServices, state.canUseFoodQuickLog else { return false }
        apply(.foodMutationStarted)
        do {
            let receipt = try await localServices.foodOccurrenceService.void(
                occurrenceID: occurrence.metadata.id,
                expectedRevision: occurrence.metadata.revision
            )
            await completeFoodMutation(.occurrenceVoided(
                receipt.occurrence.metadata.id,
                at: receipt.occurrence.metadata.lastRevisedAt
            ))
            Task { [weak self, occurrenceID = receipt.occurrence.metadata.id] in
                await self?.deleteFoodOccurrenceFromHealth(occurrenceID)
            }
            return true
        } catch let error as LocalizedError {
            apply(.foodFailed(error.errorDescription ?? "The food log was not voided."))
        } catch {
            apply(.foodFailed("The food log was not voided."))
        }
        return false
    }

    func dismissFoodStatus() {
        apply(.foodDismissed)
    }

    func beginFoodWarmPath(
        surface: WarmPathSurface,
        correlationID: UUID
    ) -> WarmPathTimingToken? {
        foodWarmPathMeasurement = nil
        return try? WarmPathTimer.start(
            workflow: .foodQuickLog,
            surface: surface,
            initialInteractionCount: 1,
            correlationID: correlationID
        )
    }

    func completeFoodWarmPath(_ token: WarmPathTimingToken) {
        guard let measurement = try? WarmPathTimer.finish(
            token,
            outcome: .committed,
            additionalInteractionCount: 1
        ) else { return }
        foodWarmPathMeasurement = measurement
        let recorder = telemetryRecorder
        let signal = measurement.technicalSignal
        Task {
            await recorder.record(signal)
        }
    }

    func dismissFoodWarmPathMeasurement() {
        foodWarmPathMeasurement = nil
    }

    var hasFoodHealthWriteCandidates: Bool {
        !foodHealthNutrientKinds.isEmpty
    }

    func requestFoodHealthAuthorization() async {
        let kinds = foodHealthNutrientKinds
        guard !kinds.isEmpty else {
            foodHealthMessage = "Add energy, protein, or caffeine to a preset before enabling Apple Health writes."
            return
        }
        foodHealthMessage = nil
        #if canImport(HealthKit)
        do {
            foodHealthAuthorization = try await foodHealthCoordinator.requestAuthorization(
                for: kinds
            )
            switch foodHealthAuthorization {
            case .authorized:
                await reconcileFoodHealthWrites()
            case .denied:
                foodHealthMessage = "Apple Health did not authorize these nutrient writes. Odyssey logs still work locally."
            case .notDetermined:
                foodHealthMessage = "Apple Health permission was not completed. Odyssey logs still work locally."
            case .unavailable:
                foodHealthMessage = "Apple Health is unavailable on this device. Odyssey logs still work locally."
            }
        } catch {
            foodHealthMessage = "Apple Health permission could not be completed. Odyssey logs still work locally."
        }
        #else
        foodHealthAuthorization = .unavailable
        foodHealthMessage = "Apple Health is unavailable on this platform."
        #endif
    }

    func dismissFoodHealthMessage() {
        foodHealthMessage = nil
    }

    func refreshHealthContextStatus() async {
        guard let coordinator = localServices?.healthImportCoordinator else {
            healthContextState = HealthContextIntegrationState()
            return
        }
        guard !healthContextState.activity.isBusy else { return }
        healthContextState.activity = .refreshing
        do {
            healthContextState.overview = try await coordinator.overview()
            healthContextState.activity = .idle
        } catch {
            healthContextState.activity = .failed(
                "The local Apple Health mirror could not be inspected safely."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func requestHealthContextAuthorization() async {
        guard let coordinator = localServices?.healthImportCoordinator else { return }
        if healthContextState.overview == nil {
            await refreshHealthContextStatus()
        }
        guard let overview = healthContextState.overview,
              overview.capability.availability == .available,
              !overview.capability.supportedKinds.isEmpty
        else {
            healthContextState.message =
                "Apple Health context is unavailable on this device. Other Odyssey features still work."
            return
        }
        guard !healthContextState.activity.isBusy else { return }
        healthContextState.message = nil
        healthContextState.activity = .authorizing
        do {
            let permission = try await coordinator.requestAuthorization(
                for: overview.capability.supportedKinds
            )
            healthContextState.overview = try await coordinator.overview()
            healthContextState.activity = .idle
            switch permission {
            case .authorized, .partial:
                await importHealthContext(showCompletionMessage: true)
            case .denied:
                healthContextState.message =
                    "Apple Health access was denied. Existing local context remains available until you remove it."
            case .restricted:
                healthContextState.message =
                    "Apple Health access is restricted on this device. Odyssey continues without it."
            case .notDetermined:
                healthContextState.message =
                    "Apple Health access was not completed. No context was imported."
            case .unavailable:
                healthContextState.message =
                    "Apple Health is unavailable on this device. Odyssey continues without it."
            case .notRequired:
                healthContextState.message =
                    "No Apple Health data types are currently requested."
            }
        } catch {
            healthContextState.activity = .failed(
                "Apple Health access could not be completed. No permission was assumed."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func importHealthContext() async {
        await importHealthContext(showCompletionMessage: true)
    }

    func removeLocalHealthContext() async {
        guard let coordinator = localServices?.healthImportCoordinator,
              !healthContextState.activity.isBusy
        else {
            return
        }
        healthContextState.activity = .revoking
        do {
            let removedCount = try await coordinator.revokeLocalHealthData()
            healthContextState.overview = try await coordinator.overview()
            healthContextState.lastSuccessfulImportAt = nil
            healthContextState.rejectedRecordCount = 0
            healthContextState.localMirrorRevoked = true
            healthContextState.activity = .idle
            healthContextState.message =
                "Removed \(removedCount) local Apple Health context record"
                + "\(removedCount == 1 ? "" : "s"). HealthKit permissions and Apple Health data were not changed."
        } catch {
            healthContextState.activity = .failed(
                "The local Apple Health mirror could not be removed safely."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func dismissHealthContextMessage() {
        healthContextState.message = nil
    }

    func refreshCalendarContextStatus() async {
        guard let coordinator = localServices?.calendarMirrorCoordinator else {
            calendarContextState = CalendarContextIntegrationState()
            return
        }
        guard !calendarContextState.activity.isBusy else { return }
        calendarContextState.activity = .refreshing
        do {
            calendarContextState.overview = try await coordinator.overview()
            calendarContextState.activity = .idle
        } catch {
            calendarContextState.activity = .failed(
                "The local calendar mirror could not be inspected safely."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func requestCalendarContextAuthorization() async {
        guard let coordinator = localServices?.calendarMirrorCoordinator else { return }
        if calendarContextState.overview == nil {
            await refreshCalendarContextStatus()
        }
        guard let overview = calendarContextState.overview,
              overview.capability.availability == .available,
              overview.capability.supportsFullAccessRead
        else {
            calendarContextState.message =
                "Calendar context is unavailable on this device. Other Odyssey features still work."
            return
        }
        guard !calendarContextState.activity.isBusy else { return }
        calendarContextState.message = nil
        calendarContextState.activity = .authorizing
        do {
            let permission = try await coordinator.requestReadAuthorization()
            calendarContextState.overview = try await coordinator.overview()
            calendarContextState.activity = .idle
            switch permission {
            case .authorized:
                await refreshCalendarContext(showCompletionMessage: true)
            case .partial:
                calendarContextState.message =
                    "Calendar write-only access does not permit reading context. Full access remains optional."
            case .denied:
                calendarContextState.message =
                    "Calendar read access was denied. Existing local context remains until you remove it."
            case .restricted:
                calendarContextState.message =
                    "Calendar access is restricted on this device. Odyssey continues without it."
            case .notDetermined:
                calendarContextState.message =
                    "Calendar access was not completed. No events were mirrored."
            case .unavailable:
                calendarContextState.message =
                    "Calendar access is unavailable on this device. Odyssey continues without it."
            case .notRequired:
                calendarContextState.message =
                    "No calendar read capability is currently requested."
            }
        } catch {
            calendarContextState.activity = .failed(
                "Calendar access could not be completed. No permission was assumed."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func refreshCalendarContext() async {
        await refreshCalendarContext(showCompletionMessage: true)
    }

    func removeLocalCalendarContext() async {
        guard let coordinator = localServices?.calendarMirrorCoordinator,
              !calendarContextState.activity.isBusy
        else {
            return
        }
        calendarContextState.activity = .revoking
        do {
            let removedCount = try await coordinator.revokeLocalCalendarData()
            calendarContextState.overview = try await coordinator.overview()
            calendarContextState.rejectedRecordCount = 0
            calendarContextState.localMirrorRevoked = true
            calendarContextState.activity = .idle
            calendarContextState.message =
                "Removed \(removedCount) local calendar context event"
                + "\(removedCount == 1 ? "" : "s"). Source calendars and system permission were not changed."
        } catch {
            calendarContextState.activity = .failed(
                "The local calendar mirror could not be removed safely."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func dismissCalendarContextMessage() {
        calendarContextState.message = nil
    }

    func refreshLocationContextStatus() async {
        guard let coordinator = localServices?.locationContextCoordinator else {
            locationContextState = LocationContextIntegrationState()
            return
        }
        guard !locationContextState.activity.isBusy else { return }
        locationContextState.activity = .refreshing
        do {
            locationContextState.overview = try await coordinator.overview()
            locationContextState.activity = .idle
        } catch {
            locationContextState.activity = .failed(
                "The local broad-place context could not be inspected safely."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func requestLocationContextAuthorization() async {
        guard let coordinator = localServices?.locationContextCoordinator else { return }
        if locationContextState.overview == nil {
            await refreshLocationContextStatus()
        }
        guard let overview = locationContextState.overview,
              overview.capability.availability == .available,
              overview.capability.supportsForegroundBroadPlace
        else {
            locationContextState.message =
                "Broad foreground location is unavailable on this device. Odyssey continues without it."
            return
        }
        guard !locationContextState.activity.isBusy else { return }
        locationContextState.message = nil
        locationContextState.activity = .authorizing
        let permission = await coordinator.requestWhenInUseAuthorization()
        do {
            locationContextState.overview = try await coordinator.overview()
            locationContextState.activity = .idle
            switch permission {
            case .authorized:
                locationContextState.message =
                    "When-in-use access is available. Refresh only when you want current broad-place context."
            case .denied:
                locationContextState.message =
                    "When-in-use access was denied. Existing local broad-place context remains until you remove it."
            case .restricted:
                locationContextState.message =
                    "Location access is restricted on this device. Odyssey continues without it."
            case .notDetermined:
                locationContextState.message =
                    "Location access was not completed. No broad place was acquired."
            case .unavailable:
                locationContextState.message =
                    "Broad foreground location is unavailable on this device. Odyssey continues without it."
            case .partial:
                locationContextState.message =
                    "Location access is incomplete. No broad place was acquired."
            case .notRequired:
                locationContextState.message =
                    "No location capability is currently requested."
            }
        } catch {
            locationContextState.activity = .failed(
                "Location access changed, but its local status could not be inspected safely."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func refreshLocationContext() async {
        guard let localServices else { return }
        if locationContextState.overview == nil {
            await refreshLocationContextStatus()
        }
        guard locationContextState.canRefresh else { return }
        locationContextState.message = nil
        locationContextState.activity = .acquiring
        do {
            let result = try await localServices.foregroundContextRefreshCoordinator.refresh()
            locationContextState.overview = try await localServices.locationContextCoordinator
                .overview()
            locationContextState.activity = .idle
            switch result.locationOutcome {
            case .acquired:
                locationContextState.localMirrorRevoked = false
                locationContextState.message =
                    "Current broad-place context refreshed locally. Coordinates were discarded after the immediate weather handoff."
            case .permissionDenied:
                locationContextState.message =
                    "When-in-use access is not granted. Prior local broad-place context was preserved."
            case .restricted:
                locationContextState.message =
                    "Location access is restricted. Prior local broad-place context was preserved."
            case .unavailable:
                locationContextState.message =
                    "Broad foreground location is unavailable. Prior local context was preserved."
            case .insufficientAccuracy:
                locationContextState.message =
                    "The current fix was too imprecise even for broad context. Prior local context was preserved."
            case .noFix:
                locationContextState.message =
                    "No current location fix was available. Prior local broad-place context was preserved."
            }
            await applyForegroundWeatherRefresh(
                result.weatherRefresh,
                coordinator: localServices.weatherMirrorCoordinator
            )
        } catch {
            locationContextState.activity = .failed(
                "Broad-place context could not be refreshed. Prior local context remains intact."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func removeLocalLocationContext() async {
        guard let coordinator = localServices?.locationContextCoordinator,
              !locationContextState.activity.isBusy
        else {
            return
        }
        locationContextState.activity = .revoking
        do {
            let removedCount = try await coordinator.revokeLocalLocationData()
            locationContextState.overview = try await coordinator.overview()
            locationContextState.localMirrorRevoked = true
            locationContextState.activity = .idle
            locationContextState.message =
                "Removed \(removedCount) local broad-place context record"
                + "\(removedCount == 1 ? "" : "s"). System location permission was not changed."
        } catch {
            locationContextState.activity = .failed(
                "The local broad-place context could not be removed safely."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func dismissLocationContextMessage() {
        locationContextState.message = nil
    }

    func refreshWeatherContextStatus() async {
        guard let coordinator = localServices?.weatherMirrorCoordinator else {
            weatherContextState = WeatherContextIntegrationState()
            return
        }
        guard !weatherContextState.activity.isBusy else { return }
        weatherContextState.activity = .refreshing
        do {
            weatherContextState.overview = try await coordinator.overview()
            weatherContextState.activity = .idle
        } catch {
            weatherContextState.activity = .failed(
                "The local weather mirror could not be inspected safely."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func removeLocalWeatherContext() async {
        guard let coordinator = localServices?.weatherMirrorCoordinator,
              !weatherContextState.activity.isBusy
        else {
            return
        }
        weatherContextState.activity = .revoking
        do {
            let removedCount = try await coordinator.revokeLocalWeatherData()
            weatherContextState.overview = try await coordinator.overview()
            weatherContextState.localMirrorRevoked = true
            weatherContextState.activity = .idle
            weatherContextState.message =
                "Removed \(removedCount) local weather context snapshot"
                + "\(removedCount == 1 ? "" : "s"). WeatherKit service access and provider data were not changed."
        } catch {
            weatherContextState.activity = .failed(
                "The local weather mirror could not be removed safely."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    func dismissWeatherContextMessage() {
        weatherContextState.message = nil
    }

    func dismissExtensionCommandMessage() {
        extensionCommandMessage = nil
    }

    func consumeExtensionPresentationRequest() {
        extensionPresentationRequest = nil
    }

    func resumeForegroundExperience() async {
        await processPendingExtensionCommands()
        await refreshNowExperience(markSeen: true)
    }

    func refreshNowExperience() async {
        await refreshNowExperience(markSeen: true)
    }

    func beginTomorrowMapTelemetrySession(
        for projection: TomorrowMapProjection,
        entryPoint: TomorrowMapProductTelemetryEntryPoint = .automaticNow
    ) async {
        guard let recorder = localServices?.productTelemetryRecorder,
              tomorrowMapTelemetrySession == nil,
              !isStartingTomorrowMapTelemetrySession
        else {
            return
        }
        isStartingTomorrowMapTelemetrySession = true
        defer { isStartingTomorrowMapTelemetrySession = false }
        tomorrowMapTelemetryGeneration &+= 1
        let generation = tomorrowMapTelemetryGeneration
        let session = await recorder.beginTomorrowMapSession(
            calendarState: projection.calendarState,
            entryPoint: entryPoint
        )
        guard generation == tomorrowMapTelemetryGeneration else {
            if let session {
                _ = await recorder.finishTomorrowMapSession(session, outcome: .dismissed)
            }
            return
        }
        tomorrowMapTelemetrySession = session
    }

    func finishTomorrowMapTelemetrySession(
        outcome: TomorrowMapProductTelemetrySessionOutcome
    ) async {
        tomorrowMapTelemetryGeneration &+= 1
        guard let recorder = localServices?.productTelemetryRecorder,
              let session = tomorrowMapTelemetrySession
        else {
            return
        }
        tomorrowMapTelemetrySession = nil
        _ = await recorder.finishTomorrowMapSession(session, outcome: outcome)
    }

    func recordTomorrowMapFeedback(
        rating: TomorrowMapProductTelemetryFeedbackRating,
        reason: TomorrowMapProductTelemetryFeedbackReason? = nil
    ) async {
        guard let recorder = localServices?.productTelemetryRecorder else { return }
        tomorrowMapTelemetryGeneration &+= 1
        let session = tomorrowMapTelemetrySession
        tomorrowMapTelemetrySession = nil
        let disposition = await recorder.recordTomorrowMapFeedback(
            rating: rating,
            reason: reason,
            session: session
        )
        if let session {
            _ = await recorder.finishTomorrowMapSession(session, outcome: .feedback)
        }
        productTelemetryMessage = telemetryFeedbackMessage(for: disposition)
    }

    func recordCaptureFeedback(
        rating: CaptureProductTelemetryFeedbackRating,
        reason: CaptureProductTelemetryFeedbackReason? = nil
    ) async {
        guard let recorder = localServices?.productTelemetryRecorder else { return }
        let disposition = await recorder.recordCaptureFeedback(
            rating: rating,
            reason: reason
        )
        productTelemetryMessage = telemetryFeedbackMessage(for: disposition)
    }

    func recordCaptureAbandonment(
        kind: CapturePayloadKind,
        exitStage: CaptureProductTelemetryExitStage,
        startedAt: Date
    ) async {
        guard let recorder = localServices?.productTelemetryRecorder else { return }
        await recorder.recordCaptureAbandonment(
            kind: kind,
            invokingSurface: .iPhoneGlobalCapture,
            exitStage: exitStage,
            startedAt: startedAt
        )
    }

    func recordTomorrowMapPlanDeviation(
        deviation: TomorrowMapProductTelemetryPlanDeviation,
        influence: TomorrowMapProductTelemetryInfluence
    ) async {
        guard let recorder = localServices?.productTelemetryRecorder else { return }
        let disposition = await recorder.recordTomorrowMapPlanDeviation(
            deviation: deviation,
            influence: influence
        )
        productTelemetryMessage = telemetryFeedbackMessage(for: disposition)
    }

    func dismissProductTelemetryMessage() {
        productTelemetryMessage = nil
    }

    func refreshProductTelemetryPrivacy() async {
        guard let service = localServices?.productTelemetryPrivacyService,
              !isLoadingProductTelemetryPrivacy
        else {
            return
        }
        isLoadingProductTelemetryPrivacy = true
        defer { isLoadingProductTelemetryPrivacy = false }
        do {
            productTelemetryPrivacySnapshot = try await service.snapshot()
            productTelemetryPrivacyMessage = nil
        } catch {
            productTelemetryPrivacyMessage =
                "Local product telemetry controls could not be read safely."
        }
    }

    func updateProductTelemetryPreferences(
        collectionMode: ProductTelemetryCollectionMode,
        enabledQuestions: [ProductTelemetryQuestionID],
        retentionDays: Int
    ) async {
        guard let service = localServices?.productTelemetryPrivacyService,
              !isLoadingProductTelemetryPrivacy
        else {
            return
        }
        isLoadingProductTelemetryPrivacy = true
        defer { isLoadingProductTelemetryPrivacy = false }
        do {
            let preferences = try ProductTelemetryPreferences(
                collectionMode: collectionMode,
                enabledQuestions: enabledQuestions,
                retentionDays: retentionDays
            )
            try await service.updatePreferences(preferences)
            productTelemetryPrivacySnapshot = try await service.snapshot()
            productTelemetryPrivacyMessage =
                "Local product telemetry preferences were saved and retention was applied."
            await refreshWeeklyProductReview()
        } catch {
            productTelemetryPrivacyMessage =
                "Local product telemetry preferences could not be saved."
        }
    }

    func deleteAllProductTelemetry() async {
        guard let service = localServices?.productTelemetryPrivacyService,
              !isLoadingProductTelemetryPrivacy
        else {
            return
        }
        isLoadingProductTelemetryPrivacy = true
        defer { isLoadingProductTelemetryPrivacy = false }
        do {
            let deletedCount = try await service.deleteAllEvents()
            productTelemetryPrivacySnapshot = try await service.snapshot()
            productTelemetryPrivacyMessage =
                "Deleted \(deletedCount) local product telemetry event"
                + "\(deletedCount == 1 ? "" : "s"). Captures and personal history were unchanged."
            await refreshWeeklyProductReview()
        } catch {
            productTelemetryPrivacyMessage =
                "Local product telemetry could not be deleted safely."
        }
    }

    func dismissProductTelemetryPrivacyMessage() {
        productTelemetryPrivacyMessage = nil
    }

    func setNowStateCorrection(
        state: NowState,
        reason: NowStateCorrectionReason
    ) async {
        guard let service = localServices?.nowExperienceService else { return }
        nowRefreshGeneration &+= 1
        let createdAt = Date()
        do {
            let correction = try NowStateCorrection(
                state: state,
                reason: reason,
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(24 * 60 * 60)
            )
            _ = try await service.setCorrection(correction)
            await refreshNowExperience(markSeen: false)
        } catch {
            nowExperienceMessage =
                "The manual state correction could not be saved to local state."
        }
    }

    func clearNowStateCorrection() async {
        guard let service = localServices?.nowExperienceService else { return }
        nowRefreshGeneration &+= 1
        do {
            _ = try await service.clearCorrection()
            await refreshNowExperience(markSeen: false)
        } catch {
            nowExperienceMessage =
                "The manual state correction could not be cleared safely."
        }
    }

    @discardableResult
    func respondToReentry(_ option: ReentryOption) async -> Bool {
        guard reentrySurface?.options.contains(option) == true,
              let service = localServices?.nowExperienceService
        else {
            return false
        }
        nowRefreshGeneration &+= 1
        let respondedAt = Date()
        do {
            if option == .stayQuiet {
                _ = try await service.setCorrection(NowStateCorrection(
                    state: .clear,
                    reason: .ownerRequestedQuiet,
                    createdAt: respondedAt,
                    expiresAt: respondedAt.addingTimeInterval(24 * 60 * 60)
                ))
            }
            _ = try await service.recordVisit(at: respondedAt)
            reentrySurface = nil
            await refreshNowExperience(markSeen: false)
            return true
        } catch {
            nowExperienceMessage =
                "The re-entry choice could not be saved to local state."
            return false
        }
    }

    func refreshCaptureArchive() async {
        refreshRecentCaptures()
        await refreshWeeklyProductReview()
        await refreshDiagnostics()
        await refreshNowExperience(markSeen: true)
    }

    func refreshWeeklyProductReview() async {
        guard let service = localServices?.weeklyProductReviewService,
              !isLoadingWeeklyProductReview
        else {
            return
        }
        isLoadingWeeklyProductReview = true
        defer { isLoadingWeeklyProductReview = false }
        do {
            let availability = try await Task.detached(priority: .utility) {
                try service.generate()
            }.value
            switch availability {
            case let .available(artifact):
                weeklyProductReview = artifact
                weeklyProductReviewMessage = nil
            case .disabledByFeatureFlag:
                weeklyProductReview = nil
                weeklyProductReviewMessage =
                    "Weekly product review is disabled by its reversible feature flag."
            }
        } catch {
            weeklyProductReviewMessage =
                "The weekly product review could not be derived from local telemetry."
        }
    }

    func reviewCapture(
        captureID: UUIDv7,
        draft: CaptureInterpretationReviewDraft
    ) async throws {
        guard let localServices else {
            throw CaptureReviewApplicationError.localDataUnavailable
        }
        let result = try await localServices.captureInterpretationService.review(
            captureID: captureID,
            draft: draft
        )
        if case let .deferred(reason) = result {
            throw CaptureReviewApplicationError.unexpectedDeferral(reason)
        }
        await refreshAfterCaptureMutation()
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
            await deliverLifeModelAcceptances()
            await refreshNowExperience(markSeen: false)
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
        await processPendingExtensionCommands()
        await resumePendingCaptureInterpretations()
        await importHealthContext(
            showCompletionMessage: false,
            requiresExistingActivation: true
        )
        await refreshCalendarContext(
            showCompletionMessage: false,
            requiresExistingMirror: true
        )
        await refreshNowExperience(markSeen: false)
        guard let remoteServices, state.canSynchronize else { return }
        await withTaskCancellationHandler {
            await synchronize()
        } onCancel: {
            Task {
                await remoteServices.syncCoordinator.cancelSynchronization()
                await remoteServices.lifeModelAcceptanceCoordinator.cancelSynchronization()
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

    func processPendingExtensionCommands() async {
        await drainExtensionCommands()
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
            await refreshWorkshop()
        } catch {
            apply(.maintenanceFailed(
                "Projection rebuild failed. The immutable ledger was not changed."
            ))
        }
    }

    func dismissMaintenanceStatus() {
        apply(.maintenanceDismissed)
    }

    func refreshWorkshop() async {
        guard let localServices else { return }
        apply(.workshopLoadStarted)
        guard state.workshopPhase == .loading else { return }
        do {
            let snapshot = try await localServices.lifeModelWorkshopService.snapshot()
            apply(.workshopLoaded(snapshot))
            await refreshNowExperience(markSeen: false)
        } catch {
            apply(.workshopFailed(
                "The local Workshop history could not be loaded safely."
            ))
        }
    }

    func createInitialWorkshopDraft(_ kind: LifeModelKind) async {
        guard let localServices, let workshopDraftFactory else { return }
        apply(.workshopSaveStarted)
        guard state.workshopPhase == .saving else { return }
        do {
            let proposal: LifeModelDraftProposal
            switch kind {
            case .charter:
                proposal = try workshopDraftFactory.initialCharter()
            case .lifeStage:
                proposal = try workshopDraftFactory.initialLifeStage()
            case .season:
                guard let charterVersionID = workshopCharterVersionID else {
                    throw WorkshopApplicationError.charterRequired
                }
                proposal = try workshopDraftFactory.initialSeason(
                    charterVersionID: charterVersionID
                )
            }
            _ = try await localServices.lifeModelWorkshopService.createDraft(proposal)
            let snapshot = try await localServices.lifeModelWorkshopService.snapshot()
            apply(.workshopSaved(snapshot))
        } catch {
            apply(.workshopFailed(workshopMessage(
                for: error,
                fallback: "The initial life-model draft could not be created."
            )))
        }
    }

    func createWorkshopRevision(
        of version: CachedLifeModelVersion
    ) async {
        guard let localServices, let workshopDraftFactory else { return }
        apply(.workshopSaveStarted)
        guard state.workshopPhase == .saving else { return }
        do {
            let proposal = try workshopDraftFactory.revision(of: version)
            _ = try await localServices.lifeModelWorkshopService.createDraft(proposal)
            let snapshot = try await localServices.lifeModelWorkshopService.snapshot()
            apply(.workshopSaved(snapshot))
        } catch {
            apply(.workshopFailed(workshopMessage(
                for: error,
                fallback: "A reviewed revision could not be started."
            )))
        }
    }

    func createSuccessorSeason(
        after version: CachedLifeModelVersion
    ) async {
        guard let localServices, let workshopDraftFactory else { return }
        apply(.workshopSaveStarted)
        guard state.workshopPhase == .saving else { return }
        do {
            let proposal = try workshopDraftFactory.successorSeason(after: version)
            _ = try await localServices.lifeModelWorkshopService.createDraft(proposal)
            let snapshot = try await localServices.lifeModelWorkshopService.snapshot()
            apply(.workshopSaved(snapshot))
        } catch {
            apply(.workshopFailed(workshopMessage(
                for: error,
                fallback: "The successor season could not be started."
            )))
        }
    }

    func saveWorkshopDraft(
        draftID: UUIDv7,
        expectedStateRevision: Int,
        document: [String: JSONValue]
    ) async -> Bool {
        guard let localServices else { return false }
        apply(.workshopSaveStarted)
        guard state.workshopPhase == .saving else { return false }
        do {
            _ = try await localServices.lifeModelWorkshopService.saveDraft(
                draftID: draftID,
                expectedStateRevision: expectedStateRevision,
                document: document
            )
            let snapshot = try await localServices.lifeModelWorkshopService.snapshot()
            apply(.workshopSaved(snapshot))
            return true
        } catch {
            apply(.workshopFailed(workshopMessage(
                for: error,
                fallback: "The Workshop draft could not be saved."
            )))
            return false
        }
    }

    func prepareWorkshopReview(for draft: LifeModelDraftRecord) async {
        guard let localServices else { return }
        apply(.workshopReviewStarted)
        guard state.workshopPhase == .reviewing else { return }
        do {
            let review = try await localServices.lifeModelWorkshopService.prepareReview(
                draftID: draft.draftID,
                expectedStateRevision: draft.stateRevision
            )
            let snapshot = try await localServices.lifeModelWorkshopService.snapshot()
            apply(.workshopReviewPrepared(review: review, snapshot: snapshot))
        } catch {
            apply(.workshopFailed(workshopMessage(
                for: error,
                fallback: "The complete semantic review could not be prepared."
            )))
        }
    }

    func queueWorkshopAcceptance(_ review: LifeModelDraftReview) async {
        guard let localServices,
              state.workshopReview?.reviewDigest == review.reviewDigest
        else { return }
        apply(.workshopQueueStarted)
        guard state.workshopPhase == .queueing else { return }
        do {
            _ = try await localServices.lifeModelWorkshopService.queueReviewedDraft(
                draftID: review.draft.draftID,
                reviewDigest: review.reviewDigest
            )
            let snapshot = try await localServices.lifeModelWorkshopService.snapshot()
            apply(.workshopQueued(snapshot))
            scheduleBackgroundRefresh()
            if remoteServices != nil, state.enrollmentPhase == .credentialStored {
                await deliverLifeModelAcceptances()
            }
        } catch {
            apply(.workshopFailed(workshopMessage(
                for: error,
                fallback: "The reviewed acceptance command could not be queued."
            )))
        }
    }

    func abandonWorkshopDraft(_ draft: LifeModelDraftRecord) async {
        guard let localServices else { return }
        apply(.workshopSaveStarted)
        guard state.workshopPhase == .saving else { return }
        do {
            _ = try await localServices.lifeModelWorkshopService.abandonDraft(
                draftID: draft.draftID,
                expectedStateRevision: draft.stateRevision
            )
            let snapshot = try await localServices.lifeModelWorkshopService.snapshot()
            apply(.workshopSaved(snapshot))
        } catch {
            apply(.workshopFailed(workshopMessage(
                for: error,
                fallback: "The Workshop draft could not be abandoned."
            )))
        }
    }

    func dismissWorkshopReview() {
        apply(.workshopReviewDismissed)
    }

    private func refreshNowExperience(markSeen: Bool) async {
        guard let localServices else { return }
        nowRefreshGeneration &+= 1
        let generation = nowRefreshGeneration
        let generatedAt = Date()
        do {
            var record = try await localServices.nowExperienceService.record()
            if let correction = record.correction,
               !correction.isActive(at: generatedAt)
            {
                record = try await localServices.nowExperienceService.clearCorrection()
            }
            let calendarSnapshot = try await localServices.calendarMirrorCoordinator
                .localSnapshot()
            let acceptedSeasons = acceptedSeasonVersions
            let recentCaptures = state.recentCaptures
            let projection = try NativeNowContextProjector().project(
                NativeNowContextInput(
                    generatedAt: generatedAt,
                    deviceTimeZoneID: TimeZone.current.identifier,
                    calendarSnapshot: calendarSnapshot,
                    calendarOverview: calendarContextState.overview,
                    healthOverview: healthContextState.overview,
                    healthLastSuccessfulImportAt: healthContextState.lastSuccessfulImportAt,
                    weatherOverview: weatherContextState.overview,
                    locationOverview: locationContextState.overview,
                    season: currentAcceptedSeason,
                    correction: record.correction
                )
            )
            let reentry = try NativeReentryProjector().project(
                NativeReentryInput(
                    lastSeenAt: record.lastSeenAt,
                    generatedAt: generatedAt,
                    deviceTimeZoneID: TimeZone.current.identifier,
                    acceptedSeasonVersions: acceptedSeasons,
                    recentCaptures: recentCaptures,
                    calendarSnapshot: calendarSnapshot,
                    locationOverview: locationContextState.overview
                )
            )
            if markSeen, reentry == nil {
                _ = try await localServices.nowExperienceService.recordVisit(
                    at: generatedAt
                )
            }
            guard generation == nowRefreshGeneration else { return }
            nowContextProjection = projection
            reentrySurface = reentry
            publishNowWidgetSnapshot(projection)
            let productTelemetryRecorder = localServices.productTelemetryRecorder
            Task {
                _ = await productTelemetryRecorder.recordTomorrowMapAvailability(
                    projection.tomorrow
                )
            }
        } catch {
            guard generation == nowRefreshGeneration else { return }
            nowExperienceMessage = nowContextProjection == nil
                ? "Current context could not be built from the local cache."
                : "Current context could not be refreshed; the last local result remains visible."
        }
    }

    private func publishNowWidgetSnapshot(
        _ projection: NativeNowContextProjection
    ) {
        guard let nowWidgetSnapshotStore else {
            nowExperienceMessage =
                "Current context is available, but the widget cache needs a configured App Group."
            return
        }
        do {
            let maximumExpiration = projection.now.generatedAt.addingTimeInterval(
                6 * 60 * 60
            )
            let expiresAt = projection.now.nextTransition.map {
                min(maximumExpiration, $0.startsAt)
            } ?? maximumExpiration
            let snapshot = try NowWidgetSnapshot(
                generatedAt: projection.now.generatedAt,
                expiresAt: expiresAt,
                timeZoneID: projection.now.timeZoneID,
                state: projection.now.state,
                summary: projection.now.summary,
                tomorrowSummary: projection.tomorrow.shape,
                nextTransitionAt: projection.now.nextTransition?.startsAt,
                privacySensitive: true
            )
            try nowWidgetSnapshotStore.write(snapshot)
            WidgetCenter.shared.reloadTimelines(
                ofKind: NowWidgetSnapshotStore.widgetKind
            )
            nowExperienceMessage = nil
        } catch {
            nowExperienceMessage =
                "Current context is available, but its private widget cache could not be updated."
        }
    }

    private var acceptedSeasonVersions: [CachedLifeModelVersion] {
        state.workshopSnapshot?.acceptedVersions
            .filter { $0.kind == .season }
            .sorted {
                if $0.acceptanceSequence != $1.acceptanceSequence {
                    return $0.acceptanceSequence > $1.acceptanceSequence
                }
                return $0.versionID.description < $1.versionID.description
            } ?? []
    }

    private var currentAcceptedSeason: Season? {
        guard let version = acceptedSeasonVersions.first else { return nil }
        return try? SyncJSONCoding.makeDecoder().decode(
            Season.self,
            from: version.document
        )
    }

    private func refreshDiagnostics() async {
        guard let localServices else { return }
        do {
            apply(.diagnosticsUpdated(try await localServices.localDiagnostics()))
        } catch {
            return
        }
    }

    private func importHealthContext(
        for requestedKinds: Set<HealthSampleKind>? = nil,
        showCompletionMessage: Bool,
        requiresExistingActivation: Bool = false,
        maintainObservation: Bool = true
    ) async {
        guard let coordinator = localServices?.healthImportCoordinator else { return }
        if healthContextState.overview == nil {
            await refreshHealthContextStatus()
        }
        guard let overview = healthContextState.overview,
              overview.capability.availability == .available,
              overview.permission == .authorized || overview.permission == .partial,
              !healthContextState.activity.isBusy
        else {
            if showCompletionMessage,
               healthContextState.overview?.permission == .notDetermined
            {
                healthContextState.message =
                    "Request Apple Health access before importing local context."
            }
            return
        }
        guard !requiresExistingActivation
            || NativeIntegrationActivationPolicy.shouldResumeHealthImport(overview)
        else {
            return
        }
        let importKinds = requestedKinds.map {
            $0.intersection(overview.capability.supportedKinds)
        } ?? overview.capability.supportedKinds
        guard !importKinds.isEmpty else { return }
        if showCompletionMessage {
            healthContextState.message = nil
        }
        healthContextState.activity = .importing
        var insertedCount = 0
        var deletedCount = 0
        var duplicateCount = 0
        var rejectedCount = 0
        var degradedKindCount = 0
        var failedKindCount = 0
        var latestSuccessfulImport: Date?
        for kind in importKinds.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            do {
                let receipt = try await coordinator.importChanges(for: kind)
                rejectedCount += receipt.rejectedCount
                switch receipt.outcome {
                case .imported, .noChanges:
                    insertedCount += receipt.insertedCount
                    deletedCount += receipt.deletedCount
                    duplicateCount += receipt.duplicateCount
                    if latestSuccessfulImport.map({ receipt.queriedAt > $0 }) ?? true {
                        latestSuccessfulImport = receipt.queriedAt
                    }
                case .permissionDenied, .restricted, .unavailable:
                    degradedKindCount += 1
                }
            } catch {
                failedKindCount += 1
            }
        }
        if let latestSuccessfulImport {
            if healthContextState.lastSuccessfulImportAt.map({
                latestSuccessfulImport > $0
            }) ?? true {
                healthContextState.lastSuccessfulImportAt = latestSuccessfulImport
            }
            healthContextState.localMirrorRevoked = false
        }
        healthContextState.rejectedRecordCount = min(
            1_000_000,
            healthContextState.rejectedRecordCount + rejectedCount
        )
        do {
            healthContextState.overview = try await coordinator.overview()
        } catch {
            failedKindCount += 1
        }
        if failedKindCount > 0 {
            healthContextState.activity = .failed(
                "Some Apple Health types could not be refreshed. Successful type imports remain committed locally."
            )
        } else {
            healthContextState.activity = .idle
        }
        if latestSuccessfulImport != nil, maintainObservation {
            await startHealthChangeObservationIfNeeded()
        }
        await refreshNowExperience(markSeen: false)
        guard showCompletionMessage else { return }
        if failedKindCount > 0 {
            healthContextState.message =
                "Apple Health refresh was partial. Try again after reviewing integration status."
        } else if degradedKindCount > 0 {
            healthContextState.message =
                "Apple Health refreshed the permitted types; \(degradedKindCount) type"
                + "\(degradedKindCount == 1 ? " was" : "s were") unavailable or denied."
        } else {
            healthContextState.message =
                "Apple Health context refreshed locally: \(insertedCount) added, "
                + "\(deletedCount) removed, and \(duplicateCount) already known."
        }
    }

    private func startHealthChangeObservationIfNeeded() async {
        guard let coordinator = localServices?.healthImportCoordinator,
              let overview = healthContextState.overview,
              overview.capability.availability == .available,
              overview.permission == .authorized || overview.permission == .partial,
              overview.changeObservationState != .active
        else {
            return
        }
        do {
            _ = try await coordinator.startChangeObservation(
                for: overview.capability.supportedKinds
            ) { [weak self] kind in
                await self?.importObservedHealthChange(kind)
            }
            healthContextState.overview = try await coordinator.overview()
        } catch {
            healthContextState.overview = try? await coordinator.overview()
            healthContextState.message =
                "Apple Health background observation could not be registered. Owner-requested and app-refresh imports still work."
        }
    }

    private func importObservedHealthChange(_ kind: HealthSampleKind) async {
        await importHealthContext(
            for: [kind],
            showCompletionMessage: false,
            requiresExistingActivation: true,
            maintainObservation: false
        )
    }

    private func refreshCalendarContext(
        showCompletionMessage: Bool,
        requiresExistingMirror: Bool = false
    ) async {
        guard let coordinator = localServices?.calendarMirrorCoordinator else { return }
        if calendarContextState.overview == nil {
            await refreshCalendarContextStatus()
        }
        guard !requiresExistingMirror
            || NativeIntegrationActivationPolicy.shouldResumeCalendarMirror(
                calendarContextState.overview
            )
        else {
            return
        }
        guard calendarContextState.overview?.capability.availability == .available,
              calendarContextState.overview?.permission == .authorized,
              !calendarContextState.activity.isBusy
        else {
            if showCompletionMessage,
               calendarContextState.overview?.permission == .notDetermined
                    || calendarContextState.overview?.permission == .partial
            {
                calendarContextState.message =
                    "Grant optional full calendar access before refreshing local constraints."
            }
            return
        }
        if showCompletionMessage {
            calendarContextState.message = nil
        }
        calendarContextState.activity = .importing
        do {
            let result = try await coordinator.refresh(
                window: try calendarContextWindow()
            )
            calendarContextState.rejectedRecordCount = min(
                1_000_000,
                calendarContextState.rejectedRecordCount + result.rejectedCount
            )
            calendarContextState.overview = try await coordinator.overview()
            calendarContextState.activity = .idle
            switch result.outcome {
            case .imported:
                calendarContextState.localMirrorRevoked = false
                if showCompletionMessage {
                    calendarContextState.message =
                        "Calendar context refreshed locally: \(result.insertedCount) added, "
                        + "\(result.updatedCount) updated, \(result.deletedCount) removed, "
                        + "and \(result.duplicateCount) unchanged."
                }
            case .permissionDenied:
                if showCompletionMessage {
                    calendarContextState.message =
                        "Calendar full access is not granted. Existing local context was preserved."
                }
            case .restricted:
                if showCompletionMessage {
                    calendarContextState.message =
                        "Calendar access is restricted. Existing local context was preserved."
                }
            case .unavailable:
                if showCompletionMessage {
                    calendarContextState.message =
                        "Calendar context is unavailable. Existing local context was preserved."
                }
            }
        } catch {
            calendarContextState.activity = .failed(
                "Calendar context could not be refreshed. Prior local events remain intact."
            )
        }
        await refreshNowExperience(markSeen: false)
    }

    private func applyForegroundWeatherRefresh(
        _ refresh: ForegroundWeatherRefreshState,
        coordinator: WeatherMirrorCoordinator
    ) async {
        switch refresh {
        case .notAttempted:
            return
        case let .completed(result):
            do {
                weatherContextState.overview = try await coordinator.overview()
                weatherContextState.activity = .idle
                switch result.outcome {
                case .fetched:
                    weatherContextState.localMirrorRevoked = false
                    weatherContextState.message =
                        "Weather context refreshed locally: \(result.insertedCount) added, "
                        + "\(result.updatedCount) updated, and \(result.duplicateCount) unchanged."
                case .rateLimited:
                    weatherContextState.message =
                        "The weather provider is rate limited. Prior local context was preserved."
                case .unavailable:
                    weatherContextState.message =
                        "Weather service or entitlement is unavailable. Prior local context was preserved."
                }
            } catch {
                weatherContextState.activity = .failed(
                    "Weather refreshed, but its local status could not be inspected safely."
                )
            }
        case .failed:
            weatherContextState.activity = .failed(
                "Weather context could not be refreshed. Prior local context remains intact."
            )
        }
    }

    private func calendarContextWindow(
        at date: Date = Date()
    ) throws -> CalendarQueryWindow {
        try CalendarQueryWindow(
            startDate: date.addingTimeInterval(-14 * 24 * 60 * 60),
            endDate: date.addingTimeInterval(180 * 24 * 60 * 60),
            timeZoneID: TimeZone.current.identifier
        )
    }

    private func foodQuickLogSnapshot(at date: Date) async throws -> FoodQuickLogSnapshot {
        guard let localServices else {
            throw FoodOccurrenceServiceError.invalidConfiguration(
                "The local food library is unavailable."
            )
        }
        let presets = try await localServices.foodPresetService.activePresets()
        let usages = try await localServices.foodOccurrenceService.rankingUsages()
        let occurrences = try await localServices.foodOccurrenceService.recentOccurrences(
            limit: 20
        )
        return try FoodQuickLogProjector.project(
            presets: presets,
            usages: usages,
            recentOccurrences: occurrences,
            at: date,
            timeZoneID: TimeZone.current.identifier
        )
    }

    private func publishWatchFoodSnapshot(_ snapshot: FoodQuickLogSnapshot) {
        guard let watchCommandReceiver,
              let projected = try? WatchFoodPresetSnapshotProjector.project(snapshot)
        else {
            return
        }
        try? watchCommandReceiver.publish(foodSnapshot: projected)
    }

    private var foodHealthNutrientKinds: Set<FoodHealthNutrientKind> {
        var kinds = Set<FoodHealthNutrientKind>()
        for preset in state.foodSnapshot?.activePresets ?? [] {
            if preset.nutrients?.energyKilocalories != nil {
                kinds.insert(.energyKilocalories)
            }
            if preset.nutrients?.proteinGrams != nil {
                kinds.insert(.proteinGrams)
            }
            if preset.nutrients?.caffeineMilligrams != nil {
                kinds.insert(.caffeineMilligrams)
            }
        }
        for occurrence in state.foodSnapshot?.recentOccurrences ?? [] {
            if occurrence.nutrientTotals?.energyKilocalories != nil {
                kinds.insert(.energyKilocalories)
            }
            if occurrence.nutrientTotals?.proteinGrams != nil {
                kinds.insert(.proteinGrams)
            }
            if occurrence.nutrientTotals?.caffeineMilligrams != nil {
                kinds.insert(.caffeineMilligrams)
            }
        }
        return kinds
    }

    private func refreshFoodHealthAuthorization() async {
        let kinds = foodHealthNutrientKinds
        guard !kinds.isEmpty else {
            foodHealthAuthorization = .notDetermined
            return
        }
        #if canImport(HealthKit)
        foodHealthAuthorization = await foodHealthCoordinator.authorizationState(
            for: kinds
        )
        #else
        foodHealthAuthorization = .unavailable
        #endif
    }

    func reconcileFoodHealthWrites() async {
        #if canImport(HealthKit)
        guard foodHealthAuthorization == .authorized,
              let localServices
        else { return }
        do {
            let occurrences = try await localServices.foodOccurrenceService
                .recentOccurrences(limit: 500)
            let voidedOccurrenceIDs = try await localServices.foodOccurrenceService
                .voidedOccurrenceIDs(limit: 500)
            var writtenCount = 0
            var omittedAlcohol = false
            for occurrence in occurrences {
                let result = try await foodHealthCoordinator.writeIfAuthorized(occurrence)
                if case let .written(sampleCount, omittedAlcoholGrams) = result {
                    writtenCount += sampleCount
                    omittedAlcohol = omittedAlcohol || omittedAlcoholGrams != nil
                }
            }
            for occurrenceID in voidedOccurrenceIDs {
                _ = try await foodHealthCoordinator.deleteOwnedSamples(
                    occurrenceID: occurrenceID
                )
            }
            if writtenCount > 0 {
                foodHealthMessage = "Reconciled \(writtenCount) Odyssey nutrient sample"
                    + "\(writtenCount == 1 ? "" : "s") with Apple Health."
                if omittedAlcohol {
                    foodHealthMessage? += " Alcohol grams remain in Odyssey because no exact HealthKit type is used."
                }
            }
        } catch {
            foodHealthMessage = "Odyssey kept every food log locally, but Apple Health reconciliation will need another try."
        }
        #endif
    }

    private func writeFoodOccurrenceToHealth(
        _ occurrence: FoodOccurrence,
        replacingExisting: Bool = false
    ) async {
        #if canImport(HealthKit)
        do {
            let result = try await foodHealthCoordinator.writeIfAuthorized(
                occurrence,
                replacingExisting: replacingExisting
            )
            switch result {
            case let .written(sampleCount, omittedAlcoholGrams):
                if sampleCount == 0 {
                    foodHealthMessage = "Removed prior Odyssey nutrient samples from Apple Health."
                } else {
                    foodHealthMessage = "Wrote \(sampleCount) nutrient sample"
                        + "\(sampleCount == 1 ? "" : "s") to Apple Health."
                }
                if omittedAlcoholGrams != nil {
                    foodHealthMessage? += " Alcohol grams remain in Odyssey."
                }
            case .authorizationRequired:
                foodHealthAuthorization = .notDetermined
            case .denied:
                foodHealthAuthorization = .denied
            case .unavailable:
                foodHealthAuthorization = .unavailable
            case .noSupportedNutrients, .deleted:
                break
            }
        } catch {
            foodHealthMessage = "The food log is safe in Odyssey; Apple Health will need reconciliation later."
        }
        #endif
    }

    private func deleteFoodOccurrenceFromHealth(_ occurrenceID: UUIDv7) async {
        #if canImport(HealthKit)
        do {
            let result = try await foodHealthCoordinator.deleteOwnedSamples(
                occurrenceID: occurrenceID
            )
            if result == .deleted {
                foodHealthMessage = "Removed Odyssey-owned nutrient samples from Apple Health."
            }
        } catch {
            foodHealthMessage = "The log is voided in Odyssey; Apple Health cleanup will need reconciliation later."
        }
        #endif
    }

    private func completeFoodMutation(_ success: FoodQuickLogSuccess) async {
        let fallback = state.foodSnapshot
        do {
            let snapshot = try await foodQuickLogSnapshot(at: Date())
            apply(.foodMutationSucceeded(success, snapshot))
            publishWatchFoodSnapshot(snapshot)
        } catch {
            if let fallback {
                apply(.foodMutationSucceeded(success, fallback))
                publishWatchFoodSnapshot(fallback)
            } else {
                apply(.foodFailed(
                    "The food change was saved, but the local library could not be refreshed."
                ))
            }
        }
        await refreshDiagnostics()
        scheduleBackgroundRefresh()
        if state.canSynchronize {
            Task { [weak self] in
                await self?.synchronize()
            }
        }
    }

    private func completeCapture(_ receipt: ManualCaptureReceipt) async {
        apply(.captureSucceeded(
            captureID: receipt.capture.metadata.id,
            at: receipt.capture.capturedAt
        ))
        await refreshDiagnostics()
        refreshRecentCaptures()
        scheduleBackgroundRefresh()
        Task { [weak self] in
            await self?.interpretCapture(receipt.capture.metadata.id)
        }
        if state.canSynchronize {
            Task { [weak self] in
                await self?.synchronize()
            }
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

    private func interpretCapture(_ captureID: UUIDv7) async {
        guard let localServices else { return }
        do {
            let result = try await localServices.captureInterpretationService.interpret(
                captureID: captureID,
                using: DeterministicCaptureInterpreter()
            )
            guard case .recorded = result else { return }
            await refreshAfterCaptureMutation()
        } catch {
            return
        }
    }

    private func refreshAfterCaptureMutation() async {
        refreshRecentCaptures()
        await refreshDiagnostics()
        await refreshNowExperience(markSeen: false)
        scheduleBackgroundRefresh()
        if state.canSynchronize {
            Task { [weak self] in
                await self?.synchronize()
            }
        }
    }

    private func resumePendingCaptureInterpretations() async {
        guard let localServices else { return }
        let captureIDs: [UUIDv7]
        do {
            captureIDs = try await localServices.captureInterpretationService
                .pendingCaptureIDs()
        } catch {
            return
        }
        for captureID in captureIDs {
            await interpretCapture(captureID)
        }
    }

    private func deliverLifeModelAcceptances() async {
        guard let localServices, let remoteServices else { return }
        apply(.workshopDeliveryStarted)
        guard state.workshopPhase == .delivering else { return }
        do {
            _ = try await remoteServices.lifeModelAcceptanceCoordinator.synchronize()
            let snapshot = try await localServices.lifeModelWorkshopService.snapshot()
            apply(.workshopDeliveryFinished(snapshot))
            await refreshNowExperience(markSeen: false)
        } catch {
            apply(.workshopFailed(
                "Life-model delivery did not complete. The reviewed command remains local "
                    + "and will retry safely."
            ))
        }
    }

    private var workshopCharterVersionID: UUIDv7? {
        guard let snapshot = state.workshopSnapshot else { return nil }
        if let queued = snapshot.acceptanceCommands.first(where: {
            $0.command.kind == .charter
                && ($0.deliveryStatus == .pending
                    || $0.deliveryStatus == .retry
                    || $0.deliveryStatus == .accepted)
        }) {
            return queued.command.versionID
        }
        return snapshot.acceptedVersions.first(where: { $0.kind == .charter })?.versionID
    }

    private func workshopMessage(
        for error: Error,
        fallback: String
    ) -> String {
        switch error {
        case let error as LifeModelWorkshopError:
            error.errorDescription ?? fallback
        case let error as LifeModelWorkshopDraftFactoryError:
            error.errorDescription ?? fallback
        case let error as LifeModelWorkshopEditorError:
            error.errorDescription ?? fallback
        case let error as WorkshopApplicationError:
            error.errorDescription ?? fallback
        default:
            fallback
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
            ),
            appBuild: try appVersion()
        )
    }

    private func makeAppGroupRoot() throws -> URL {
        guard let appGroup = Bundle.main.object(
            forInfoDictionaryKey: "ODYSSEY_APP_GROUP"
        ) as? String,
            !appGroup.isEmpty
        else {
            throw ExtensionCommandError.appGroupUnavailable
        }
        return try ExtensionCommandQueue.appGroupRoot(identifier: appGroup)
    }

    private func drainExtensionCommands(limit: Int = 50) async {
        guard !isDrainingExtensionCommands else { return }
        guard let queue = extensionCommandQueue,
              let processor = extensionCommandProcessor
        else { return }
        isDrainingExtensionCommands = true
        defer { isDrainingExtensionCommands = false }
        do {
            _ = try await queue.recoverInterruptedClaims()
            var processedCount = 0
            commandLoop: for _ in 0 ..< limit {
                guard let claim = try await queue.claimNext() else { break }
                do {
                    let result = try await processor.process(
                        claim.command,
                        captureTimeZoneID: TimeZone.current.identifier,
                        captureLocationPermissionState: .unavailable
                    )
                    var stopAfterAcknowledgment = false
                    switch result {
                    case let .captureCommitted(receipt):
                        Task { [weak self] in
                            await self?.interpretCapture(receipt.capture.metadata.id)
                        }
                    case let .captureAlreadyCommitted(capture):
                        Task { [weak self] in
                            await self?.interpretCapture(capture.metadata.id)
                        }
                    case let .foodCommitted(receipt):
                        Task { [weak self, occurrence = receipt.occurrence] in
                            await self?.writeFoodOccurrenceToHealth(occurrence)
                        }
                    case let .foodAlreadyCommitted(occurrence):
                        Task { [weak self] in
                            await self?.writeFoodOccurrenceToHealth(occurrence)
                        }
                    case let .presentationRequested(presentation):
                        extensionPresentationRequest = presentation
                        stopAfterAcknowledgment = true
                    }
                    try await queue.acknowledge(claim)
                    if result.committedNewMutation {
                        processedCount += 1
                    }
                    if stopAfterAcknowledgment {
                        break commandLoop
                    }
                } catch let error as FoodOccurrenceServiceError {
                    switch error {
                    case .presetNotFound, .invalidPresetProjection, .stalePresetRevision,
                         .presetArchived, .invalidConfiguration:
                        try await queue.reject(claim)
                        continue
                    default:
                        try await queue.retry(claim)
                        break commandLoop
                    }
                } catch let error as ExtensionCommandError {
                    _ = error
                    try await queue.reject(claim)
                    continue
                } catch let error as ExtensionCommandProcessingError {
                    _ = error
                    try await queue.reject(claim)
                    continue
                } catch {
                    try await queue.retry(claim)
                    break commandLoop
                }
            }
            if processedCount > 0 {
                extensionCommandMessage = "Committed \(processedCount) extension command"
                    + "\(processedCount == 1 ? "" : "s") to the local ledger."
                refreshRecentCaptures()
                await refreshFoodQuickLog()
                await refreshDiagnostics()
                await refreshNowExperience(markSeen: false)
                scheduleBackgroundRefresh()
            }
        } catch {
            extensionCommandMessage =
                "Extension commands remain protected and will retry on the next launch."
        }
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

    private func telemetryFeedbackMessage(
        for disposition: ProductTelemetryRecordingDisposition
    ) -> String {
        switch disposition {
        case .recorded:
            "Feedback saved only in this device's governed product telemetry."
        case .skippedByPreference:
            "Feedback was not stored because local product telemetry is off for this question."
        case .skippedByFeatureFlag:
            "Feedback was not stored because this product question is disabled."
        case .skippedByStorage:
            "Feedback was not stored because the local telemetry preference changed."
        case .unsupportedContext, .failed:
            "Feedback could not be stored; the product experience is otherwise unchanged."
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

private enum WorkshopApplicationError: LocalizedError {
    case charterRequired

    var errorDescription: String? {
        switch self {
        case .charterRequired:
            "Review and queue the Charter before creating its first season."
        }
    }
}
