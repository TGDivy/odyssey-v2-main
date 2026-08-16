import Foundation
import OdysseyIntegrations

public enum HealthImportCoordinatorError: Error, Equatable, Sendable {
    case unexpectedBatchKind
    case invalidStoredDocument
    case mutableHealthRecord
}

public struct HealthImportRunReceipt: Hashable, Sendable {
    public let kind: HealthSampleKind
    public let outcome: HealthImportOutcome
    public let queriedAt: Date
    public let insertedCount: Int
    public let deletedCount: Int
    public let duplicateCount: Int
    public let rejectedCount: Int
    public let cursorAdvanced: Bool

    public init(
        kind: HealthSampleKind,
        outcome: HealthImportOutcome,
        queriedAt: Date,
        insertedCount: Int,
        deletedCount: Int,
        duplicateCount: Int,
        rejectedCount: Int,
        cursorAdvanced: Bool
    ) {
        self.kind = kind
        self.outcome = outcome
        self.queriedAt = queriedAt
        self.insertedCount = insertedCount
        self.deletedCount = deletedCount
        self.duplicateCount = duplicateCount
        self.rejectedCount = rejectedCount
        self.cursorAdvanced = cursorAdvanced
    }
}

public struct HealthLocalSnapshot: Sendable {
    public let kind: HealthSampleKind
    public let samples: [HealthImportedSample]
    public let cursor: HealthImportCursor?

    public init(
        kind: HealthSampleKind,
        samples: [HealthImportedSample],
        cursor: HealthImportCursor?
    ) {
        self.kind = kind
        self.samples = samples
        self.cursor = cursor
    }
}

public actor HealthImportCoordinator {
    private let importer: any IncrementalHealthImporting
    private let store: any IntegrationLocalRecordStoring

    public init(
        importer: any IncrementalHealthImporting,
        store: any IntegrationLocalRecordStoring
    ) {
        self.importer = importer
        self.store = store
    }

    public func capability() async -> HealthImportCapability {
        await importer.capability()
    }

    public func authorizationState(
        for kinds: Set<HealthSampleKind>
    ) async -> IntegrationPermissionState {
        await importer.authorizationState(for: kinds)
    }

    public func requestAuthorization(
        for kinds: Set<HealthSampleKind>
    ) async throws -> IntegrationPermissionState {
        guard !kinds.isEmpty else { return .notRequired }
        return try await importer.requestAuthorization(for: kinds)
    }

    public func importChanges(
        for kind: HealthSampleKind,
        limit: Int = 500
    ) async throws -> HealthImportRunReceipt {
        guard (1 ... 500).contains(limit) else {
            throw HealthImportError.invalidBatch
        }
        let stored = try await store.integrationSnapshot(
            connector: .health,
            stream: kind.rawValue
        )
        let cursor = try stored.cursor.map(HealthImportCursor.init(data:))
        let batch = try await importer.changes(
            for: kind,
            after: cursor,
            limit: limit
        )
        guard batch.kind == kind else {
            throw HealthImportCoordinatorError.unexpectedBatchKind
        }
        guard batch.outcome == .imported || batch.outcome == .noChanges else {
            return HealthImportRunReceipt(
                kind: kind,
                outcome: batch.outcome,
                queriedAt: batch.queriedAt,
                insertedCount: 0,
                deletedCount: 0,
                duplicateCount: 0,
                rejectedCount: batch.rejectedRecordCount,
                cursorAdvanced: false
            )
        }

        let normalized = try Self.normalizedPage(batch)
        let receipt = try await store.applyIntegrationPage(IntegrationLocalPage(
            connector: .health,
            stream: kind.rawValue,
            records: normalized.records,
            deletedExternalIdentifiers: normalized.deletedExternalIdentifiers,
            nextCursor: batch.nextCursor?.data,
            appliedAt: batch.queriedAt,
            allowsUpdates: false
        ))
        guard receipt.updatedCount == 0 else {
            throw HealthImportCoordinatorError.mutableHealthRecord
        }
        return HealthImportRunReceipt(
            kind: kind,
            outcome: batch.outcome,
            queriedAt: batch.queriedAt,
            insertedCount: receipt.insertedCount,
            deletedCount: receipt.deletedCount,
            duplicateCount: normalized.duplicateCount + receipt.duplicateCount,
            rejectedCount: batch.rejectedRecordCount
                + normalized.rejectedCount
                + receipt.rejectedCount,
            cursorAdvanced: batch.nextCursor.map {
                $0.data != stored.cursor
            } ?? false
        )
    }

    public func localSnapshot(
        for kind: HealthSampleKind
    ) async throws -> HealthLocalSnapshot {
        let stored = try await store.integrationSnapshot(
            connector: .health,
            stream: kind.rawValue
        )
        let samples = try stored.records.map { record in
            let document = try Self.decode(record.document)
            guard document.schemaVersion == 1,
                  document.sample.identity.kind == kind,
                  document.sample.identity.externalIdentifier
                    == record.externalIdentifier,
                  document.sample.endDate == record.sourceTimestamp
            else {
                throw HealthImportCoordinatorError.invalidStoredDocument
            }
            return document.sample
        }.sorted {
            if $0.startDate != $1.startDate {
                return $0.startDate < $1.startDate
            }
            return $0.identity.externalIdentifier
                < $1.identity.externalIdentifier
        }
        return HealthLocalSnapshot(
            kind: kind,
            samples: samples,
            cursor: try stored.cursor.map(HealthImportCursor.init(data:))
        )
    }

    public func revokeLocalHealthData() async throws -> Int {
        try await store.clearIntegrationData(connector: .health)
    }

    private static func normalizedPage(
        _ batch: HealthImportBatch
    ) throws -> NormalizedHealthPage {
        var deleted = Set<String>()
        var duplicateCount = 0
        for identity in batch.deletedIdentities {
            if !deleted.insert(identity.externalIdentifier).inserted {
                duplicateCount += 1
            }
        }

        var accepted = [String: HealthImportedSample]()
        var conflicted = Set<String>()
        var rejectedCount = 0
        for sample in batch.samples {
            let identifier = sample.identity.externalIdentifier
            guard !deleted.contains(identifier) else {
                rejectedCount += 1
                continue
            }
            guard !conflicted.contains(identifier) else {
                rejectedCount += 1
                continue
            }
            if let prior = accepted[identifier] {
                if prior == sample {
                    duplicateCount += 1
                } else {
                    accepted.removeValue(forKey: identifier)
                    conflicted.insert(identifier)
                    rejectedCount += 1
                }
            } else {
                accepted[identifier] = sample
            }
        }

        let records = try accepted.values.map { sample in
            try IntegrationLocalRecord(
                connector: .health,
                stream: batch.kind.rawValue,
                externalIdentifier: sample.identity.externalIdentifier,
                sourceTimestamp: sample.endDate,
                document: try encode(HealthLocalDocument(
                    schemaVersion: 1,
                    sample: sample
                ))
            )
        }
        return NormalizedHealthPage(
            records: records,
            deletedExternalIdentifiers: Array(deleted),
            duplicateCount: duplicateCount,
            rejectedCount: rejectedCount
        )
    }

    private static func encode(_ document: HealthLocalDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private static func decode(_ data: Data) throws -> HealthLocalDocument {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(HealthLocalDocument.self, from: data)
        } catch {
            throw HealthImportCoordinatorError.invalidStoredDocument
        }
    }
}

private struct HealthLocalDocument: Codable {
    let schemaVersion: Int
    let sample: HealthImportedSample
}

private struct NormalizedHealthPage {
    let records: [IntegrationLocalRecord]
    let deletedExternalIdentifiers: [String]
    let duplicateCount: Int
    let rejectedCount: Int
}
