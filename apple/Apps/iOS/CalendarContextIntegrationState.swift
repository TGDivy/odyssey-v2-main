import Foundation
import OdysseyCalendar
import OdysseyIntegrations

enum CalendarContextActivity: Equatable {
    case idle
    case refreshing
    case authorizing
    case importing
    case revoking
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .refreshing, .authorizing, .importing, .revoking:
            true
        case .idle, .failed:
            false
        }
    }
}

struct CalendarContextIntegrationState {
    var overview: CalendarMirrorOverview?
    var activity: CalendarContextActivity = .idle
    var rejectedRecordCount = 0
    var message: String?
    var localMirrorRevoked = false

    var canRequestFullAccess: Bool {
        guard !activity.isBusy,
              overview?.capability.availability == .available,
              overview?.capability.supportsFullAccessRead == true
        else {
            return false
        }
        return overview?.permission == .notDetermined
            || overview?.permission == .partial
    }

    var canRefresh: Bool {
        !activity.isBusy
            && overview?.capability.availability == .available
            && overview?.permission == .authorized
    }

    var integrationHealth: IntegrationHealthSnapshot? {
        guard let overview else { return nil }
        return try? IntegrationHealthSnapshot(
            connector: .calendar,
            observedAt: overview.observedAt,
            operationalState: operationalState,
            permission: overview.permission,
            lastSuccessfulSync: overview.lastSuccessfulRefreshAt,
            newestSourceTimestamp: overview.newestSourceVersion,
            rejectedRecordCount: rejectedRecordCount,
            rateLimitState: .notApplicable,
            revocationSupported: true,
            contribution: .calendarConstraints
        )
    }

    var operationalState: IntegrationOperationalState {
        if localMirrorRevoked {
            return .revoked
        }
        switch activity {
        case .importing:
            return .syncing
        case .failed:
            return .failed
        case .idle, .refreshing, .authorizing, .revoking:
            break
        }
        guard overview?.capability.availability == .available else {
            return .disabled
        }
        switch overview?.permission {
        case .denied, .restricted, .unavailable, .partial:
            return .degraded
        case .authorized:
            return overview?.lastSuccessfulRefreshAt == nil ? .idle : .healthy
        case .notDetermined, .notRequired, .none:
            return .idle
        }
    }
}
