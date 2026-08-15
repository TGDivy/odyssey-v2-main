import Foundation
import OdysseyAuth
import OdysseyData
import OdysseyDomain
import OdysseySync

public enum NativeApplicationConfigurationError: Error, Equatable, Sendable {
    case invalidApplicationIdentifier
    case invalidStorageDirectory
    case invalidOwnerActor
    case invalidKeychainAccessGroup
    case invalidRemoteEnvironment
    case invalidRemoteBaseURL
    case placeholderRemoteHost
    case insecureRemoteHost
    case invalidAppVersion
}

extension NativeApplicationConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidApplicationIdentifier:
            "The app identifier is missing or invalid."
        case .invalidStorageDirectory:
            "The Application Support storage directory is invalid."
        case .invalidOwnerActor:
            "The local owner actor identifier is invalid."
        case .invalidKeychainAccessGroup:
            "The Keychain access group is invalid."
        case .invalidRemoteEnvironment:
            "The Odyssey deployment environment is invalid."
        case .invalidRemoteBaseURL:
            "The Odyssey API base URL is missing or invalid."
        case .placeholderRemoteHost:
            "The Odyssey API still uses a non-routable placeholder host."
        case .insecureRemoteHost:
            "Plain HTTP is allowed only for a loopback development server."
        case .invalidAppVersion:
            "The app version is missing or invalid."
        }
    }
}

public struct NativeLocalConfiguration: Sendable {
    public let applicationIdentifier: String
    public let applicationSupportDirectory: URL
    public let ownerActorID: String
    public let keychainAccessGroup: String?

    public init(
        applicationIdentifier: String,
        applicationSupportDirectory: URL,
        ownerActorID: String = "owner",
        keychainAccessGroup: String? = nil
    ) throws {
        guard Self.isIdentifier(applicationIdentifier) else {
            throw NativeApplicationConfigurationError.invalidApplicationIdentifier
        }
        guard applicationSupportDirectory.isFileURL,
              applicationSupportDirectory.path.hasPrefix("/")
        else {
            throw NativeApplicationConfigurationError.invalidStorageDirectory
        }
        guard Self.isIdentifier(ownerActorID) else {
            throw NativeApplicationConfigurationError.invalidOwnerActor
        }
        if let keychainAccessGroup, !Self.isIdentifier(keychainAccessGroup) {
            throw NativeApplicationConfigurationError.invalidKeychainAccessGroup
        }
        self.applicationIdentifier = applicationIdentifier
        self.applicationSupportDirectory = applicationSupportDirectory
        self.ownerActorID = ownerActorID
        self.keychainAccessGroup = keychainAccessGroup
    }

    public var databaseURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("odyssey.sqlite", isDirectory: false)
    }

    public var preMigrationBackupDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("Migrations", isDirectory: true)
    }

    public var keychainConfiguration: KeychainCredentialConfiguration {
        KeychainCredentialConfiguration(
            service: "\(applicationIdentifier).credentials",
            accessGroup: keychainAccessGroup
        )
    }

    private static func isIdentifier(_ value: String) -> Bool {
        (1 ... 200).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: ".-_"))
                    .contains($0)
            }
    }
}

public enum NativeDeploymentEnvironment: String, Codable, CaseIterable, Hashable, Sendable {
    case development
    case staging
    case production
}

public struct NativeRemoteConfiguration: Sendable {
    public let baseURL: URL
    public let environment: NativeDeploymentEnvironment
    public let platform: DevicePlatform
    public let appVersion: String
    public let timeout: TimeInterval

    public init(
        baseURL: URL,
        environment: NativeDeploymentEnvironment,
        platform: DevicePlatform,
        appVersion: String,
        timeout: TimeInterval = 30
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              let host = baseURL.host?.lowercased(),
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              timeout.isFinite,
              timeout > 0
        else {
            throw NativeApplicationConfigurationError.invalidRemoteBaseURL
        }
        guard !host.hasSuffix(".example.invalid"), host != "example.invalid" else {
            throw NativeApplicationConfigurationError.placeholderRemoteHost
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https"
            || (scheme == "http" && environment == .development && isLoopback)
        else {
            throw NativeApplicationConfigurationError.insecureRemoteHost
        }
        guard (1 ... 100).contains(appVersion.count),
              appVersion == appVersion.trimmingCharacters(in: .whitespacesAndNewlines),
              appVersion.utf8.allSatisfy({ (32 ... 126).contains($0) })
        else {
            throw NativeApplicationConfigurationError.invalidAppVersion
        }
        self.baseURL = baseURL
        self.environment = environment
        self.platform = platform
        self.appVersion = appVersion
        self.timeout = timeout
    }

    public var allowsInsecureLoopbackDevelopment: Bool {
        baseURL.scheme?.lowercased() == "http"
    }

    public var userAgent: String {
        "Odyssey/\(appVersion) (\(platform.rawValue); \(environment.rawValue))"
    }
}

public struct NativeLocalServices: Sendable {
    public let credentialVault: any CredentialVault
    public let deviceID: UUIDv7
    public let ledgerStore: SQLiteLedgerStore
    public let captureService: ManualCaptureService

    public static func bootstrap(
        configuration: NativeLocalConfiguration
    ) async throws -> Self {
        let vault = try KeychainCredentialVault(
            configuration: configuration.keychainConfiguration
        )
        return try await bootstrap(configuration: configuration, vault: vault)
    }

    public static func bootstrap(
        configuration: NativeLocalConfiguration,
        vault: any CredentialVault
    ) async throws -> Self {
        let deviceID = try await vault.loadOrCreateDeviceID()
        let ledgerStore = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: configuration.databaseURL,
                deviceID: deviceID,
                preMigrationBackupDirectory: configuration.preMigrationBackupDirectory
            )
        )
        let captureService = try ManualCaptureService(
            store: ledgerStore,
            deviceID: deviceID,
            ownerActorID: configuration.ownerActorID
        )
        return Self(
            credentialVault: vault,
            deviceID: deviceID,
            ledgerStore: ledgerStore,
            captureService: captureService
        )
    }

    public func localDiagnostics(
        attachmentBacklog: Int = 0
    ) async throws -> NativeSyncDiagnostics {
        guard attachmentBacklog >= 0 else {
            throw DurableSyncCoordinatorError.invalidLocalState(
                "Attachment backlog cannot be negative."
            )
        }
        let local = try await ledgerStore.localSyncDiagnostics()
        let state = local.syncState
        let serverSchemaVersion = state.serverSchemaVersion
        let compatibility: NativeSchemaCompatibility
        if let serverSchemaVersion, serverSchemaVersion < SyncSchema.currentVersion {
            compatibility = .serverUpgradeRequired
        } else if serverSchemaVersion == SyncSchema.currentVersion {
            compatibility = .compatible
        } else {
            compatibility = .unknown
        }
        return NativeSyncDiagnostics(
            deviceID: state.deviceID,
            lastSuccessfulPushAt: state.lastSuccessfulPushAt,
            lastSuccessfulPullAt: state.lastSuccessfulPullAt,
            operationsQueued: local.operationsQueued,
            oldestUnsyncedOperationAt: local.oldestUnsyncedOperationAt,
            conflictCount: local.conflictCount,
            attachmentBacklog: attachmentBacklog,
            deviceCursor: try SyncCursor(state.cursor),
            serverCursor: try SyncCursor(state.serverCursor),
            serverSchemaVersion: serverSchemaVersion,
            schemaCompatibility: compatibility
        )
    }

    public func recentCaptures(limit: Int = 50) throws -> [CaptureRecord] {
        try ledgerStore.projectedEntities(entityType: ManualCaptureService.entityType, limit: limit)
            .map {
                try SyncJSONCoding.makeDecoder().decode(
                    CaptureRecord.self,
                    from: $0.document
                )
            }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
}

public struct NativeRemoteServices: Sendable {
    public let configuration: NativeRemoteConfiguration
    public let authClient: URLSessionAuthClient
    public let tokenSession: AccessTokenSession
    public let syncTransport: URLSessionSyncTransport
    public let syncCoordinator: DurableSyncCoordinator
    public let lifeModelTransport: URLSessionLifeModelTransport
    public let lifeModelAcceptanceCoordinator: LifeModelAcceptanceCoordinator
    private let credentialVault: any CredentialVault

    public init(
        localServices: NativeLocalServices,
        configuration: NativeRemoteConfiguration
    ) throws {
        let authClient = try URLSessionAuthClient(
            configuration: URLSessionAuthClientConfiguration(
                baseURL: configuration.baseURL,
                timeout: configuration.timeout,
                userAgent: configuration.userAgent,
                allowsInsecureTransportForTesting: configuration.allowsInsecureLoopbackDevelopment
            )
        )
        let tokenSession = try AccessTokenSession(
            vault: localServices.credentialVault,
            client: authClient
        )
        let syncTransport = try URLSessionSyncTransport(
            configuration: URLSessionSyncTransportConfiguration(
                baseURL: configuration.baseURL,
                timeout: configuration.timeout,
                userAgent: configuration.userAgent,
                allowsInsecureTransportForTesting: configuration.allowsInsecureLoopbackDevelopment
            ),
            tokenProvider: tokenSession
        )
        let syncCoordinator = try DurableSyncCoordinator(
            store: localServices.ledgerStore,
            transport: syncTransport
        )
        let lifeModelTransport = try URLSessionLifeModelTransport(
            configuration: configuration,
            tokenProvider: tokenSession
        )
        let lifeModelAcceptanceCoordinator = try LifeModelAcceptanceCoordinator(
            store: localServices.ledgerStore,
            transport: lifeModelTransport
        )
        self.configuration = configuration
        self.authClient = authClient
        self.tokenSession = tokenSession
        self.syncTransport = syncTransport
        self.syncCoordinator = syncCoordinator
        self.lifeModelTransport = lifeModelTransport
        self.lifeModelAcceptanceCoordinator = lifeModelAcceptanceCoordinator
        credentialVault = localServices.credentialVault
    }

    public func appleEnrollmentCoordinator(
        authorizer: any AppleAuthorizationPerforming
    ) -> AppleEnrollmentCoordinator {
        AppleEnrollmentCoordinator(
            vault: credentialVault,
            client: authClient,
            tokenSession: tokenSession,
            authorizer: authorizer
        )
    }
}
