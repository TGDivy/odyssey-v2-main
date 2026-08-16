import OdysseyIntegrations
import OdysseyWeather

enum WeatherContextActivity: Equatable {
    case idle
    case refreshing
    case importing
    case revoking
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .refreshing, .importing, .revoking:
            true
        case .idle, .failed:
            false
        }
    }
}

struct WeatherContextIntegrationState {
    var overview: WeatherMirrorOverview?
    var activity: WeatherContextActivity = .idle
    var message: String?
    var localMirrorRevoked = false

    var integrationHealth: IntegrationHealthSnapshot? {
        guard let overview else { return nil }
        return try? IntegrationHealthSnapshot(
            connector: .weather,
            observedAt: overview.observedAt,
            operationalState: operationalState,
            permission: overview.permission,
            lastSuccessfulSync: overview.lastSuccessfulRefreshAt,
            newestSourceTimestamp: overview.newestSourceTimestamp,
            rejectedRecordCount: overview.rejectedRecordCount,
            rateLimitState: overview.rateLimitState,
            revocationSupported: true,
            contribution: .planningWeather
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
        case .idle, .refreshing, .revoking:
            break
        }
        guard overview?.capability.availability == .available else {
            return .disabled
        }
        switch overview?.lastOutcome {
        case .fetched:
            return overview?.cacheIsFresh == true ? .healthy : .degraded
        case .rateLimited, .unavailable:
            return .degraded
        case nil:
            if overview?.cachedPlace != nil {
                return overview?.cacheIsFresh == true ? .healthy : .degraded
            }
            return .idle
        }
    }
}

extension IntegrationRateLimitState {
    var ownerDisplayName: String {
        switch self {
        case .notApplicable:
            "Not applicable"
        case .ready:
            "Ready"
        case .limited:
            "Limited"
        }
    }
}

extension WeatherMirrorOutcome {
    var ownerDisplayName: String {
        switch self {
        case .fetched:
            "Fetched"
        case .unavailable:
            "Unavailable"
        case .rateLimited:
            "Rate limited"
        }
    }
}
