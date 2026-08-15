import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public actor InMemoryLedgerStore: LedgerStore {
    private var storedEntries: [LedgerEntry] = []
    private var nextDeviceSequence: Int64 = 1

    public init() {}

    public func append(_ entry: LedgerEntry) async throws {
        if !storedEntries.contains(where: { $0.eventID == entry.eventID }) {
            storedEntries.append(entry)
        }
    }

    public func commit(_ commit: LedgerCommit) async throws -> LedgerCommitReceipt {
        let localIndex: Int
        if let existingIndex = storedEntries.firstIndex(where: { $0.eventID == commit.entry.eventID }) {
            localIndex = existingIndex
        } else {
            storedEntries.append(commit.entry)
            localIndex = storedEntries.index(before: storedEntries.endIndex)
        }
        let localSequence = Int64(localIndex + 1)
        let queuedOperation = commit.syncMutation.map { mutation in
            let operation = PendingSyncOperation(
                operationID: mutation.operationID,
                deviceSequence: nextDeviceSequence,
                entityType: mutation.entityType,
                entityID: mutation.entityID,
                mutationType: mutation.mutationType,
                baseRevision: mutation.baseRevision,
                payload: mutation.payload,
                payloadSHA256: SHA256Digest.hexDigest(of: mutation.payload),
                createdAt: mutation.createdAt,
                idempotencyKey: mutation.idempotencyKey,
                sensitivityClass: mutation.sensitivityClass,
                sourceEventID: commit.entry.eventID,
                status: .pending,
                attemptCount: 0,
                nextAttemptAt: nil,
                lastError: nil
            )
            nextDeviceSequence += 1
            return operation
        }
        return LedgerCommitReceipt(
            localSequence: localSequence,
            queuedOperation: queuedOperation
        )
    }

    public func entries(after eventID: UUIDv7?, limit: Int) async throws -> [LedgerEntry] {
        let startIndex: Int
        if let eventID, let index = storedEntries.firstIndex(where: { $0.eventID == eventID }) {
            startIndex = storedEntries.index(after: index)
        } else {
            startIndex = storedEntries.startIndex
        }
        return Array(storedEntries[startIndex...].prefix(limit))
    }
}

public struct SyntheticClock: Sendable {
    public let now: Date

    public init(now: Date) {
        self.now = now
    }
}
