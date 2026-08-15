import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public enum LifeModelAcceptanceCoordinatorError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidLocalState(String)
    case invalidServerReceipt(String)
    case invalidRemoteHistory(String)
}

extension LifeModelAcceptanceCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message),
             let .invalidLocalState(message),
             let .invalidServerReceipt(message),
             let .invalidRemoteHistory(message):
            message
        }
    }
}

public struct LifeModelAcceptanceCoordinatorConfiguration: Sendable {
    public let deliveryBatchSize: Int
    public let historyLimit: Int
    public let retryBaseDelay: TimeInterval
    public let retryMaximumDelay: TimeInterval

    public init(
        deliveryBatchSize: Int = 50,
        historyLimit: Int = 200,
        retryBaseDelay: TimeInterval = 30,
        retryMaximumDelay: TimeInterval = 60 * 60
    ) {
        self.deliveryBatchSize = deliveryBatchSize
        self.historyLimit = historyLimit
        self.retryBaseDelay = retryBaseDelay
        self.retryMaximumDelay = retryMaximumDelay
    }
}

public struct LifeModelAcceptanceRunReport: Codable, Hashable, Sendable {
    public let attemptedCount: Int
    public let acceptedCount: Int
    public let conflictCount: Int
    public let rejectedCount: Int
    public let retryScheduledCount: Int
    public let cachedHistoryVersionCount: Int
    public let failedHistoryKinds: [LifeModelKind]
    public let orientationRefreshFailureCount: Int
    public let completedAt: Date

    public init(
        attemptedCount: Int,
        acceptedCount: Int,
        conflictCount: Int,
        rejectedCount: Int,
        retryScheduledCount: Int,
        cachedHistoryVersionCount: Int,
        failedHistoryKinds: [LifeModelKind],
        orientationRefreshFailureCount: Int,
        completedAt: Date
    ) {
        self.attemptedCount = attemptedCount
        self.acceptedCount = acceptedCount
        self.conflictCount = conflictCount
        self.rejectedCount = rejectedCount
        self.retryScheduledCount = retryScheduledCount
        self.cachedHistoryVersionCount = cachedHistoryVersionCount
        self.failedHistoryKinds = failedHistoryKinds
        self.orientationRefreshFailureCount = orientationRefreshFailureCount
        self.completedAt = completedAt
    }
}

private enum LifeModelDeliveryDisposition {
    case conflict(orientationRefreshFailed: Bool)
    case rejected
    case retryScheduled
}

public actor LifeModelAcceptanceCoordinator {
    private static let retryMessage = "Delivery could not be completed and will retry."
    private static let conflictMessage =
        "The accepted current version changed and requires owner review."
    private static let rejectedMessage =
        "The server or transport rejected this acceptance command."

    private let store: any LifeModelAcceptanceStore
    private let transport: any LifeModelTransport
    private let configuration: LifeModelAcceptanceCoordinatorConfiguration
    private let clock: @Sendable () -> Date
    private var activeRun: Task<LifeModelAcceptanceRunReport, Error>?

    public init(
        store: any LifeModelAcceptanceStore,
        transport: any LifeModelTransport,
        configuration: LifeModelAcceptanceCoordinatorConfiguration = .init(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard (1 ... 200).contains(configuration.deliveryBatchSize) else {
            throw LifeModelAcceptanceCoordinatorError.invalidConfiguration(
                "Life-model delivery batch size must be between 1 and 200."
            )
        }
        guard (1 ... 200).contains(configuration.historyLimit) else {
            throw LifeModelAcceptanceCoordinatorError.invalidConfiguration(
                "Life-model history limits must be between 1 and 200."
            )
        }
        guard configuration.retryBaseDelay.isFinite,
              configuration.retryMaximumDelay.isFinite,
              configuration.retryBaseDelay > 0,
              configuration.retryMaximumDelay >= configuration.retryBaseDelay
        else {
            throw LifeModelAcceptanceCoordinatorError.invalidConfiguration(
                "Retry delays must be finite, positive, and monotonically bounded."
            )
        }
        self.store = store
        self.transport = transport
        self.configuration = configuration
        self.clock = clock
    }

    public func synchronize() async throws -> LifeModelAcceptanceRunReport {
        if let activeRun {
            return try await activeRun.value
        }
        let task = Task { try await performRun() }
        activeRun = task
        defer { activeRun = nil }
        return try await task.value
    }

    public func cancelSynchronization() {
        activeRun?.cancel()
    }

    public func refreshRemoteHistory() async throws -> Int {
        let refreshedAt = try validClockInstant(context: "history refresh")
        var cachedCount = 0
        for kind in LifeModelKind.allCases {
            try Task.checkCancellation()
            let response = try await transport.history(
                kind: kind,
                limit: configuration.historyLimit
            )
            cachedCount += try cacheHistory(
                response,
                requestedKind: kind,
                cachedAt: refreshedAt
            )
        }
        return cachedCount
    }

    private func performRun() async throws -> LifeModelAcceptanceRunReport {
        let startedAt = try validClockInstant(context: "delivery start")
        let pending = try store.pendingLifeModelAcceptances(
            limit: configuration.deliveryBatchSize,
            readyAt: startedAt
        )
        try validatePendingQueue(pending)

        var acceptedCount = 0
        var conflictCount = 0
        var rejectedCount = 0
        var retryScheduledCount = 0
        var orientationRefreshFailureCount = 0
        for queued in pending {
            try Task.checkCancellation()
            do {
                let receipt = try await transport.submit(queued.command)
                let completedAt = try validClockInstant(context: "accepted delivery")
                let version = try validateAndCacheableVersion(
                    receipt,
                    queued: queued,
                    cachedAt: completedAt
                )
                try store.recordLifeModelAccepted(
                    eventID: queued.command.eventID,
                    version: version,
                    completedAt: completedAt
                )
                acceptedCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LifeModelTransportError {
                let disposition = try await handleTransportError(error, queued: queued)
                switch disposition {
                case let .conflict(orientationRefreshFailed):
                    conflictCount += 1
                    if orientationRefreshFailed {
                        orientationRefreshFailureCount += 1
                    }
                case .rejected:
                    rejectedCount += 1
                case .retryScheduled:
                    retryScheduledCount += 1
                }
            }
        }

        let historyResult = try await refreshHistoryBestEffort()
        let completedAt = try validClockInstant(context: "delivery completion")
        return LifeModelAcceptanceRunReport(
            attemptedCount: pending.count,
            acceptedCount: acceptedCount,
            conflictCount: conflictCount,
            rejectedCount: rejectedCount,
            retryScheduledCount: retryScheduledCount,
            cachedHistoryVersionCount: historyResult.cachedCount,
            failedHistoryKinds: historyResult.failedKinds,
            orientationRefreshFailureCount: orientationRefreshFailureCount,
            completedAt: completedAt
        )
    }

    private func handleTransportError(
        _ error: LifeModelTransportError,
        queued: StoredLifeModelAcceptance
    ) async throws -> LifeModelDeliveryDisposition {
        if case let .api(statusCode, body) = error, statusCode == 409 {
            return try await recordConflict(errorBody: body, queued: queued)
        }
        let occurredAt = try validClockInstant(context: "delivery failure")
        if error.isRetryable {
            let nextAttemptAt = occurredAt.addingTimeInterval(
                retryDelay(previousAttemptCount: queued.attemptCount)
            )
            guard nextAttemptAt.timeIntervalSinceReferenceDate.isFinite else {
                throw LifeModelAcceptanceCoordinatorError.invalidLocalState(
                    "The calculated life-model retry instant is not finite."
                )
            }
            try store.recordLifeModelRetry(
                eventID: queued.command.eventID,
                errorCode: safeErrorCode(for: error),
                message: Self.retryMessage,
                nextAttemptAt: nextAttemptAt,
                updatedAt: occurredAt
            )
            return .retryScheduled
        }
        try store.recordLifeModelRejected(
            eventID: queued.command.eventID,
            errorCode: safeErrorCode(for: error),
            message: Self.rejectedMessage,
            completedAt: occurredAt
        )
        return .rejected
    }

    private func recordConflict(
        errorBody: APIErrorBody,
        queued: StoredLifeModelAcceptance
    ) async throws -> LifeModelDeliveryDisposition {
        var orientation: CurrentOrientationResponse?
        var orientationRefreshFailed = false
        do {
            orientation = try await transport.orientation(asOf: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            orientationRefreshFailed = true
        }
        let completedAt = try validClockInstant(context: "conflict delivery")
        let actualCurrentVersionID: UUIDv7?
        if let orientation {
            do {
                try validateOrientation(orientation)
                actualCurrentVersionID = orientation.version(for: queued.command.kind)?.versionID
            } catch {
                orientationRefreshFailed = true
                actualCurrentVersionID = nil
            }
        } else {
            actualCurrentVersionID = nil
        }
        try store.recordLifeModelConflict(
            eventID: queued.command.eventID,
            errorCode: safeAPICode(errorBody.code, fallback: "LIFE_MODEL_CONFLICT"),
            message: Self.conflictMessage,
            actualCurrentVersionID: actualCurrentVersionID,
            completedAt: completedAt
        )
        if let orientation, !orientationRefreshFailed {
            for version in orientation.versions {
                try store.cacheLifeModelVersion(
                    try cacheableRemoteVersion(
                        version,
                        expectedKind: version.kind,
                        policyVersion: orientation.policyVersion,
                        cachedAt: completedAt
                    )
                )
            }
        }
        return .conflict(orientationRefreshFailed: orientationRefreshFailed)
    }

    private func refreshHistoryBestEffort() async throws -> (
        cachedCount: Int,
        failedKinds: [LifeModelKind]
    ) {
        let refreshedAt = try validClockInstant(context: "history refresh")
        var cachedCount = 0
        var failedKinds: [LifeModelKind] = []
        for kind in LifeModelKind.allCases {
            try Task.checkCancellation()
            let response: LifeModelHistoryResponse
            do {
                response = try await transport.history(
                    kind: kind,
                    limit: configuration.historyLimit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch is LifeModelTransportError {
                failedKinds.append(kind)
                continue
            }
            cachedCount += try cacheHistory(
                response,
                requestedKind: kind,
                cachedAt: refreshedAt
            )
        }
        return (cachedCount, failedKinds)
    }

    private func cacheHistory(
        _ response: LifeModelHistoryResponse,
        requestedKind: LifeModelKind,
        cachedAt: Date
    ) throws -> Int {
        guard response.kind == requestedKind,
              Self.isBoundedIdentifier(response.policyVersion, maximum: 200),
              response.versions.count <= configuration.historyLimit,
              Set(response.versions.map(\.versionID)).count == response.versions.count
        else {
            throw LifeModelAcceptanceCoordinatorError.invalidRemoteHistory(
                "The remote life-model history does not match the requested kind or limits."
            )
        }
        var previousSequence: Int?
        for version in response.versions {
            if let previousSequence, version.acceptanceSequence >= previousSequence {
                throw LifeModelAcceptanceCoordinatorError.invalidRemoteHistory(
                    "Remote life-model history is not in descending acceptance order."
                )
            }
            let cached = try cacheableRemoteVersion(
                version,
                expectedKind: requestedKind,
                policyVersion: response.policyVersion,
                cachedAt: cachedAt
            )
            try store.cacheLifeModelVersion(cached)
            previousSequence = version.acceptanceSequence
        }
        return response.versions.count
    }

    private func validateAndCacheableVersion(
        _ receipt: LifeModelRevisionReceipt,
        queued: StoredLifeModelAcceptance,
        cachedAt: Date
    ) throws -> CachedLifeModelVersion {
        let command = queued.command
        let version = receipt.version
        guard receipt.eventID == command.eventID,
              receipt.eventID == version.eventID,
              receipt.ledgerSequence == version.ledgerSequence,
              version.kind == command.kind,
              version.versionID == command.versionID,
              version.logicalID == command.logicalID,
              version.versionNumber == command.versionNumber,
              version.supersedesVersionID == command.expectedCurrentVersionID,
              version.acceptanceMethod == command.acceptanceMethod,
              version.acceptedAt == command.acceptedAt,
              Self.isBoundedIdentifier(receipt.policyVersion, maximum: 200),
              receipt.warnings.count <= 100
        else {
            throw LifeModelAcceptanceCoordinatorError.invalidServerReceipt(
                "The server receipt does not match the immutable queued acceptance command."
            )
        }
        let localDocument: [String: JSONValue]
        do {
            localDocument = try SyncJSONCoding.makeDecoder().decode(
                [String: JSONValue].self,
                from: command.document
            )
        } catch {
            throw LifeModelAcceptanceCoordinatorError.invalidLocalState(
                "A queued life-model document is not a JSON object."
            )
        }
        guard version.document == localDocument else {
            throw LifeModelAcceptanceCoordinatorError.invalidServerReceipt(
                "The server receipt document does not match the queued acceptance document."
            )
        }
        return try cacheableRemoteVersion(
            version,
            expectedKind: command.kind,
            policyVersion: receipt.policyVersion,
            cachedAt: cachedAt
        )
    }

    private func cacheableRemoteVersion(
        _ version: LifeModelVersionEnvelope,
        expectedKind: LifeModelKind,
        policyVersion: String,
        cachedAt: Date
    ) throws -> CachedLifeModelVersion {
        guard version.kind == expectedKind,
              version.acceptedAt.timeIntervalSinceReferenceDate.isFinite,
              Self.isBoundedIdentifier(policyVersion, maximum: 200),
              version.status.map({ Self.isBoundedIdentifier($0, maximum: 100) }) ?? true
        else {
            throw LifeModelAcceptanceCoordinatorError.invalidRemoteHistory(
                "A remote life-model version contains invalid kind or provenance metadata."
            )
        }
        return try version.cached(policyVersion: policyVersion, cachedAt: cachedAt)
    }

    private func validateOrientation(_ response: CurrentOrientationResponse) throws {
        guard response.asOf.timeIntervalSinceReferenceDate.isFinite,
              Self.isBoundedIdentifier(response.policyVersion, maximum: 200),
              Set(response.versions.map(\.kind)).count == response.versions.count
        else {
            throw LifeModelAcceptanceCoordinatorError.invalidRemoteHistory(
                "The current orientation response contains invalid provenance or duplicate kinds."
            )
        }
        for version in response.versions {
            _ = try cacheableRemoteVersion(
                version,
                expectedKind: version.kind,
                policyVersion: response.policyVersion,
                cachedAt: response.asOf
            )
        }
    }

    private func validatePendingQueue(
        _ pending: [StoredLifeModelAcceptance]
    ) throws {
        guard Set(pending.map(\.command.eventID)).count == pending.count,
              Set(pending.map(\.command.versionID)).count == pending.count,
              pending.allSatisfy({
                  $0.deliveryStatus == .pending || $0.deliveryStatus == .retry
              })
        else {
            throw LifeModelAcceptanceCoordinatorError.invalidLocalState(
                "The local life-model delivery queue contains duplicate or terminal commands."
            )
        }
    }

    private func validClockInstant(context: String) throws -> Date {
        let instant = clock()
        guard instant.timeIntervalSinceReferenceDate.isFinite else {
            throw LifeModelAcceptanceCoordinatorError.invalidLocalState(
                "The local clock returned a non-finite \(context) instant."
            )
        }
        return instant
    }

    private func retryDelay(previousAttemptCount: Int) -> TimeInterval {
        let exponent = min(max(previousAttemptCount, 0), 20)
        return min(
            configuration.retryMaximumDelay,
            configuration.retryBaseDelay * pow(2, Double(exponent))
        )
    }

    private func safeErrorCode(for error: LifeModelTransportError) -> String {
        switch error {
        case let .api(statusCode, body):
            safeAPICode(body.code, fallback: "HTTP_\(statusCode)")
        case let .network(code):
            "NETWORK_\(code)"
        case .nonHTTPResponse:
            "NON_HTTP_RESPONSE"
        case .redirected:
            "CROSS_ORIGIN_REDIRECT"
        case .responseTooLarge:
            "RESPONSE_TOO_LARGE"
        case .invalidRequest:
            "INVALID_LOCAL_REQUEST"
        case let .invalidResponse(statusCode, _):
            "INVALID_HTTP_\(statusCode)_RESPONSE"
        }
    }

    private func safeAPICode(_ code: String, fallback: String) -> String {
        guard Self.isBoundedIdentifier(code, maximum: 200),
              code.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: "_.-"))
                      .contains($0)
              })
        else {
            return fallback
        }
        return code
    }

    private static func isBoundedIdentifier(
        _ value: String,
        maximum: Int
    ) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
