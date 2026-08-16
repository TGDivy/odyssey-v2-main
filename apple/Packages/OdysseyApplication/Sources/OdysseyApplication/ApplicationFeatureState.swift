import Foundation
import OdysseyDomain
import OdysseySync

public enum ApplicationLocalReadiness: Equatable, Sendable {
    case launching
    case ready
    case unavailable(String)
}

public enum ApplicationRemoteReadiness: Equatable, Sendable {
    case checking
    case available
    case unavailable(String)
}

public enum ApplicationEnrollmentPhase: Equatable, Sendable {
    case checking
    case notEnrolled
    case credentialStored
    case authorizing
    case failed(String)
}

public enum ApplicationCapturePhase: Equatable, Sendable {
    case idle
    case saving
    case saved(captureID: UUIDv7, at: Date)
    case failed(String)
}

public enum ApplicationSyncPhase: Equatable, Sendable {
    case idle
    case synchronizing
    case succeeded(SyncRunReport)
    case failed(String)
}

public enum ApplicationMaintenancePhase: Equatable, Sendable {
    case idle
    case running
    case succeeded(String)
    case failed(String)
}

public enum ApplicationWorkshopPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case saving
    case reviewing
    case queueing
    case delivering
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .loading, .saving, .reviewing, .queueing, .delivering:
            true
        case .idle, .ready, .failed:
            false
        }
    }
}

public struct ApplicationFeatureState: Equatable, Sendable {
    public var localReadiness: ApplicationLocalReadiness
    public var remoteReadiness: ApplicationRemoteReadiness
    public var enrollmentPhase: ApplicationEnrollmentPhase
    public var capturePhase: ApplicationCapturePhase
    public var syncPhase: ApplicationSyncPhase
    public var maintenancePhase: ApplicationMaintenancePhase
    public var workshopPhase: ApplicationWorkshopPhase
    public var diagnostics: NativeSyncDiagnostics?
    public var recentCaptures: [CaptureRecord]
    public var workshopSnapshot: LifeModelWorkshopSnapshot?
    public var workshopReview: LifeModelDraftReview?

    public init(
        localReadiness: ApplicationLocalReadiness = .launching,
        remoteReadiness: ApplicationRemoteReadiness = .checking,
        enrollmentPhase: ApplicationEnrollmentPhase = .checking,
        capturePhase: ApplicationCapturePhase = .idle,
        syncPhase: ApplicationSyncPhase = .idle,
        maintenancePhase: ApplicationMaintenancePhase = .idle,
        workshopPhase: ApplicationWorkshopPhase = .idle,
        diagnostics: NativeSyncDiagnostics? = nil,
        recentCaptures: [CaptureRecord] = [],
        workshopSnapshot: LifeModelWorkshopSnapshot? = nil,
        workshopReview: LifeModelDraftReview? = nil
    ) {
        self.localReadiness = localReadiness
        self.remoteReadiness = remoteReadiness
        self.enrollmentPhase = enrollmentPhase
        self.capturePhase = capturePhase
        self.syncPhase = syncPhase
        self.maintenancePhase = maintenancePhase
        self.workshopPhase = workshopPhase
        self.diagnostics = diagnostics
        self.recentCaptures = recentCaptures
        self.workshopSnapshot = workshopSnapshot
        self.workshopReview = workshopReview
    }

    public var canCapture: Bool {
        localReadiness == .ready && capturePhase != .saving
    }

    public var canSynchronize: Bool {
        remoteReadiness == .available
            && enrollmentPhase == .credentialStored
            && syncPhase != .synchronizing
    }

    public var canUseWorkshop: Bool {
        localReadiness == .ready && !workshopPhase.isBusy
    }
}

public enum ApplicationFeatureAction: Equatable, Sendable {
    case bootstrapStarted
    case localReady
    case localUnavailable(String)
    case remoteReady
    case remoteUnavailable(String)
    case enrollmentObserved(stored: Bool)
    case enrollmentStarted
    case enrollmentSucceeded
    case enrollmentFailed(String)
    case captureStarted
    case captureSucceeded(captureID: UUIDv7, at: Date)
    case captureFailed(String)
    case captureDismissed
    case syncStarted
    case syncSucceeded(SyncRunReport)
    case syncFailed(String)
    case diagnosticsUpdated(NativeSyncDiagnostics)
    case recentCapturesUpdated([CaptureRecord])
    case maintenanceStarted
    case maintenanceSucceeded(String)
    case maintenanceFailed(String)
    case maintenanceDismissed
    case workshopLoadStarted
    case workshopLoaded(LifeModelWorkshopSnapshot)
    case workshopSaveStarted
    case workshopSaved(LifeModelWorkshopSnapshot)
    case workshopReviewStarted
    case workshopReviewPrepared(
        review: LifeModelDraftReview,
        snapshot: LifeModelWorkshopSnapshot
    )
    case workshopQueueStarted
    case workshopQueued(LifeModelWorkshopSnapshot)
    case workshopDeliveryStarted
    case workshopDeliveryFinished(LifeModelWorkshopSnapshot)
    case workshopFailed(String)
    case workshopReviewDismissed
}

public enum ApplicationFeatureReducer {
    public static func reduce(
        state: inout ApplicationFeatureState,
        action: ApplicationFeatureAction
    ) {
        switch action {
        case .bootstrapStarted:
            state = ApplicationFeatureState()
        case .localReady:
            state.localReadiness = .ready
        case let .localUnavailable(message):
            state.localReadiness = .unavailable(message)
            state.remoteReadiness = .unavailable(
                "Remote services remain disabled until local storage is available."
            )
            state.enrollmentPhase = .checking
            state.syncPhase = .idle
            state.diagnostics = nil
            state.recentCaptures = []
            state.workshopPhase = .idle
            state.workshopSnapshot = nil
            state.workshopReview = nil
        case .remoteReady:
            guard state.localReadiness == .ready else { return }
            state.remoteReadiness = .available
        case let .remoteUnavailable(message):
            state.remoteReadiness = .unavailable(message)
            state.syncPhase = .idle
        case let .enrollmentObserved(stored):
            guard state.localReadiness == .ready else { return }
            state.enrollmentPhase = stored ? .credentialStored : .notEnrolled
        case .enrollmentStarted:
            guard state.localReadiness == .ready,
                  state.remoteReadiness == .available
            else { return }
            state.enrollmentPhase = .authorizing
        case .enrollmentSucceeded:
            state.enrollmentPhase = .credentialStored
        case let .enrollmentFailed(message):
            state.enrollmentPhase = .failed(message)
        case .captureStarted:
            guard state.localReadiness == .ready,
                  state.capturePhase != .saving
            else { return }
            state.capturePhase = .saving
        case let .captureSucceeded(captureID, at):
            guard state.capturePhase == .saving else { return }
            state.capturePhase = .saved(captureID: captureID, at: at)
        case let .captureFailed(message):
            guard state.capturePhase == .saving else { return }
            state.capturePhase = .failed(message)
        case .captureDismissed:
            guard state.capturePhase != .saving else { return }
            state.capturePhase = .idle
        case .syncStarted:
            guard state.remoteReadiness == .available,
                  state.enrollmentPhase == .credentialStored,
                  state.syncPhase != .synchronizing
            else { return }
            state.syncPhase = .synchronizing
        case let .syncSucceeded(report):
            guard state.syncPhase == .synchronizing else { return }
            state.syncPhase = .succeeded(report)
        case let .syncFailed(message):
            guard state.syncPhase == .synchronizing else { return }
            state.syncPhase = .failed(message)
        case let .diagnosticsUpdated(diagnostics):
            guard state.localReadiness == .ready else { return }
            state.diagnostics = diagnostics
        case let .recentCapturesUpdated(captures):
            guard state.localReadiness == .ready else { return }
            state.recentCaptures = captures
        case .maintenanceStarted:
            guard state.localReadiness == .ready,
                  state.maintenancePhase != .running
            else { return }
            state.maintenancePhase = .running
        case let .maintenanceSucceeded(message):
            guard state.maintenancePhase == .running else { return }
            state.maintenancePhase = .succeeded(message)
        case let .maintenanceFailed(message):
            guard state.maintenancePhase == .running else { return }
            state.maintenancePhase = .failed(message)
        case .maintenanceDismissed:
            guard state.maintenancePhase != .running else { return }
            state.maintenancePhase = .idle
        case .workshopLoadStarted:
            guard state.localReadiness == .ready,
                  !state.workshopPhase.isBusy
            else { return }
            state.workshopPhase = .loading
        case let .workshopLoaded(snapshot):
            guard state.workshopPhase == .loading else { return }
            state.workshopPhase = .ready
            state.workshopSnapshot = snapshot
            state.workshopReview = nil
        case .workshopSaveStarted:
            guard state.localReadiness == .ready,
                  !state.workshopPhase.isBusy
            else { return }
            state.workshopPhase = .saving
            state.workshopReview = nil
        case let .workshopSaved(snapshot):
            guard state.workshopPhase == .saving else { return }
            state.workshopPhase = .ready
            state.workshopSnapshot = snapshot
        case .workshopReviewStarted:
            guard state.localReadiness == .ready,
                  !state.workshopPhase.isBusy
            else { return }
            state.workshopPhase = .reviewing
            state.workshopReview = nil
        case let .workshopReviewPrepared(review, snapshot):
            guard state.workshopPhase == .reviewing else { return }
            state.workshopPhase = .ready
            state.workshopSnapshot = snapshot
            state.workshopReview = review
        case .workshopQueueStarted:
            guard state.localReadiness == .ready,
                  state.workshopReview != nil,
                  !state.workshopPhase.isBusy
            else { return }
            state.workshopPhase = .queueing
        case let .workshopQueued(snapshot):
            guard state.workshopPhase == .queueing else { return }
            state.workshopPhase = .ready
            state.workshopSnapshot = snapshot
            state.workshopReview = nil
        case .workshopDeliveryStarted:
            guard state.localReadiness == .ready,
                  !state.workshopPhase.isBusy
            else { return }
            state.workshopPhase = .delivering
        case let .workshopDeliveryFinished(snapshot):
            guard state.workshopPhase == .delivering else { return }
            state.workshopPhase = .ready
            state.workshopSnapshot = snapshot
            state.workshopReview = nil
        case let .workshopFailed(message):
            guard state.localReadiness == .ready else { return }
            state.workshopPhase = .failed(message)
        case .workshopReviewDismissed:
            guard !state.workshopPhase.isBusy else { return }
            state.workshopReview = nil
        }
    }
}
