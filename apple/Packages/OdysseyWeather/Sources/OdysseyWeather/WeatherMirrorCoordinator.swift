import Foundation
import OdysseyIntegrations

public enum WeatherMirrorCoordinatorError: Error, Equatable, Sendable {
    case unexpectedSnapshotPlace
    case invalidStoredDocument
    case invalidStoredCursor
    case invalidClock
}

public struct WeatherMirrorRunReceipt: Hashable, Sendable {
    public let placeIdentifier: String
    public let outcome: WeatherMirrorOutcome
    public let attemptedAt: Date
    public let insertedCount: Int
    public let updatedCount: Int
    public let duplicateCount: Int
    public let rejectedCount: Int
    public let cursorAdvanced: Bool
    public let rateLimitState: IntegrationRateLimitState

    public init(
        placeIdentifier: String,
        outcome: WeatherMirrorOutcome,
        attemptedAt: Date,
        insertedCount: Int,
        updatedCount: Int,
        duplicateCount: Int,
        rejectedCount: Int,
        cursorAdvanced: Bool,
        rateLimitState: IntegrationRateLimitState
    ) {
        self.placeIdentifier = placeIdentifier
        self.outcome = outcome
        self.attemptedAt = attemptedAt
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.duplicateCount = duplicateCount
        self.rejectedCount = rejectedCount
        self.cursorAdvanced = cursorAdvanced
        self.rateLimitState = rateLimitState
    }
}

public struct WeatherLocalSnapshot: Sendable {
    public let context: WeatherContextSnapshot?
    public let lastAttemptAt: Date?
    public let lastSuccessfulRefreshAt: Date?
    public let lastOutcome: WeatherMirrorOutcome?
    public let rateLimitState: IntegrationRateLimitState
    public let rejectedRecordCount: Int

    public init(
        context: WeatherContextSnapshot?,
        lastAttemptAt: Date?,
        lastSuccessfulRefreshAt: Date?,
        lastOutcome: WeatherMirrorOutcome?,
        rateLimitState: IntegrationRateLimitState,
        rejectedRecordCount: Int
    ) {
        self.context = context
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        self.lastOutcome = lastOutcome
        self.rateLimitState = rateLimitState
        self.rejectedRecordCount = rejectedRecordCount
    }
}

public struct WeatherMirrorOverview: Sendable {
    public let observedAt: Date
    public let capability: WeatherMirrorCapability
    public let permission: IntegrationPermissionState
    public let cachedPlace: WeatherPlaceContext?
    public let cacheIsFresh: Bool
    public let lastAttemptAt: Date?
    public let lastSuccessfulRefreshAt: Date?
    public let newestSourceTimestamp: Date?
    public let expiresAt: Date?
    public let lastOutcome: WeatherMirrorOutcome?
    public let rateLimitState: IntegrationRateLimitState
    public let rejectedRecordCount: Int
    public let attribution: WeatherProviderAttribution?

    public init(
        observedAt: Date,
        capability: WeatherMirrorCapability,
        permission: IntegrationPermissionState,
        cachedPlace: WeatherPlaceContext?,
        cacheIsFresh: Bool,
        lastAttemptAt: Date?,
        lastSuccessfulRefreshAt: Date?,
        newestSourceTimestamp: Date?,
        expiresAt: Date?,
        lastOutcome: WeatherMirrorOutcome?,
        rateLimitState: IntegrationRateLimitState,
        rejectedRecordCount: Int,
        attribution: WeatherProviderAttribution?
    ) throws {
        guard observedAt.timeIntervalSinceReferenceDate.isFinite,
              Self.validDate(lastAttemptAt),
              Self.validDate(lastSuccessfulRefreshAt),
              Self.validDate(newestSourceTimestamp),
              Self.validDate(expiresAt),
              (0 ... 1_000_000).contains(rejectedRecordCount)
        else {
            throw WeatherMirrorCoordinatorError.invalidClock
        }
        self.observedAt = observedAt
        self.capability = capability
        self.permission = permission
        self.cachedPlace = cachedPlace
        self.cacheIsFresh = cacheIsFresh
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        self.newestSourceTimestamp = newestSourceTimestamp
        self.expiresAt = expiresAt
        self.lastOutcome = lastOutcome
        self.rateLimitState = rateLimitState
        self.rejectedRecordCount = rejectedRecordCount
        self.attribution = attribution
    }

    private static func validDate(_ date: Date?) -> Bool {
        date?.timeIntervalSinceReferenceDate.isFinite ?? true
    }
}

public actor WeatherMirrorCoordinator {
    public static let stream = "forecast"

    private static let currentRecordIdentifier = "current"

    private let adapter: any WeatherContextProviding
    private let store: any IntegrationLocalRecordStoring
    private let clock: @Sendable () -> Date

    public init(
        adapter: any WeatherContextProviding,
        store: any IntegrationLocalRecordStoring,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.adapter = adapter
        self.store = store
        self.clock = clock
    }

    public func capability() async -> WeatherMirrorCapability {
        await adapter.capability()
    }

    public func permissionState() async -> IntegrationPermissionState {
        await adapter.permissionState()
    }

    public func refresh(
        for query: WeatherQueryLocation
    ) async throws -> WeatherMirrorRunReceipt {
        let stored = try await loadStoredState()
        let attemptedAt = clock()
        guard attemptedAt.timeIntervalSinceReferenceDate.isFinite,
              stored.cursor.map({ attemptedAt >= $0.lastAttemptAt }) ?? true
        else {
            throw WeatherMirrorCoordinatorError.invalidClock
        }
        let result = try await adapter.weather(for: query)
        let successfulAt: Date?
        let records: [IntegrationLocalRecord]
        if let snapshot = result.snapshot {
            guard snapshot.place == query.place else {
                throw WeatherMirrorCoordinatorError.unexpectedSnapshotPlace
            }
            guard snapshot.fetchedAt <= attemptedAt.addingTimeInterval(5 * 60),
                  snapshot.expiresAt > attemptedAt
            else {
                throw WeatherMirrorCoordinatorError.invalidClock
            }
            successfulAt = attemptedAt
            records = [try IntegrationLocalRecord(
                connector: .weather,
                stream: Self.stream,
                externalIdentifier: Self.currentRecordIdentifier,
                sourceTimestamp: snapshot.sourceAsOf,
                document: try Self.encode(WeatherLocalDocument(
                    schemaVersion: 1,
                    context: snapshot
                ))
            )]
        } else {
            successfulAt = stored.cursor?.lastSuccessfulRefreshAt
            records = []
        }
        let cursor = WeatherMirrorCursor(
            schemaVersion: 1,
            lastAttemptAt: attemptedAt,
            lastSuccessfulRefreshAt: successfulAt,
            lastOutcome: result.outcome,
            rateLimitState: result.rateLimitState,
            rejectedRecordCount: result.rejectedRecordCount
        )
        let cursorData = try Self.encode(cursor)
        let receipt = try await store.applyIntegrationPage(IntegrationLocalPage(
            connector: .weather,
            stream: Self.stream,
            records: records,
            deletedExternalIdentifiers: [],
            nextCursor: cursorData,
            appliedAt: attemptedAt,
            allowsUpdates: true
        ))
        return WeatherMirrorRunReceipt(
            placeIdentifier: query.place.identifier,
            outcome: result.outcome,
            attemptedAt: attemptedAt,
            insertedCount: receipt.insertedCount,
            updatedCount: receipt.updatedCount,
            duplicateCount: receipt.duplicateCount,
            rejectedCount: result.rejectedRecordCount + receipt.rejectedCount,
            cursorAdvanced: stored.cursorData != cursorData,
            rateLimitState: result.rateLimitState
        )
    }

    public func localSnapshot() async throws -> WeatherLocalSnapshot {
        let stored = try await loadStoredState()
        return WeatherLocalSnapshot(
            context: stored.context,
            lastAttemptAt: stored.cursor?.lastAttemptAt,
            lastSuccessfulRefreshAt: stored.cursor?.lastSuccessfulRefreshAt,
            lastOutcome: stored.cursor?.lastOutcome,
            rateLimitState: stored.cursor?.rateLimitState ?? .notApplicable,
            rejectedRecordCount: stored.cursor?.rejectedRecordCount ?? 0
        )
    }

    public func overview(
        observedAt: Date = Date()
    ) async throws -> WeatherMirrorOverview {
        let capability = await adapter.capability()
        let permission: IntegrationPermissionState
        if capability.availability == .available {
            permission = await adapter.permissionState()
        } else {
            permission = .unavailable
        }
        let snapshot = try await localSnapshot()
        return try WeatherMirrorOverview(
            observedAt: observedAt,
            capability: capability,
            permission: permission,
            cachedPlace: snapshot.context?.place,
            cacheIsFresh: snapshot.context.map { $0.expiresAt > observedAt } ?? false,
            lastAttemptAt: snapshot.lastAttemptAt,
            lastSuccessfulRefreshAt: snapshot.lastSuccessfulRefreshAt,
            newestSourceTimestamp: snapshot.context?.sourceAsOf,
            expiresAt: snapshot.context?.expiresAt,
            lastOutcome: snapshot.lastOutcome,
            rateLimitState: snapshot.rateLimitState,
            rejectedRecordCount: snapshot.rejectedRecordCount,
            attribution: snapshot.context?.attribution
        )
    }

    public func revokeLocalWeatherData() async throws -> Int {
        try await store.clearIntegrationData(connector: .weather)
    }

    private func loadStoredState() async throws -> StoredWeatherState {
        let stored = try await store.integrationSnapshot(
            connector: .weather,
            stream: Self.stream
        )
        guard stored.records.count <= 1 else {
            throw WeatherMirrorCoordinatorError.invalidStoredDocument
        }
        let context = try stored.records.first.map(Self.decodeRecord)
        let cursor: WeatherMirrorCursor?
        if let cursorData = stored.cursor {
            do {
                cursor = try Self.decode(WeatherMirrorCursor.self, from: cursorData)
            } catch {
                throw WeatherMirrorCoordinatorError.invalidStoredCursor
            }
            guard let cursor,
                  cursor.schemaVersion == 1,
                  cursor.lastAttemptAt.timeIntervalSinceReferenceDate.isFinite,
                  cursor.lastSuccessfulRefreshAt?.timeIntervalSinceReferenceDate.isFinite
                    ?? true,
                  cursor.lastSuccessfulRefreshAt.map({ $0 <= cursor.lastAttemptAt })
                    ?? true,
                  (0 ... 1_000_000).contains(cursor.rejectedRecordCount),
                  Self.valid(cursor: cursor, hasContext: context != nil)
            else {
                throw WeatherMirrorCoordinatorError.invalidStoredCursor
            }
        } else {
            cursor = nil
            guard context == nil else {
                throw WeatherMirrorCoordinatorError.invalidStoredCursor
            }
        }
        return StoredWeatherState(
            context: context,
            cursor: cursor,
            cursorData: stored.cursor
        )
    }

    private static func valid(
        cursor: WeatherMirrorCursor,
        hasContext: Bool
    ) -> Bool {
        guard hasContext == (cursor.lastSuccessfulRefreshAt != nil) else {
            return false
        }
        switch cursor.lastOutcome {
        case .fetched:
            return hasContext
                && cursor.lastSuccessfulRefreshAt == cursor.lastAttemptAt
                && cursor.rateLimitState != .limited
        case .rateLimited:
            return cursor.rateLimitState == .limited
        case .unavailable:
            return cursor.rateLimitState != .limited
        }
    }

    private static func decodeRecord(
        _ record: IntegrationLocalRecord
    ) throws -> WeatherContextSnapshot {
        let document: WeatherLocalDocument
        do {
            document = try decode(WeatherLocalDocument.self, from: record.document)
        } catch {
            throw WeatherMirrorCoordinatorError.invalidStoredDocument
        }
        guard document.schemaVersion == 1,
              record.connector == .weather,
              record.stream == Self.stream,
              record.externalIdentifier == Self.currentRecordIdentifier,
              record.sourceTimestamp == document.context.sourceAsOf
        else {
            throw WeatherMirrorCoordinatorError.invalidStoredDocument
        }
        return document.context
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

private struct WeatherLocalDocument: Codable {
    let schemaVersion: Int
    let context: WeatherContextSnapshot
}

private struct WeatherMirrorCursor: Codable {
    let schemaVersion: Int
    let lastAttemptAt: Date
    let lastSuccessfulRefreshAt: Date?
    let lastOutcome: WeatherMirrorOutcome
    let rateLimitState: IntegrationRateLimitState
    let rejectedRecordCount: Int
}

private struct StoredWeatherState {
    let context: WeatherContextSnapshot?
    let cursor: WeatherMirrorCursor?
    let cursorData: Data?
}
