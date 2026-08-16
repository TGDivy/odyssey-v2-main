import Foundation
import OdysseyIntegrations
import OdysseyLocation

enum LocationContextActivity: Equatable {
    case idle
    case refreshing
    case authorizing
    case acquiring
    case revoking
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .refreshing, .authorizing, .acquiring, .revoking:
            true
        case .idle, .failed:
            false
        }
    }
}

struct LocationContextIntegrationState {
    var overview: LocationContextOverview?
    var activity: LocationContextActivity = .idle
    var message: String?
    var localMirrorRevoked = false

    var canRequestWhenInUse: Bool {
        !activity.isBusy
            && overview?.capability.availability == .available
            && overview?.capability.supportsForegroundBroadPlace == true
            && overview?.permission == .notDetermined
    }

    var canRefresh: Bool {
        !activity.isBusy
            && overview?.capability.availability == .available
            && overview?.capability.supportsForegroundBroadPlace == true
            && overview?.permission == .authorized
    }

    var integrationHealth: IntegrationHealthSnapshot? {
        guard let overview else { return nil }
        return try? IntegrationHealthSnapshot(
            connector: .location,
            observedAt: overview.observedAt,
            operationalState: operationalState,
            permission: overview.permission,
            lastSuccessfulSync: overview.lastSuccessfulRefreshAt,
            newestSourceTimestamp: overview.cachedPlace?.capturedAt,
            rejectedRecordCount: overview.rejectedRecordCount,
            rateLimitState: .notApplicable,
            revocationSupported: true,
            contribution: .broadForegroundPlace
        )
    }

    var operationalState: IntegrationOperationalState {
        if localMirrorRevoked {
            return .revoked
        }
        switch activity {
        case .acquiring:
            return .syncing
        case .failed:
            return .failed
        case .idle, .refreshing, .authorizing, .revoking:
            break
        }
        guard overview?.capability.availability == .available,
              overview?.capability.supportsForegroundBroadPlace == true
        else {
            return .disabled
        }
        switch overview?.permission {
        case .denied, .restricted, .unavailable, .partial:
            return .degraded
        case .authorized:
            guard overview?.cachedPlace != nil else { return .idle }
            return overview?.cacheIsFresh == true ? .healthy : .degraded
        case .notDetermined, .notRequired, .none:
            return .idle
        }
    }
}

extension BroadPlacePrecision {
    var ownerDisplayName: String {
        switch self {
        case .locality:
            "Locality"
        case .administrativeArea:
            "Administrative area"
        case .timeZone:
            "Time zone only"
        }
    }
}

extension BroadLocationOutcome {
    var ownerDisplayName: String {
        switch self {
        case .acquired:
            "Acquired"
        case .permissionDenied:
            "Permission denied"
        case .restricted:
            "Restricted"
        case .unavailable:
            "Unavailable"
        case .insufficientAccuracy:
            "Insufficient broad accuracy"
        case .noFix:
            "No current fix"
        }
    }
}
