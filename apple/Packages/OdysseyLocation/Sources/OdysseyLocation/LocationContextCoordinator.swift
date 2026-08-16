import Foundation
import OdysseyIntegrations

public enum LocationContextCoordinatorError: Error, Equatable, Sendable {
    case invalidStoredDocument
    case invalidStoredCursor
    case invalidClock
}

public struct LocationContextRunReceipt: Hashable, Sendable {
    public let outcome: BroadLocationOutcome
    public let attemptedAt: Date
    public let transientFix: TransientLocationFix?
    public let insertedCount: Int
    public let updatedCount: Int
    public let duplicateCount: Int
    public let rejectedCount: Int
    public let cursorAdvanced: Bool

    public init(
        outcome: BroadLocationOutcome,
        attemptedAt: Date,
        transientFix: TransientLocationFix?,
        insertedCount: Int,
        updatedCount: Int,
        duplicateCount: Int,
        rejectedCount: Int,
        cursorAdvanced: Bool
    ) {
        self.outcome = outcome
        self.attemptedAt = attemptedAt
        self.transientFix = transientFix
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.duplicateCount = duplicateCount
        self.rejectedCount = rejectedCount
        self.cursorAdvanced = cursorAdvanced
    }
}

public struct LocationLocalSnapshot: Sendable {
    public let context: BroadLocationContext?
    public let lastAttemptAt: Date?
    public let lastSuccessfulRefreshAt: Date?
    public let lastOutcome: BroadLocationOutcome?
    public let rejectedRecordCount: Int

    public init(
        context: BroadLocationContext?,
        lastAttemptAt: Date?,
        lastSuccessfulRefreshAt: Date?,
        lastOutcome: BroadLocationOutcome?,
        rejectedRecordCount: Int
    ) {
        self.context = context
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        self.lastOutcome = lastOutcome
        self.rejectedRecordCount = rejectedRecordCount
    }
}

public struct LocationContextOverview: Sendable {
    public let observedAt: Date
    public let capability: LocationContextCapability
    public let permission: IntegrationPermissionState
    public let cachedPlace: BroadLocationContext?
    public let cacheIsFresh: Bool
    public let lastAttemptAt: Date?
    public let lastSuccessfulRefreshAt: Date?
    public let lastOutcome: BroadLocationOutcome?
    public let rejectedRecordCount: Int

    public init(
        observedAt: Date,
        capability: LocationContextCapability,
        permission: IntegrationPermissionState,
        cachedPlace: BroadLocationContext?,
        cacheIsFresh: Bool,
        lastAttemptAt: Date?,
        lastSuccessfulRefreshAt: Date?,
        lastOutcome: BroadLocationOutcome?,
        rejectedRecordCount: Int
    ) throws {
        guard observedAt.timeIntervalSinceReferenceDate.isFinite,
              Self.validDate(lastAttemptAt),
              Self.validDate(lastSuccessfulRefreshAt),
              (0 ... 1_000_000).contains(rejectedRecordCount)
        else {
            throw LocationContextCoordinatorError.invalidClock
        }
        self.observedAt = observedAt
        self.capability = capability
        self.permission = permission
        self.cachedPlace = cachedPlace
        self.cacheIsFresh = cacheIsFresh
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        self.lastOutcome = lastOutcome
        self.rejectedRecordCount = rejectedRecordCount
    }

    private static func validDate(_ date: Date?) -> Bool {
        date?.timeIntervalSinceReferenceDate.isFinite ?? true
    }
}

public actor LocationContextCoordinator {
    public static let stream = "broad_place"

    private static let currentRecordIdentifier = "current"

    private let adapter: any LocationContextProviding
    private let store: any IntegrationLocalRecordStoring
    private let clock: @Sendable () -> Date

    public init(
        adapter: any LocationContextProviding,
        store: any IntegrationLocalRecordStoring,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.adapter = adapter
        self.store = store
        self.clock = clock
    }

    public func capability() async -> LocationContextCapability {
        await adapter.capability()
    }

    public func authorizationState() async -> IntegrationPermissionState {
        await adapter.authorizationState()
    }

    public func requestWhenInUseAuthorization() async -> IntegrationPermissionState {
        await adapter.requestWhenInUseAuthorization()
    }

    public func refresh() async throws -> LocationContextRunReceipt {
        let stored = try await loadStoredState()
        let attemptedAt = clock()
        guard attemptedAt.timeIntervalSinceReferenceDate.isFinite,
              stored.cursor.map({ attemptedAt >= $0.lastAttemptAt }) ?? true
        else {
            throw LocationContextCoordinatorError.invalidClock
        }
        let result = try await adapter.currentBroadLocation()
        let records: [IntegrationLocalRecord]
        let successfulAt: Date?
        if let fix = result.fix {
            guard fix.context.capturedAt <= attemptedAt.addingTimeInterval(5 * 60),
                  fix.context.expiresAt > attemptedAt
            else {
                throw LocationContextCoordinatorError.invalidClock
            }
            records = [try IntegrationLocalRecord(
                connector: .location,
                stream: Self.stream,
                externalIdentifier: Self.currentRecordIdentifier,
                sourceTimestamp: fix.context.capturedAt,
                document: try Self.encode(LocationLocalDocument(
                    schemaVersion: 1,
                    context: fix.context
                ))
            )]
            successfulAt = attemptedAt
        } else {
            records = []
            successfulAt = stored.cursor?.lastSuccessfulRefreshAt
        }
        let cursor = LocationContextCursor(
            schemaVersion: 1,
            lastAttemptAt: attemptedAt,
            lastSuccessfulRefreshAt: successfulAt,
            lastOutcome: result.outcome,
            rejectedRecordCount: result.rejectedRecordCount
        )
        let cursorData = try Self.encode(cursor)
        let receipt = try await store.applyIntegrationPage(IntegrationLocalPage(
            connector: .location,
            stream: Self.stream,
            records: records,
            deletedExternalIdentifiers: [],
            nextCursor: cursorData,
            appliedAt: attemptedAt,
            allowsUpdates: true
        ))
        return LocationContextRunReceipt(
            outcome: result.outcome,
            attemptedAt: attemptedAt,
            transientFix: result.fix,
            insertedCount: receipt.insertedCount,
            updatedCount: receipt.updatedCount,
            duplicateCount: receipt.duplicateCount,
            rejectedCount: result.rejectedRecordCount + receipt.rejectedCount,
            cursorAdvanced: stored.cursorData != cursorData
        )
    }

    public func localSnapshot() async throws -> LocationLocalSnapshot {
        let stored = try await loadStoredState()
        return LocationLocalSnapshot(
            context: stored.context,
            lastAttemptAt: stored.cursor?.lastAttemptAt,
            lastSuccessfulRefreshAt: stored.cursor?.lastSuccessfulRefreshAt,
            lastOutcome: stored.cursor?.lastOutcome,
            rejectedRecordCount: stored.cursor?.rejectedRecordCount ?? 0
        )
    }

    public func overview(
        observedAt: Date = Date()
    ) async throws -> LocationContextOverview {
        let capability = await adapter.capability()
        let permission: IntegrationPermissionState
        if capability.availability == .available,
           capability.supportsForegroundBroadPlace
        {
            permission = await adapter.authorizationState()
        } else {
            permission = .unavailable
        }
        let snapshot = try await localSnapshot()
        return try LocationContextOverview(
            observedAt: observedAt,
            capability: capability,
            permission: permission,
            cachedPlace: snapshot.context,
            cacheIsFresh: snapshot.context.map { $0.expiresAt > observedAt } ?? false,
            lastAttemptAt: snapshot.lastAttemptAt,
            lastSuccessfulRefreshAt: snapshot.lastSuccessfulRefreshAt,
            lastOutcome: snapshot.lastOutcome,
            rejectedRecordCount: snapshot.rejectedRecordCount
        )
    }

    public func revokeLocalLocationData() async throws -> Int {
        await adapter.stopMonitoring()
        return try await store.clearIntegrationData(connector: .location)
    }

    private func loadStoredState() async throws -> StoredLocationState {
        let stored = try await store.integrationSnapshot(
            connector: .location,
            stream: Self.stream
        )
        guard stored.records.count <= 1 else {
            throw LocationContextCoordinatorError.invalidStoredDocument
        }
        let context = try stored.records.first.map(Self.decodeRecord)
        let cursor: LocationContextCursor?
        if let cursorData = stored.cursor {
            do {
                cursor = try Self.decode(LocationContextCursor.self, from: cursorData)
            } catch {
                throw LocationContextCoordinatorError.invalidStoredCursor
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
                throw LocationContextCoordinatorError.invalidStoredCursor
            }
        } else {
            cursor = nil
            guard context == nil else {
                throw LocationContextCoordinatorError.invalidStoredCursor
            }
        }
        return StoredLocationState(
            context: context,
            cursor: cursor,
            cursorData: stored.cursor
        )
    }

    private static func valid(
        cursor: LocationContextCursor,
        hasContext: Bool
    ) -> Bool {
        guard hasContext == (cursor.lastSuccessfulRefreshAt != nil) else {
            return false
        }
        if cursor.lastOutcome == .acquired {
            return hasContext
                && cursor.lastSuccessfulRefreshAt == cursor.lastAttemptAt
        }
        return true
    }

    private static func decodeRecord(
        _ record: IntegrationLocalRecord
    ) throws -> BroadLocationContext {
        let document: LocationLocalDocument
        do {
            document = try decode(LocationLocalDocument.self, from: record.document)
        } catch {
            throw LocationContextCoordinatorError.invalidStoredDocument
        }
        guard document.schemaVersion == 1,
              record.connector == .location,
              record.stream == Self.stream,
              record.externalIdentifier == Self.currentRecordIdentifier,
              record.sourceTimestamp == document.context.capturedAt
        else {
            throw LocationContextCoordinatorError.invalidStoredDocument
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

private struct LocationLocalDocument: Codable {
    let schemaVersion: Int
    let context: BroadLocationContext
}

private struct LocationContextCursor: Codable {
    let schemaVersion: Int
    let lastAttemptAt: Date
    let lastSuccessfulRefreshAt: Date?
    let lastOutcome: BroadLocationOutcome
    let rejectedRecordCount: Int
}

private struct StoredLocationState {
    let context: BroadLocationContext?
    let cursor: LocationContextCursor?
    let cursorData: Data?
}
