import Foundation
import OdysseyAuth
import OdysseyCalendar
import OdysseyData
import OdysseyDomain
import OdysseyHealth
import OdysseyIntelligence
import OdysseyLocation
import OdysseySync
import OdysseyTelemetry
import OdysseyWeather

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
    case featureConfigurationVerificationUnavailable
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
        case .featureConfigurationVerificationUnavailable:
            "Feature configuration trust is set, but no Ed25519 verifier is available."
        }
    }
}

public struct NativeLocalConfiguration: Sendable {
    public let applicationIdentifier: String
    public let applicationSupportDirectory: URL
    public let ownerActorID: String
    public let appBuild: String
    public let keychainAccessGroup: String?
    public let featureConfigurationTrust: NativeFeatureConfigurationTrust?

    public init(
        applicationIdentifier: String,
        applicationSupportDirectory: URL,
        ownerActorID: String = "owner",
        appBuild: String = "development",
        keychainAccessGroup: String? = nil,
        featureConfigurationTrust: NativeFeatureConfigurationTrust? = nil
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
        guard Self.isAppBuild(appBuild) else {
            throw NativeApplicationConfigurationError.invalidAppVersion
        }
        if let keychainAccessGroup, !Self.isIdentifier(keychainAccessGroup) {
            throw NativeApplicationConfigurationError.invalidKeychainAccessGroup
        }
        self.applicationIdentifier = applicationIdentifier
        self.applicationSupportDirectory = applicationSupportDirectory
        self.ownerActorID = ownerActorID
        self.appBuild = appBuild
        self.keychainAccessGroup = keychainAccessGroup
        self.featureConfigurationTrust = featureConfigurationTrust
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

    public var attachmentDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    public var captureImportDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("CaptureImports", isDirectory: true)
            .appendingPathComponent("Temporary", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
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

    private static func isAppBuild(_ value: String) -> Bool {
        (1 ... 100).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.allSatisfy { (32 ... 126).contains($0) }
    }
}

public enum NativeDeploymentEnvironment: String, Codable, CaseIterable, Hashable, Sendable {
    case development
    case staging
    case production
}

public enum NativeFeatureConfigurationTrustError: Error, Equatable, Sendable {
    case invalidKeyID
    case invalidPublicKey
}

public struct NativeFeatureConfigurationTrust: Sendable {
    public let keyID: String
    public let environment: NativeDeploymentEnvironment
    let publicKey: Data

    public init(
        keyID: String,
        publicKeyBase64: String,
        environment: NativeDeploymentEnvironment
    ) throws {
        guard (1 ... 100).contains(keyID.count),
              keyID.unicodeScalars.allSatisfy({
                  $0.isASCII
                      && (CharacterSet.alphanumerics.contains($0)
                          || "._-".unicodeScalars.contains($0))
              })
        else {
            throw NativeFeatureConfigurationTrustError.invalidKeyID
        }
        guard let publicKey = Data(base64Encoded: publicKeyBase64),
              publicKey.count == 32,
              publicKey.base64EncodedString() == publicKeyBase64
        else {
            throw NativeFeatureConfigurationTrustError.invalidPublicKey
        }
        self.keyID = keyID
        self.environment = environment
        self.publicKey = publicKey
    }
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
    public let applicationIdentifier: String
    public let credentialVault: any CredentialVault
    public let deviceID: UUIDv7
    public let ledgerStore: SQLiteLedgerStore
    public let productTelemetryRecorder: ProductTelemetryRecorder
    public let weeklyProductReviewService: WeeklyProductReviewService
    public let productTelemetryPrivacyService: ProductTelemetryPrivacyService
    public let captureService: ManualCaptureService
    public let captureAttachmentStore: LocalCaptureAttachmentStore
    public let captureImportBuffer: LocalCaptureImportBuffer
    public let mediaCaptureService: LocalMediaCaptureService
    public let captureInterpretationService: CaptureInterpretationService
    public let foodPresetService: FoodPresetService
    public let foodOccurrenceService: FoodOccurrenceService
    public let calendarMirrorCoordinator: CalendarMirrorCoordinator
    public let healthImportCoordinator: HealthImportCoordinator
    public let locationContextCoordinator: LocationContextCoordinator
    public let weatherMirrorCoordinator: WeatherMirrorCoordinator
    public let foregroundContextRefreshCoordinator: ForegroundContextRefreshCoordinator
    public let lifeModelWorkshopService: LifeModelWorkshopService
    public let nowExperienceService: NowExperienceService
    public let attachmentRecoveryState: LocalCaptureAttachmentRecoveryState
    public let featureConfigurationTrust: NativeFeatureConfigurationTrust?

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
        vault: any CredentialVault,
        healthImporter: (any IncrementalHealthImporting)? = nil,
        calendarAdapter: (any CalendarContextProviding)? = nil,
        locationAdapter: (any LocationContextProviding)? = nil,
        weatherAdapter: (any WeatherContextProviding)? = nil,
        featureConfigurationSignatureVerifier: (
            any FeatureConfigurationSignatureVerifying
        )? = nil
    ) async throws -> Self {
        let deviceID = try await vault.loadOrCreateDeviceID()
        let featureConfigurationVerifier = try makeFeatureConfigurationVerifier(
            configuration: configuration,
            signatureVerifier: featureConfigurationSignatureVerifier
        )
        let ledgerStore = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: configuration.databaseURL,
                deviceID: deviceID,
                preMigrationBackupDirectory: configuration.preMigrationBackupDirectory,
                featureConfigurationVerifier: featureConfigurationVerifier
            )
        )
        let productTelemetryRecorder = try ProductTelemetryRecorder(
            store: ledgerStore,
            deviceID: deviceID,
            appBuild: configuration.appBuild,
            featureAssignments: {
                try ledgerStore.resolveFeatureConfiguration(
                    assignmentSubject: deviceID.description
                ).assignments
            }
        )
        let weeklyProductReviewService = WeeklyProductReviewService(
            store: ledgerStore,
            featureAssignments: {
                try ledgerStore.resolveFeatureConfiguration(
                    assignmentSubject: deviceID.description
                ).assignments
            }
        )
        let productTelemetryPrivacyService = ProductTelemetryPrivacyService(
            store: ledgerStore,
            recorder: productTelemetryRecorder,
            featureConfiguration: {
                try ledgerStore.resolveFeatureConfiguration(
                    assignmentSubject: deviceID.description
                )
            }
        )
        let captureService = try ManualCaptureService(
            store: ledgerStore,
            deviceID: deviceID,
            ownerActorID: configuration.ownerActorID,
            productTelemetryRecorder: productTelemetryRecorder
        )
        let captureAttachmentStore = try LocalCaptureAttachmentStore(
            configuration: LocalCaptureAttachmentStoreConfiguration(
                rootDirectory: configuration.attachmentDirectory
            )
        )
        let captureImportBuffer = try LocalCaptureImportBuffer(
            configuration: LocalCaptureImportBufferConfiguration(
                rootDirectory: configuration.captureImportDirectory
            )
        )
        let mediaCaptureService = LocalMediaCaptureService(
            attachmentStore: captureAttachmentStore,
            captureService: captureService
        )
        let captureInterpretationService = CaptureInterpretationService(
            store: ledgerStore
        )
        let foodPresetService = try FoodPresetService(
            store: ledgerStore,
            ownerActorID: configuration.ownerActorID
        )
        let foodOccurrenceService = try FoodOccurrenceService(
            store: ledgerStore,
            ownerActorID: configuration.ownerActorID
        )
        let resolvedHealthImporter: any IncrementalHealthImporting
        if let healthImporter {
            resolvedHealthImporter = healthImporter
        } else {
            resolvedHealthImporter = SystemHealthImportAdapter.make()
        }
        let healthImportCoordinator = HealthImportCoordinator(
            importer: resolvedHealthImporter,
            store: ledgerStore
        )
        let resolvedCalendarAdapter: any CalendarContextProviding
        if let calendarAdapter {
            resolvedCalendarAdapter = calendarAdapter
        } else {
            resolvedCalendarAdapter = SystemCalendarAdapter.make()
        }
        let calendarMirrorCoordinator = CalendarMirrorCoordinator(
            adapter: resolvedCalendarAdapter,
            store: ledgerStore
        )
        let resolvedLocationAdapter: any LocationContextProviding
        if let locationAdapter {
            resolvedLocationAdapter = locationAdapter
        } else {
            resolvedLocationAdapter = SystemLocationAdapter.make()
        }
        let locationContextCoordinator = LocationContextCoordinator(
            adapter: resolvedLocationAdapter,
            store: ledgerStore
        )
        let resolvedWeatherAdapter: any WeatherContextProviding
        if let weatherAdapter {
            resolvedWeatherAdapter = weatherAdapter
        } else {
            resolvedWeatherAdapter = SystemWeatherAdapter.make()
        }
        let weatherMirrorCoordinator = WeatherMirrorCoordinator(
            adapter: resolvedWeatherAdapter,
            store: ledgerStore
        )
        let foregroundContextRefreshCoordinator = ForegroundContextRefreshCoordinator(
            locationCoordinator: locationContextCoordinator,
            weatherCoordinator: weatherMirrorCoordinator
        )
        let lifeModelWorkshopService = try LifeModelWorkshopService(
            store: ledgerStore,
            deviceID: deviceID,
            ownerActorID: configuration.ownerActorID
        )
        let nowExperienceService = NowExperienceService(store: ledgerStore)
        return Self(
            applicationIdentifier: configuration.applicationIdentifier,
            credentialVault: vault,
            deviceID: deviceID,
            ledgerStore: ledgerStore,
            productTelemetryRecorder: productTelemetryRecorder,
            weeklyProductReviewService: weeklyProductReviewService,
            productTelemetryPrivacyService: productTelemetryPrivacyService,
            captureService: captureService,
            captureAttachmentStore: captureAttachmentStore,
            captureImportBuffer: captureImportBuffer,
            mediaCaptureService: mediaCaptureService,
            captureInterpretationService: captureInterpretationService,
            foodPresetService: foodPresetService,
            foodOccurrenceService: foodOccurrenceService,
            calendarMirrorCoordinator: calendarMirrorCoordinator,
            healthImportCoordinator: healthImportCoordinator,
            locationContextCoordinator: locationContextCoordinator,
            weatherMirrorCoordinator: weatherMirrorCoordinator,
            foregroundContextRefreshCoordinator: foregroundContextRefreshCoordinator,
            lifeModelWorkshopService: lifeModelWorkshopService,
            nowExperienceService: nowExperienceService,
            attachmentRecoveryState: await attachmentRecoveryState(
                store: captureAttachmentStore,
                ledgerStore: ledgerStore
            ),
            featureConfigurationTrust: configuration.featureConfigurationTrust
        )
    }

    private static func makeFeatureConfigurationVerifier(
        configuration: NativeLocalConfiguration,
        signatureVerifier: (any FeatureConfigurationSignatureVerifying)?
    ) throws -> FeatureConfigurationVerifier? {
        guard let trust = configuration.featureConfigurationTrust else {
            return nil
        }
        if let signatureVerifier {
            return try FeatureConfigurationVerifier(
                expectedKeyID: trust.keyID,
                publicKey: trust.publicKey,
                expectedEnvironment: trust.environment.featureConfigurationEnvironment,
                expectedAudience: configuration.applicationIdentifier,
                signatureVerifier: signatureVerifier
            )
        }
        #if canImport(CryptoKit)
        return try FeatureConfigurationVerifier(
            expectedKeyID: trust.keyID,
            publicKey: trust.publicKey,
            expectedEnvironment: trust.environment.featureConfigurationEnvironment,
            expectedAudience: configuration.applicationIdentifier,
            signatureVerifier: CryptoKitEd25519SignatureVerifier()
        )
        #else
        throw NativeApplicationConfigurationError.featureConfigurationVerificationUnavailable
        #endif
    }

    private static func attachmentRecoveryState(
        store: LocalCaptureAttachmentStore,
        ledgerStore: SQLiteLedgerStore
    ) async -> LocalCaptureAttachmentRecoveryState {
        do {
            let captures = try ledgerStore.projectedEntities(
                entityType: ManualCaptureService.entityType,
                limit: 500
            ).map {
                try SyncJSONCoding.makeDecoder().decode(
                    CaptureRecord.self,
                    from: $0.document
                )
            }
            let references = Set(captures.flatMap { capture in
                capture.attachments.map(\.objectRef)
            })
            return .completed(try await store.reconcile(
                referencedObjectReferences: references
            ))
        } catch {
            return .requiresRepair
        }
    }

    public func localDiagnostics(
        attachmentBacklog: Int? = nil
    ) async throws -> NativeSyncDiagnostics {
        if let attachmentBacklog, attachmentBacklog < 0 {
            throw DurableSyncCoordinatorError.invalidLocalState(
                "Attachment backlog cannot be negative."
            )
        }
        let resolvedAttachmentBacklog: Int
        if let attachmentBacklog {
            resolvedAttachmentBacklog = attachmentBacklog
        } else {
            switch attachmentRecoveryState {
            case let .completed(report):
                resolvedAttachmentBacklog = report.stagedAttachmentsAwaitingReview
                    + report.missingReferencedAttachments
            case .requiresRepair:
                resolvedAttachmentBacklog = 1
            }
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
            attachmentBacklog: resolvedAttachmentBacklog,
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
    public let featureConfigurationTransport: URLSessionFeatureConfigurationTransport?
    public let featureConfigurationRefreshCoordinator: FeatureConfigurationRefreshCoordinator?
    private let credentialVault: any CredentialVault

    public init(
        localServices: NativeLocalServices,
        configuration: NativeRemoteConfiguration
    ) throws {
        if let trust = localServices.featureConfigurationTrust,
           trust.environment != configuration.environment
        {
            throw NativeApplicationConfigurationError.invalidRemoteEnvironment
        }
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
        let featureConfigurationTransport: URLSessionFeatureConfigurationTransport?
        let featureConfigurationRefreshCoordinator: FeatureConfigurationRefreshCoordinator?
        if localServices.featureConfigurationTrust != nil {
            let transport = try URLSessionFeatureConfigurationTransport(
                configuration: configuration,
                tokenProvider: tokenSession
            )
            featureConfigurationTransport = transport
            featureConfigurationRefreshCoordinator = FeatureConfigurationRefreshCoordinator(
                cache: localServices.ledgerStore,
                transport: transport,
                audience: localServices.applicationIdentifier,
                assignmentSubject: localServices.deviceID.description
            )
        } else {
            featureConfigurationTransport = nil
            featureConfigurationRefreshCoordinator = nil
        }
        self.configuration = configuration
        self.authClient = authClient
        self.tokenSession = tokenSession
        self.syncTransport = syncTransport
        self.syncCoordinator = syncCoordinator
        self.lifeModelTransport = lifeModelTransport
        self.lifeModelAcceptanceCoordinator = lifeModelAcceptanceCoordinator
        self.featureConfigurationTransport = featureConfigurationTransport
        self.featureConfigurationRefreshCoordinator = featureConfigurationRefreshCoordinator
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

private extension NativeDeploymentEnvironment {
    var featureConfigurationEnvironment: FeatureConfigurationEnvironment {
        switch self {
        case .development:
            .development
        case .staging:
            .staging
        case .production:
            .production
        }
    }
}
