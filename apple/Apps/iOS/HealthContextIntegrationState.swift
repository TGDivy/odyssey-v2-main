import Foundation
import OdysseyHealth
import OdysseyIntegrations

enum HealthContextActivity: Equatable {
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

struct HealthContextIntegrationState {
    var overview: HealthImportOverview?
    var activity: HealthContextActivity = .idle
    var lastSuccessfulImportAt: Date?
    var rejectedRecordCount = 0
    var message: String?
    var localMirrorRevoked = false

    var canRequestAuthorization: Bool {
        !activity.isBusy
            && overview?.capability.availability == .available
            && overview?.permission == .notDetermined
    }

    var canImport: Bool {
        guard !activity.isBusy,
              overview?.capability.availability == .available
        else {
            return false
        }
        return overview?.permission == .authorized
            || overview?.permission == .partial
    }

    var integrationHealth: IntegrationHealthSnapshot? {
        guard let overview else { return nil }
        return try? IntegrationHealthSnapshot(
            connector: .health,
            observedAt: overview.observedAt,
            operationalState: operationalState,
            permission: overview.permission,
            lastSuccessfulSync: lastSuccessfulImportAt,
            newestSourceTimestamp: overview.newestSourceTimestamp,
            rejectedRecordCount: rejectedRecordCount,
            rateLimitState: .notApplicable,
            revocationSupported: true,
            contribution: .approvedHealthContext
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
        if overview?.changeObservationState == .failed {
            return .degraded
        }
        switch overview?.permission {
        case .denied, .restricted, .unavailable:
            return .degraded
        case .authorized, .partial:
            return lastSuccessfulImportAt == nil ? .idle : .healthy
        case .notDetermined, .notRequired, .none:
            return .idle
        }
    }
}

extension HealthChangeObservationState {
    var ownerDisplayName: String {
        switch self {
        case .unsupported:
            "Unsupported"
        case .inactive:
            "Inactive"
        case .active:
            "Registered"
        case .failed:
            "Registration failed"
        }
    }
}

extension HealthSampleKind {
    var ownerDisplayName: String {
        switch self {
        case .workout:
            "Workouts"
        case .heartRate:
            "Heart rate"
        case .restingHeartRate:
            "Resting heart rate"
        case .sleepAnalysis:
            "Sleep"
        case .bodyMass:
            "Body mass"
        case .activeEnergy:
            "Active energy"
        }
    }
}

extension IntegrationCapabilityAvailability {
    var ownerDisplayName: String {
        switch self {
        case .available:
            "Available"
        case .unavailable:
            "Unavailable"
        case .unsupported:
            "Unsupported"
        case .disabledByPolicy:
            "Disabled by policy"
        }
    }
}

extension IntegrationPermissionState {
    var ownerDisplayName: String {
        switch self {
        case .notRequired:
            "Not required"
        case .notDetermined:
            "Not requested"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        case .authorized:
            "Authorized"
        case .partial:
            "Granted types are private"
        case .unavailable:
            "Unavailable"
        }
    }
}

extension IntegrationOperationalState {
    var ownerDisplayName: String {
        switch self {
        case .disabled:
            "Disabled"
        case .idle:
            "Idle"
        case .syncing:
            "Importing"
        case .healthy:
            "Healthy"
        case .degraded:
            "Degraded"
        case .failed:
            "Failed"
        case .revoked:
            "Local mirror removed"
        }
    }
}
