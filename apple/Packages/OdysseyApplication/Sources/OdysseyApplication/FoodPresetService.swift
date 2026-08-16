import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public protocol FoodPresetStore: LedgerStore {
    func projectedEntity(
        entityType: String,
        entityID: UUIDv7
    ) throws -> ProjectedEntity?
    func projectedEntities(
        entityType: String,
        limit: Int
    ) throws -> [ProjectedEntity]
}

extension SQLiteLedgerStore: FoodPresetStore {}

public enum FoodPresetServiceError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidClock
    case presetNotFound(UUIDv7)
    case invalidPresetProjection(String)
    case staleRevision(expected: Int, actual: Int)
    case presetArchived
    case noChanges
    case payloadTooLarge(maximumBytes: Int)
}

extension FoodPresetServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case .invalidClock:
            "The food preset clock is invalid or precedes its current revision."
        case .presetNotFound:
            "The food preset is unavailable."
        case let .invalidPresetProjection(message):
            message
        case .staleRevision:
            "The food preset changed. Reload it before saving another revision."
        case .presetArchived:
            "An archived food preset cannot be revised or restored."
        case .noChanges:
            "The food preset revision does not change any owner-authored field."
        case let .payloadTooLarge(maximumBytes):
            "The food preset exceeds the local \(maximumBytes)-byte safety limit."
        }
    }
}

public struct FoodPresetDraft: Codable, Hashable, Sendable {
    public let name: String
    public let servingDescription: String
    public let aliases: [String]
    public let nutrients: FoodNutrientProfile?

    public init(
        name: String,
        servingDescription: String,
        aliases: [String] = [],
        nutrients: FoodNutrientProfile? = nil
    ) {
        self.name = name
        self.servingDescription = servingDescription
        self.aliases = aliases
        self.nutrients = nutrients
    }
}

public struct FoodPresetCommitReceipt: Hashable, Sendable {
    public let preset: FoodPreset
    public let eventID: UUIDv7
    public let ledgerLocalSequence: Int64
    public let operationID: UUIDv7
    public let deviceSequence: Int64?
    public let mutationType: LedgerMutationType

    public init(
        preset: FoodPreset,
        eventID: UUIDv7,
        ledgerLocalSequence: Int64,
        operationID: UUIDv7,
        deviceSequence: Int64?,
        mutationType: LedgerMutationType
    ) {
        self.preset = preset
        self.eventID = eventID
        self.ledgerLocalSequence = ledgerLocalSequence
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.mutationType = mutationType
    }
}

private enum FoodPresetRevisionChange: String, Codable {
    case contentUpdated = "content_updated"
    case archived
}

private struct FoodPresetCreatedLedgerPayload: Codable {
    let foodPresetID: UUIDv7
}

private struct FoodPresetRevisedLedgerPayload: Codable {
    let foodPresetID: UUIDv7
    let change: FoodPresetRevisionChange
}

public actor FoodPresetService {
    public static let createdEventType = "food_preset.created.v1"
    public static let revisedEventType = "food_preset.revised.v1"
    public static let entityType = "food_preset"

    private let store: any FoodPresetStore
    private let ownerActorID: String
    private let clock: @Sendable () -> Date
    private let identifier: @Sendable () -> UUIDv7
    private let provenanceIdentifier: @Sendable () -> UUID

    public init(
        store: any FoodPresetStore,
        ownerActorID: String = "owner",
        clock: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> UUIDv7 = UUIDv7.init,
        provenanceIdentifier: @escaping @Sendable () -> UUID = UUID.init
    ) throws {
        guard (1 ... 100).contains(ownerActorID.count),
              ownerActorID == ownerActorID.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw FoodPresetServiceError.invalidConfiguration(
                "The food preset owner actor identifier is invalid."
            )
        }
        self.store = store
        self.ownerActorID = ownerActorID
        self.clock = clock
        self.identifier = identifier
        self.provenanceIdentifier = provenanceIdentifier
    }

    @discardableResult
    public func create(
        _ draft: FoodPresetDraft,
        sensitivity: DataClass = .private
    ) async throws -> FoodPresetCommitReceipt {
        let createdAt = try validClockInstant()
        let presetID = identifier()
        let provenanceID = provenanceIdentifier()
        let metadata = try EntityMetadata(
            id: presetID,
            createdAt: createdAt,
            createdBy: ActorRef(actorType: .user, actorID: ownerActorID),
            lastRevisedAt: createdAt,
            revision: 1,
            sensitivity: sensitivity,
            provenanceID: provenanceID
        )
        let preset = try makePreset(metadata: metadata, draft: draft)
        let document = try encodedDocument(preset)
        let eventID = identifier()
        let operationID = identifier()
        let eventPayload = try SyncJSONCoding.makeEncoder().encode(
            FoodPresetCreatedLedgerPayload(foodPresetID: presetID)
        )
        return try await commit(
            preset: preset,
            eventID: eventID,
            eventType: Self.createdEventType,
            eventPayload: eventPayload,
            projectionDocument: document,
            syncPayload: document,
            operationID: operationID,
            mutationType: .create,
            baseRevision: nil,
            occurredAt: createdAt,
            eventProvenanceID: provenanceID
        )
    }

    @discardableResult
    public func revise(
        presetID: UUIDv7,
        expectedRevision: Int,
        draft: FoodPresetDraft
    ) async throws -> FoodPresetCommitReceipt {
        let current = try currentPreset(id: presetID)
        try validateRevision(current, expectedRevision: expectedRevision)
        guard !current.matches(draft) else {
            throw FoodPresetServiceError.noChanges
        }
        let revisedAt = try validClockInstant(notBefore: current.metadata.lastRevisedAt)
        let metadata = try revisedMetadata(for: current, revisedAt: revisedAt)
        let revised = try makePreset(metadata: metadata, draft: draft)
        let currentDocument = try encodedDocument(current)
        let revisedDocument = try encodedDocument(revised)
        let syncPayload = try updatePayload(
            previousDocument: currentDocument,
            revisedDocument: revisedDocument
        )
        return try await commitRevision(
            preset: revised,
            current: current,
            eventPayload: FoodPresetRevisedLedgerPayload(
                foodPresetID: presetID,
                change: .contentUpdated
            ),
            projectionDocument: revisedDocument,
            syncPayload: syncPayload,
            mutationType: .update,
            revisedAt: revisedAt
        )
    }

    @discardableResult
    public func archive(
        presetID: UUIDv7,
        expectedRevision: Int
    ) async throws -> FoodPresetCommitReceipt {
        let current = try currentPreset(id: presetID)
        try validateRevision(current, expectedRevision: expectedRevision)
        let archivedAt = try validClockInstant(notBefore: current.metadata.lastRevisedAt)
        let metadata = try revisedMetadata(
            for: current,
            revisedAt: archivedAt,
            tombstonedAt: archivedAt
        )
        let archived = try FoodPreset(
            metadata: metadata,
            name: current.name,
            servingDescription: current.servingDescription,
            aliases: current.aliases,
            nutrients: current.nutrients
        )
        let document = try encodedDocument(archived)
        let emptyPayload = try SyncJSONCoding.makeEncoder().encode([String: JSONValue]())
        return try await commitRevision(
            preset: archived,
            current: current,
            eventPayload: FoodPresetRevisedLedgerPayload(
                foodPresetID: presetID,
                change: .archived
            ),
            projectionDocument: document,
            syncPayload: emptyPayload,
            mutationType: .delete,
            revisedAt: archivedAt
        )
    }

    public func preset(id: UUIDv7) throws -> FoodPreset {
        try currentPreset(id: id)
    }

    public func activePresets(limit: Int = 500) throws -> [FoodPreset] {
        guard (1 ... 500).contains(limit) else {
            throw FoodPresetServiceError.invalidConfiguration(
                "Food preset pages require 1 through 500 values."
            )
        }
        return try store.projectedEntities(
            entityType: Self.entityType,
            limit: limit
        ).map(decode)
    }

    private func currentPreset(id: UUIDv7) throws -> FoodPreset {
        guard let projection = try store.projectedEntity(
            entityType: Self.entityType,
            entityID: id
        ) else {
            throw FoodPresetServiceError.presetNotFound(id)
        }
        return try decode(projection)
    }

    private func decode(_ projection: ProjectedEntity) throws -> FoodPreset {
        guard projection.entityType == Self.entityType else {
            throw FoodPresetServiceError.invalidPresetProjection(
                "The food preset projection has the wrong entity type."
            )
        }
        let decoded: FoodPreset
        do {
            let value = try SyncJSONCoding.makeDecoder().decode(
                FoodPreset.self,
                from: projection.document
            )
            decoded = try FoodPreset(
                metadata: value.metadata,
                name: value.name,
                servingDescription: value.servingDescription,
                aliases: value.aliases,
                nutrients: value.nutrients
            )
        } catch {
            throw FoodPresetServiceError.invalidPresetProjection(
                "The food preset projection cannot be decoded safely."
            )
        }
        guard decoded.metadata.id == projection.entityID,
              decoded.metadata.revision == projection.revision,
              (decoded.metadata.tombstonedAt != nil) == projection.tombstone
        else {
            throw FoodPresetServiceError.invalidPresetProjection(
                "The food preset projection identity, revision, or tombstone is inconsistent."
            )
        }
        return decoded
    }

    private func validateRevision(
        _ preset: FoodPreset,
        expectedRevision: Int
    ) throws {
        guard preset.metadata.tombstonedAt == nil else {
            throw FoodPresetServiceError.presetArchived
        }
        guard expectedRevision == preset.metadata.revision else {
            throw FoodPresetServiceError.staleRevision(
                expected: expectedRevision,
                actual: preset.metadata.revision
            )
        }
    }

    private func revisedMetadata(
        for current: FoodPreset,
        revisedAt: Date,
        tombstonedAt: Date? = nil
    ) throws -> EntityMetadata {
        try EntityMetadata(
            id: current.metadata.id,
            schemaVersion: current.metadata.schemaVersion,
            createdAt: current.metadata.createdAt,
            createdBy: current.metadata.createdBy,
            lastRevisedAt: revisedAt,
            revision: current.metadata.revision + 1,
            tombstonedAt: tombstonedAt,
            sensitivity: current.metadata.sensitivity,
            provenanceID: current.metadata.provenanceID
        )
    }

    private func makePreset(
        metadata: EntityMetadata,
        draft: FoodPresetDraft
    ) throws -> FoodPreset {
        try FoodPreset(
            metadata: metadata,
            name: draft.name,
            servingDescription: draft.servingDescription,
            aliases: draft.aliases,
            nutrients: draft.nutrients
        )
    }

    private func encodedDocument(_ preset: FoodPreset) throws -> Data {
        let document = try SyncJSONCoding.makeEncoder().encode(preset)
        guard document.count <= SQLiteLedgerStore.maximumSyncPayloadBytes else {
            throw FoodPresetServiceError.payloadTooLarge(
                maximumBytes: SQLiteLedgerStore.maximumSyncPayloadBytes
            )
        }
        return document
    }

    private func updatePayload(
        previousDocument: Data,
        revisedDocument: Data
    ) throws -> Data {
        let decoder = SyncJSONCoding.makeDecoder()
        let previous = try decoder.decode([String: JSONValue].self, from: previousDocument)
        let revised = try decoder.decode([String: JSONValue].self, from: revisedDocument)
        var changed = revised.filter { previous[$0.key] != $0.value }
        for key in previous.keys where revised[key] == nil {
            changed[key] = .null
        }
        let payload = try SyncJSONCoding.makeEncoder().encode(changed)
        guard payload.count <= SQLiteLedgerStore.maximumSyncPayloadBytes else {
            throw FoodPresetServiceError.payloadTooLarge(
                maximumBytes: SQLiteLedgerStore.maximumSyncPayloadBytes
            )
        }
        return payload
    }

    private func commitRevision(
        preset: FoodPreset,
        current: FoodPreset,
        eventPayload: FoodPresetRevisedLedgerPayload,
        projectionDocument: Data,
        syncPayload: Data,
        mutationType: LedgerMutationType,
        revisedAt: Date
    ) async throws -> FoodPresetCommitReceipt {
        let eventID = identifier()
        let operationID = identifier()
        return try await commit(
            preset: preset,
            eventID: eventID,
            eventType: Self.revisedEventType,
            eventPayload: try SyncJSONCoding.makeEncoder().encode(eventPayload),
            projectionDocument: projectionDocument,
            syncPayload: syncPayload,
            operationID: operationID,
            mutationType: mutationType,
            baseRevision: current.metadata.revision,
            occurredAt: revisedAt,
            eventProvenanceID: provenanceIdentifier()
        )
    }

    private func commit(
        preset: FoodPreset,
        eventID: UUIDv7,
        eventType: String,
        eventPayload: Data,
        projectionDocument: Data,
        syncPayload: Data,
        operationID: UUIDv7,
        mutationType: LedgerMutationType,
        baseRevision: Int?,
        occurredAt: Date,
        eventProvenanceID: UUID
    ) async throws -> FoodPresetCommitReceipt {
        let receipt = try await store.commit(LedgerCommit(
            entry: LedgerEntry(
                eventID: eventID,
                eventType: eventType,
                aggregateType: Self.entityType,
                aggregateID: preset.metadata.id,
                occurredAt: occurredAt,
                recordedAt: occurredAt,
                payload: eventPayload,
                provenanceID: eventProvenanceID
            ),
            projection: ProjectionMutation(
                entityType: Self.entityType,
                entityID: preset.metadata.id,
                revision: preset.metadata.revision,
                mutationType: mutationType,
                document: projectionDocument
            ),
            syncMutation: SyncMutationDraft(
                operationID: operationID,
                entityType: Self.entityType,
                entityID: preset.metadata.id,
                mutationType: mutationType,
                baseRevision: baseRevision,
                payload: syncPayload,
                createdAt: occurredAt,
                idempotencyKey: operationID.description,
                sensitivityClass: preset.metadata.sensitivity
            )
        ))
        return FoodPresetCommitReceipt(
            preset: preset,
            eventID: eventID,
            ledgerLocalSequence: receipt.localSequence,
            operationID: operationID,
            deviceSequence: receipt.queuedOperation?.deviceSequence,
            mutationType: mutationType
        )
    }

    private func validClockInstant(notBefore: Date? = nil) throws -> Date {
        let value = clock()
        guard value.timeIntervalSinceReferenceDate.isFinite,
              notBefore.map({ value >= $0 }) ?? true
        else {
            throw FoodPresetServiceError.invalidClock
        }
        return value
    }
}

private extension FoodPreset {
    func matches(_ draft: FoodPresetDraft) -> Bool {
        name == draft.name
            && servingDescription == draft.servingDescription
            && aliases == draft.aliases
            && nutrients == draft.nutrients
    }
}
