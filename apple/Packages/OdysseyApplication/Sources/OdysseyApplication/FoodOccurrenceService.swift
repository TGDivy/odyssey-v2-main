import Foundation
import OdysseyData
import OdysseyDomain
import OdysseySync

public protocol FoodOccurrenceStore: FoodPresetStore {}

extension SQLiteLedgerStore: FoodOccurrenceStore {}

public enum FoodOccurrenceServiceError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidClock
    case presetNotFound(UUIDv7)
    case invalidPresetProjection(String)
    case stalePresetRevision(expected: Int, actual: Int)
    case presetArchived
    case occurrenceNotFound(UUIDv7)
    case invalidOccurrenceProjection(String)
    case staleOccurrenceRevision(expected: Int, actual: Int)
    case occurrenceVoided
    case noChanges
    case payloadTooLarge(maximumBytes: Int)
}

extension FoodOccurrenceServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case .invalidClock:
            "The food occurrence clock is invalid or precedes its current revision."
        case .presetNotFound:
            "The selected food preset is unavailable."
        case let .invalidPresetProjection(message):
            message
        case .stalePresetRevision:
            "The selected food preset changed. Reload it before logging."
        case .presetArchived:
            "An archived food preset cannot be logged."
        case .occurrenceNotFound:
            "The food occurrence is unavailable."
        case let .invalidOccurrenceProjection(message):
            message
        case .staleOccurrenceRevision:
            "The food occurrence changed. Reload it before correcting it."
        case .occurrenceVoided:
            "A voided food occurrence cannot be corrected or restored."
        case .noChanges:
            "The food occurrence correction does not change any owner-authored field."
        case let .payloadTooLarge(maximumBytes):
            "The food occurrence exceeds the local \(maximumBytes)-byte safety limit."
        }
    }
}

public struct FoodOccurrenceDraft: Hashable, Sendable {
    public let presetID: UUIDv7
    public let expectedPresetRevision: Int
    public let quantity: Double
    public let occurredAt: Date
    public let timeZoneID: String

    public init(
        presetID: UUIDv7,
        expectedPresetRevision: Int,
        quantity: Double = 1,
        occurredAt: Date,
        timeZoneID: String
    ) {
        self.presetID = presetID
        self.expectedPresetRevision = expectedPresetRevision
        self.quantity = quantity
        self.occurredAt = occurredAt
        self.timeZoneID = timeZoneID
    }
}

public struct FoodOccurrenceCorrectionDraft: Hashable, Sendable {
    public let expectedOccurrenceRevision: Int
    public let presetID: UUIDv7
    public let expectedPresetRevision: Int
    public let quantity: Double
    public let occurredAt: Date
    public let timeZoneID: String

    public init(
        expectedOccurrenceRevision: Int,
        presetID: UUIDv7,
        expectedPresetRevision: Int,
        quantity: Double,
        occurredAt: Date,
        timeZoneID: String
    ) {
        self.expectedOccurrenceRevision = expectedOccurrenceRevision
        self.presetID = presetID
        self.expectedPresetRevision = expectedPresetRevision
        self.quantity = quantity
        self.occurredAt = occurredAt
        self.timeZoneID = timeZoneID
    }
}

public struct FoodOccurrenceCommitReceipt: Hashable, Sendable {
    public let occurrence: FoodOccurrence
    public let eventID: UUIDv7
    public let ledgerLocalSequence: Int64
    public let operationID: UUIDv7
    public let deviceSequence: Int64?
    public let mutationType: LedgerMutationType

    public init(
        occurrence: FoodOccurrence,
        eventID: UUIDv7,
        ledgerLocalSequence: Int64,
        operationID: UUIDv7,
        deviceSequence: Int64?,
        mutationType: LedgerMutationType
    ) {
        self.occurrence = occurrence
        self.eventID = eventID
        self.ledgerLocalSequence = ledgerLocalSequence
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.mutationType = mutationType
    }
}

private enum FoodOccurrenceRevisionChange: String, Codable {
    case detailsCorrected = "details_corrected"
    case voided
}

private struct FoodConsumedLedgerPayload: Codable {
    let foodOccurrenceID: UUIDv7
    let foodPresetID: UUIDv7
}

private struct FoodConsumptionCorrectedLedgerPayload: Codable {
    let foodOccurrenceID: UUIDv7
    let foodPresetID: UUIDv7
    let change: FoodOccurrenceRevisionChange
}

public actor FoodOccurrenceService {
    public static let consumedEventType = "food.consumed.v1"
    public static let correctedEventType = "food.consumption_corrected.v1"
    public static let entityType = "food_occurrence"

    private let store: any FoodOccurrenceStore
    private let ownerActorID: String
    private let clock: @Sendable () -> Date
    private let identifier: @Sendable () -> UUIDv7
    private let provenanceIdentifier: @Sendable () -> UUID

    public init(
        store: any FoodOccurrenceStore,
        ownerActorID: String = "owner",
        clock: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> UUIDv7 = UUIDv7.init,
        provenanceIdentifier: @escaping @Sendable () -> UUID = UUID.init
    ) throws {
        guard (1 ... 100).contains(ownerActorID.count),
              ownerActorID == ownerActorID.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw FoodOccurrenceServiceError.invalidConfiguration(
                "The food occurrence owner actor identifier is invalid."
            )
        }
        self.store = store
        self.ownerActorID = ownerActorID
        self.clock = clock
        self.identifier = identifier
        self.provenanceIdentifier = provenanceIdentifier
    }

    @discardableResult
    public func record(
        _ draft: FoodOccurrenceDraft
    ) async throws -> FoodOccurrenceCommitReceipt {
        let recordedAt = try validClockInstant()
        let preset = try currentPreset(
            id: draft.presetID,
            expectedRevision: draft.expectedPresetRevision
        )
        let occurrenceID = identifier()
        let provenanceID = provenanceIdentifier()
        let metadata = try EntityMetadata(
            id: occurrenceID,
            createdAt: recordedAt,
            createdBy: ActorRef(actorType: .user, actorID: ownerActorID),
            lastRevisedAt: recordedAt,
            revision: 1,
            sensitivity: .sensitive,
            provenanceID: provenanceID
        )
        let occurrence = try makeOccurrence(
            metadata: metadata,
            preset: preset,
            quantity: draft.quantity,
            occurredAt: draft.occurredAt,
            timeZoneID: draft.timeZoneID
        )
        let document = try encodedDocument(occurrence)
        let eventID = identifier()
        let operationID = identifier()
        let eventPayload = try SyncJSONCoding.makeEncoder().encode(
            FoodConsumedLedgerPayload(
                foodOccurrenceID: occurrenceID,
                foodPresetID: preset.metadata.id
            )
        )
        return try await commit(
            occurrence: occurrence,
            eventID: eventID,
            eventType: Self.consumedEventType,
            eventPayload: eventPayload,
            projectionDocument: document,
            syncPayload: document,
            operationID: operationID,
            mutationType: .create,
            baseRevision: nil,
            recordedAt: recordedAt,
            eventProvenanceID: provenanceID
        )
    }

    @discardableResult
    public func correct(
        occurrenceID: UUIDv7,
        draft: FoodOccurrenceCorrectionDraft
    ) async throws -> FoodOccurrenceCommitReceipt {
        let current = try currentOccurrence(id: occurrenceID)
        try validateOccurrenceRevision(
            current,
            expectedRevision: draft.expectedOccurrenceRevision
        )
        let preset = try currentPreset(
            id: draft.presetID,
            expectedRevision: draft.expectedPresetRevision
        )
        let correctedAt = try validClockInstant(notBefore: current.metadata.lastRevisedAt)
        let metadata = try revisedMetadata(for: current, revisedAt: correctedAt)
        let corrected = try makeOccurrence(
            metadata: metadata,
            preset: preset,
            quantity: draft.quantity,
            occurredAt: draft.occurredAt,
            timeZoneID: draft.timeZoneID
        )
        guard !current.hasSameDetails(as: corrected) else {
            throw FoodOccurrenceServiceError.noChanges
        }
        let currentDocument = try encodedDocument(current)
        let correctedDocument = try encodedDocument(corrected)
        let syncPayload = try updatePayload(
            previousDocument: currentDocument,
            revisedDocument: correctedDocument
        )
        return try await commitRevision(
            occurrence: corrected,
            current: current,
            eventPayload: FoodConsumptionCorrectedLedgerPayload(
                foodOccurrenceID: occurrenceID,
                foodPresetID: corrected.presetID,
                change: .detailsCorrected
            ),
            projectionDocument: correctedDocument,
            syncPayload: syncPayload,
            mutationType: .update,
            recordedAt: correctedAt
        )
    }

    @discardableResult
    public func void(
        occurrenceID: UUIDv7,
        expectedRevision: Int
    ) async throws -> FoodOccurrenceCommitReceipt {
        let current = try currentOccurrence(id: occurrenceID)
        try validateOccurrenceRevision(current, expectedRevision: expectedRevision)
        let voidedAt = try validClockInstant(notBefore: current.metadata.lastRevisedAt)
        let metadata = try revisedMetadata(
            for: current,
            revisedAt: voidedAt,
            tombstonedAt: voidedAt
        )
        let voided = try FoodOccurrence(
            metadata: metadata,
            presetID: current.presetID,
            presetRevision: current.presetRevision,
            presetNameSnapshot: current.presetNameSnapshot,
            servingDescriptionSnapshot: current.servingDescriptionSnapshot,
            quantity: current.quantity,
            nutrientTotals: current.nutrientTotals,
            occurredAt: current.occurredAt,
            timeZoneID: current.timeZoneID,
            originalUTCOffsetSeconds: current.originalUTCOffsetSeconds
        )
        let document = try encodedDocument(voided)
        let emptyPayload = try SyncJSONCoding.makeEncoder().encode([String: JSONValue]())
        return try await commitRevision(
            occurrence: voided,
            current: current,
            eventPayload: FoodConsumptionCorrectedLedgerPayload(
                foodOccurrenceID: occurrenceID,
                foodPresetID: current.presetID,
                change: .voided
            ),
            projectionDocument: document,
            syncPayload: emptyPayload,
            mutationType: .delete,
            recordedAt: voidedAt
        )
    }

    public func occurrence(id: UUIDv7) throws -> FoodOccurrence {
        try currentOccurrence(id: id)
    }

    public func recentOccurrences(limit: Int = 100) throws -> [FoodOccurrence] {
        guard (1 ... 500).contains(limit) else {
            throw FoodOccurrenceServiceError.invalidConfiguration(
                "Food occurrence pages require 1 through 500 values."
            )
        }
        return Array(try activeOccurrences().prefix(limit))
    }

    public func rankingUsages(limit: Int = 500) throws -> [FoodPresetUsage] {
        guard (1 ... 500).contains(limit) else {
            throw FoodOccurrenceServiceError.invalidConfiguration(
                "Food ranking history requires 1 through 500 occurrences."
            )
        }
        return try activeOccurrences().prefix(limit).map { occurrence in
            let context: FoodPresetRankingContext
            do {
                context = try FoodPresetRankingContext(
                    occurredAt: occurrence.occurredAt,
                    timeZoneID: occurrence.timeZoneID
                )
            } catch {
                throw FoodOccurrenceServiceError.invalidOccurrenceProjection(
                    "The food occurrence cannot produce a valid ranking context."
                )
            }
            return try FoodPresetUsage(
                usageID: occurrence.metadata.id,
                presetID: occurrence.presetID,
                occurredAt: occurrence.occurredAt,
                context: context
            )
        }
    }

    private func activeOccurrences() throws -> [FoodOccurrence] {
        try store.projectedEntities(
            entityType: Self.entityType,
            limit: 500
        ).map(decodeOccurrence).sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.metadata.id.description > $1.metadata.id.description
        }
    }

    private func currentPreset(
        id: UUIDv7,
        expectedRevision: Int
    ) throws -> FoodPreset {
        guard let projection = try store.projectedEntity(
            entityType: FoodPresetService.entityType,
            entityID: id
        ) else {
            throw FoodOccurrenceServiceError.presetNotFound(id)
        }
        guard !projection.tombstone else {
            throw FoodOccurrenceServiceError.presetArchived
        }
        let preset = try decodePreset(projection)
        guard preset.metadata.tombstonedAt == nil else {
            throw FoodOccurrenceServiceError.presetArchived
        }
        guard expectedRevision == preset.metadata.revision else {
            throw FoodOccurrenceServiceError.stalePresetRevision(
                expected: expectedRevision,
                actual: preset.metadata.revision
            )
        }
        return preset
    }

    private func currentOccurrence(id: UUIDv7) throws -> FoodOccurrence {
        guard let projection = try store.projectedEntity(
            entityType: Self.entityType,
            entityID: id
        ) else {
            throw FoodOccurrenceServiceError.occurrenceNotFound(id)
        }
        guard !projection.tombstone else {
            throw FoodOccurrenceServiceError.occurrenceVoided
        }
        let occurrence = try decodeOccurrence(projection)
        guard occurrence.metadata.tombstonedAt == nil else {
            throw FoodOccurrenceServiceError.occurrenceVoided
        }
        return occurrence
    }

    private func decodePreset(_ projection: ProjectedEntity) throws -> FoodPreset {
        guard projection.entityType == FoodPresetService.entityType else {
            throw FoodOccurrenceServiceError.invalidPresetProjection(
                "The selected food preset projection has the wrong entity type."
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
            throw FoodOccurrenceServiceError.invalidPresetProjection(
                "The selected food preset cannot be decoded safely."
            )
        }
        guard decoded.metadata.id == projection.entityID,
              decoded.metadata.revision == projection.revision,
              decoded.metadata.tombstonedAt == nil
        else {
            throw FoodOccurrenceServiceError.invalidPresetProjection(
                "The selected food preset identity or revision is inconsistent."
            )
        }
        return decoded
    }

    private func decodeOccurrence(_ projection: ProjectedEntity) throws -> FoodOccurrence {
        guard projection.entityType == Self.entityType else {
            throw FoodOccurrenceServiceError.invalidOccurrenceProjection(
                "The food occurrence projection has the wrong entity type."
            )
        }
        let decoded: FoodOccurrence
        do {
            let value = try SyncJSONCoding.makeDecoder().decode(
                FoodOccurrence.self,
                from: projection.document
            )
            decoded = try FoodOccurrence(
                metadata: value.metadata,
                presetID: value.presetID,
                presetRevision: value.presetRevision,
                presetNameSnapshot: value.presetNameSnapshot,
                servingDescriptionSnapshot: value.servingDescriptionSnapshot,
                quantity: value.quantity,
                nutrientTotals: value.nutrientTotals,
                occurredAt: value.occurredAt,
                timeZoneID: value.timeZoneID,
                originalUTCOffsetSeconds: value.originalUTCOffsetSeconds
            )
        } catch {
            throw FoodOccurrenceServiceError.invalidOccurrenceProjection(
                "The food occurrence projection cannot be decoded safely."
            )
        }
        guard decoded.metadata.id == projection.entityID,
              decoded.metadata.revision == projection.revision,
              !projection.tombstone,
              decoded.metadata.tombstonedAt == nil
        else {
            throw FoodOccurrenceServiceError.invalidOccurrenceProjection(
                "The food occurrence projection identity, revision, or tombstone is inconsistent."
            )
        }
        return decoded
    }

    private func validateOccurrenceRevision(
        _ occurrence: FoodOccurrence,
        expectedRevision: Int
    ) throws {
        guard occurrence.metadata.tombstonedAt == nil else {
            throw FoodOccurrenceServiceError.occurrenceVoided
        }
        guard expectedRevision == occurrence.metadata.revision else {
            throw FoodOccurrenceServiceError.staleOccurrenceRevision(
                expected: expectedRevision,
                actual: occurrence.metadata.revision
            )
        }
    }

    private func revisedMetadata(
        for current: FoodOccurrence,
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

    private func makeOccurrence(
        metadata: EntityMetadata,
        preset: FoodPreset,
        quantity: Double,
        occurredAt: Date,
        timeZoneID: String
    ) throws -> FoodOccurrence {
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw FoodOccurrenceValidationError.invalidTemporalContext
        }
        return try FoodOccurrence(
            metadata: metadata,
            presetID: preset.metadata.id,
            presetRevision: preset.metadata.revision,
            presetNameSnapshot: preset.name,
            servingDescriptionSnapshot: preset.servingDescription,
            quantity: quantity,
            nutrientTotals: try nutrientTotals(
                perServing: preset.nutrients,
                quantity: quantity
            ),
            occurredAt: occurredAt,
            timeZoneID: timeZoneID,
            originalUTCOffsetSeconds: timeZone.secondsFromGMT(for: occurredAt)
        )
    }

    private func nutrientTotals(
        perServing: FoodNutrientProfile?,
        quantity: Double
    ) throws -> FoodNutrientProfile? {
        guard quantity.isFinite,
              quantity > 0,
              quantity <= FoodOccurrence.maximumQuantity
        else {
            throw FoodOccurrenceValidationError.invalidQuantity
        }
        guard let perServing else { return nil }
        do {
            return try FoodNutrientProfile(
                energyKilocalories: perServing.energyKilocalories.map { $0 * quantity },
                proteinGrams: perServing.proteinGrams.map { $0 * quantity },
                caffeineMilligrams: perServing.caffeineMilligrams.map { $0 * quantity },
                alcoholGrams: perServing.alcoholGrams.map { $0 * quantity },
                sourceKind: perServing.sourceKind,
                sourceDescription: perServing.sourceDescription
            )
        } catch {
            throw FoodOccurrenceValidationError.invalidNutrients
        }
    }

    private func encodedDocument(_ occurrence: FoodOccurrence) throws -> Data {
        let document = try SyncJSONCoding.makeEncoder().encode(occurrence)
        guard document.count <= SQLiteLedgerStore.maximumSyncPayloadBytes else {
            throw FoodOccurrenceServiceError.payloadTooLarge(
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
            throw FoodOccurrenceServiceError.payloadTooLarge(
                maximumBytes: SQLiteLedgerStore.maximumSyncPayloadBytes
            )
        }
        return payload
    }

    private func commitRevision(
        occurrence: FoodOccurrence,
        current: FoodOccurrence,
        eventPayload: FoodConsumptionCorrectedLedgerPayload,
        projectionDocument: Data,
        syncPayload: Data,
        mutationType: LedgerMutationType,
        recordedAt: Date
    ) async throws -> FoodOccurrenceCommitReceipt {
        let eventID = identifier()
        let operationID = identifier()
        return try await commit(
            occurrence: occurrence,
            eventID: eventID,
            eventType: Self.correctedEventType,
            eventPayload: try SyncJSONCoding.makeEncoder().encode(eventPayload),
            projectionDocument: projectionDocument,
            syncPayload: syncPayload,
            operationID: operationID,
            mutationType: mutationType,
            baseRevision: current.metadata.revision,
            recordedAt: recordedAt,
            eventProvenanceID: provenanceIdentifier()
        )
    }

    private func commit(
        occurrence: FoodOccurrence,
        eventID: UUIDv7,
        eventType: String,
        eventPayload: Data,
        projectionDocument: Data,
        syncPayload: Data,
        operationID: UUIDv7,
        mutationType: LedgerMutationType,
        baseRevision: Int?,
        recordedAt: Date,
        eventProvenanceID: UUID
    ) async throws -> FoodOccurrenceCommitReceipt {
        let receipt = try await store.commit(LedgerCommit(
            entry: LedgerEntry(
                eventID: eventID,
                eventType: eventType,
                aggregateType: Self.entityType,
                aggregateID: occurrence.metadata.id,
                occurredAt: occurrence.occurredAt,
                recordedAt: recordedAt,
                payload: eventPayload,
                provenanceID: eventProvenanceID
            ),
            projection: ProjectionMutation(
                entityType: Self.entityType,
                entityID: occurrence.metadata.id,
                revision: occurrence.metadata.revision,
                mutationType: mutationType,
                document: projectionDocument
            ),
            syncMutation: SyncMutationDraft(
                operationID: operationID,
                entityType: Self.entityType,
                entityID: occurrence.metadata.id,
                mutationType: mutationType,
                baseRevision: baseRevision,
                payload: syncPayload,
                createdAt: recordedAt,
                idempotencyKey: operationID.description,
                sensitivityClass: occurrence.metadata.sensitivity
            )
        ))
        return FoodOccurrenceCommitReceipt(
            occurrence: occurrence,
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
            throw FoodOccurrenceServiceError.invalidClock
        }
        return value
    }
}

private extension FoodOccurrence {
    func hasSameDetails(as other: FoodOccurrence) -> Bool {
        presetID == other.presetID
            && presetRevision == other.presetRevision
            && presetNameSnapshot == other.presetNameSnapshot
            && servingDescriptionSnapshot == other.servingDescriptionSnapshot
            && quantity == other.quantity
            && nutrientTotals == other.nutrientTotals
            && occurredAt == other.occurredAt
            && timeZoneID == other.timeZoneID
            && originalUTCOffsetSeconds == other.originalUTCOffsetSeconds
    }
}
