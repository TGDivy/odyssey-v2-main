import AuthenticationServices
import BackgroundTasks
import Combine
import CoreLocation
import Foundation
import OdysseyApplication
import OdysseyAuth
import OdysseyData
import OdysseyDomain
import OdysseyExtensionBridge
import OdysseyHealth
import OdysseySync
import UIKit

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
    @Published private(set) var extensionCommandMessage: String?
    @Published private(set) var extensionPresentationRequest: ExtensionCommandPresentation?

    private var localServices: NativeLocalServices?
    private var remoteServices: NativeRemoteServices?
    private var workshopDraftFactory: LifeModelWorkshopDraftFactory?
    private var isBootstrapping = false
    private var isDrainingExtensionCommands = false
    private var extensionCommandQueue: ExtensionCommandQueue?
    private var extensionCommandProcessor: ExtensionCommandProcessor?

    #if canImport(HealthKit)
    private let foodHealthCoordinator = FoodHealthWriteCoordinator(
        writer: HealthKitFoodWriter()
    )
    #endif

    var captureImportBuffer: LocalCaptureImportBuffer? {
        localServices?.captureImportBuffer
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
        apply(.bootstrapStarted)
        localServices = nil
        remoteServices = nil
        workshopDraftFactory = nil
        extensionCommandQueue = nil
        extensionCommandProcessor = nil
        extensionCommandMessage = nil
        extensionPresentationRequest = nil

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
                extensionCommandQueue = try makeExtensionCommandQueue()
            } catch {
                extensionCommandMessage =
                    "Extension quick capture is unavailable until the App Group is configured."
            }
            apply(.localReady)
            await refreshDiagnostics()
            refreshRecentCaptures()
            await refreshWorkshop()
            await refreshFoodQuickLog()
            await drainExtensionCommands()
            if foodHealthAuthorization == .authorized {
                Task { [weak self] in
                    await self?.reconcileFoodHealthWrites()
                }
            }
            Task { [weak self] in
                await self?.resumePendingCaptureInterpretations()
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
            apply(.foodLoaded(try await foodQuickLogSnapshot(at: Date())))
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

    func dismissExtensionCommandMessage() {
        extensionCommandMessage = nil
    }

    func consumeExtensionPresentationRequest() {
        extensionPresentationRequest = nil
    }

    func refreshCaptureArchive() async {
        refreshRecentCaptures()
        await refreshDiagnostics()
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

    private func refreshDiagnostics() async {
        guard let localServices else { return }
        do {
            apply(.diagnosticsUpdated(try await localServices.localDiagnostics()))
        } catch {
            return
        }
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
            apply(.foodMutationSucceeded(success, try await foodQuickLogSnapshot(at: Date())))
        } catch {
            if let fallback {
                apply(.foodMutationSucceeded(success, fallback))
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
            )
        )
    }

    private func makeExtensionCommandQueue() throws -> ExtensionCommandQueue {
        guard let appGroup = Bundle.main.object(
            forInfoDictionaryKey: "ODYSSEY_APP_GROUP"
        ) as? String,
            !appGroup.isEmpty
        else {
            throw ExtensionCommandError.appGroupUnavailable
        }
        return try ExtensionCommandQueue(
            rootDirectory: ExtensionCommandQueue.appGroupRoot(identifier: appGroup)
        )
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
