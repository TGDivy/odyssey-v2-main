import Foundation
import OdysseyData
import OdysseyIntelligence

public enum NowExperienceError: Error, Equatable, Sendable {
    case invalidSchema
    case invalidClock
    case invalidDocument
}

public struct NowExperienceRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let lastSeenAt: Date?
    public let correction: NowStateCorrection?

    public init(
        lastSeenAt: Date? = nil,
        correction: NowStateCorrection? = nil
    ) throws {
        guard lastSeenAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw NowExperienceError.invalidClock
        }
        schemaVersion = Self.currentSchemaVersion
        self.lastSeenAt = lastSeenAt
        self.correction = correction
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion)
            == Self.currentSchemaVersion
        else {
            throw NowExperienceError.invalidSchema
        }
        try self.init(
            lastSeenAt: values.decodeIfPresent(Date.self, forKey: .lastSeenAt),
            correction: values.decodeIfPresent(
                NowStateCorrection.self,
                forKey: .correction
            )
        )
    }
}

public actor NowExperienceService {
    public static let stateKey = "now_experience"

    private let store: any LocalApplicationStateStoring
    private let clock: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        store: any LocalApplicationStateStoring,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.clock = clock
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func record() throws -> NowExperienceRecord {
        guard let stored = try store.localApplicationState(for: Self.stateKey) else {
            return try NowExperienceRecord()
        }
        guard stored.schemaVersion == NowExperienceRecord.currentSchemaVersion else {
            throw NowExperienceError.invalidSchema
        }
        do {
            return try decoder.decode(NowExperienceRecord.self, from: stored.document)
        } catch let error as NowExperienceError {
            throw error
        } catch {
            throw NowExperienceError.invalidDocument
        }
    }

    @discardableResult
    public func recordVisit(at visitedAt: Date? = nil) throws -> NowExperienceRecord {
        let visitedAt = visitedAt ?? clock()
        guard visitedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NowExperienceError.invalidClock
        }
        let current = try record()
        let effectiveVisit = max(current.lastSeenAt ?? visitedAt, visitedAt)
        return try persist(NowExperienceRecord(
            lastSeenAt: effectiveVisit,
            correction: current.correction
        ))
    }

    @discardableResult
    public func setCorrection(
        _ correction: NowStateCorrection
    ) throws -> NowExperienceRecord {
        let current = try record()
        return try persist(NowExperienceRecord(
            lastSeenAt: current.lastSeenAt,
            correction: correction
        ))
    }

    @discardableResult
    public func clearCorrection() throws -> NowExperienceRecord {
        let current = try record()
        return try persist(NowExperienceRecord(lastSeenAt: current.lastSeenAt))
    }

    private func persist(
        _ record: NowExperienceRecord
    ) throws -> NowExperienceRecord {
        let updatedAt = clock()
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NowExperienceError.invalidClock
        }
        let document: Data
        do {
            document = try encoder.encode(record)
        } catch {
            throw NowExperienceError.invalidDocument
        }
        _ = try store.putLocalApplicationState(
            key: Self.stateKey,
            schemaVersion: NowExperienceRecord.currentSchemaVersion,
            document: document,
            updatedAt: updatedAt
        )
        return record
    }
}
