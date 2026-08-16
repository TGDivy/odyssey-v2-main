import Foundation
import OdysseyCalendar
import OdysseyData
import OdysseyDomain
import OdysseyIntelligence
import OdysseyLocation
import OdysseySync

public enum NativeReentryError: Error, Equatable, Sendable {
    case invalidClock
    case invalidTimeZone
    case invalidIdentifier
}

public struct NativeReentryInput: Sendable {
    public let lastSeenAt: Date?
    public let generatedAt: Date
    public let deviceTimeZoneID: String
    public let acceptedSeasonVersions: [CachedLifeModelVersion]
    public let recentCaptures: [CaptureRecord]
    public let calendarSnapshot: CalendarLocalSnapshot?
    public let locationOverview: LocationContextOverview?
    public let opportunities: [ReentryOpportunity]

    public init(
        lastSeenAt: Date?,
        generatedAt: Date,
        deviceTimeZoneID: String,
        acceptedSeasonVersions: [CachedLifeModelVersion] = [],
        recentCaptures: [CaptureRecord] = [],
        calendarSnapshot: CalendarLocalSnapshot? = nil,
        locationOverview: LocationContextOverview? = nil,
        opportunities: [ReentryOpportunity] = []
    ) throws {
        guard lastSeenAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              generatedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw NativeReentryError.invalidClock
        }
        guard TimeZone(identifier: deviceTimeZoneID) != nil else {
            throw NativeReentryError.invalidTimeZone
        }
        self.lastSeenAt = lastSeenAt
        self.generatedAt = generatedAt
        self.deviceTimeZoneID = deviceTimeZoneID
        self.acceptedSeasonVersions = acceptedSeasonVersions
        self.recentCaptures = recentCaptures
        self.calendarSnapshot = calendarSnapshot
        self.locationOverview = locationOverview
        self.opportunities = opportunities
    }
}

public struct NativeReentryProjector: Sendable {
    public init() {}

    public func project(
        _ input: NativeReentryInput
    ) throws -> ReentrySurface? {
        let projector = ReentryProjector()
        guard try projector.shouldEnter(
            lastSeen: input.lastSeenAt,
            now: input.generatedAt
        ), let lastSeenAt = input.lastSeenAt else {
            return nil
        }
        return try projector.project(
            lastSeen: lastSeenAt,
            now: input.generatedAt,
            changes: try materialChanges(input, since: lastSeenAt),
            opportunities: input.opportunities
        )
    }

    private func materialChanges(
        _ input: NativeReentryInput,
        since lastSeenAt: Date
    ) throws -> [ReentryMaterialChange] {
        var changes = [ReentryMaterialChange]()
        if let season = try seasonChange(input, since: lastSeenAt) {
            changes.append(season)
        }
        if let capture = try captureChange(input, since: lastSeenAt) {
            changes.append(capture)
        }
        if let calendar = try calendarChange(input, since: lastSeenAt) {
            changes.append(calendar)
        }
        if let location = try locationChange(input, since: lastSeenAt) {
            changes.append(location)
        }
        return changes
    }

    private func seasonChange(
        _ input: NativeReentryInput,
        since lastSeenAt: Date
    ) throws -> ReentryMaterialChange? {
        let versions = input.acceptedSeasonVersions.filter {
            $0.kind == .season
                && $0.acceptedAt > lastSeenAt
                && $0.acceptedAt <= input.generatedAt
        }.sorted {
            if $0.acceptanceSequence != $1.acceptanceSequence {
                return $0.acceptanceSequence > $1.acceptanceSequence
            }
            return $0.versionID.description < $1.versionID.description
        }
        guard let latest = versions.first else { return nil }
        let title = (try? SyncJSONCoding.makeDecoder().decode(
            Season.self,
            from: latest.document
        ).title).map { bounded($0, maximum: 300) }
        let summary: String
        if let title {
            summary = versions.count == 1
                ? "Season “\(title)” was accepted while you were away."
                : "\(versions.count) Season versions were accepted; the latest is “\(title)”."
        } else {
            summary = versions.count == 1
                ? "An accepted Season version changed while you were away."
                : "\(versions.count) accepted Season versions changed while you were away."
        }
        return try ReentryMaterialChange(
            id: latest.versionID,
            occurredAt: latest.acceptedAt,
            summary: summary,
            relevance: 1,
            sourceReferences: Array(versions.prefix(16).map(\.versionID))
        )
    }

    private func captureChange(
        _ input: NativeReentryInput,
        since lastSeenAt: Date
    ) throws -> ReentryMaterialChange? {
        let captures = input.recentCaptures.filter {
            $0.metadata.lastRevisedAt > lastSeenAt
                && $0.metadata.lastRevisedAt <= input.generatedAt
        }.sorted {
            if $0.metadata.lastRevisedAt != $1.metadata.lastRevisedAt {
                return $0.metadata.lastRevisedAt > $1.metadata.lastRevisedAt
            }
            return $0.metadata.id.description < $1.metadata.id.description
        }
        guard let latest = captures.first else { return nil }
        let needsClarification = captures.contains {
            $0.interpretationStatus == .needsClarification
        }
        let summary = captures.count == 1
            ? "One recent capture was added or reinterpreted locally."
            : "\(captures.count) recent captures were added or reinterpreted locally."
        return try ReentryMaterialChange(
            id: latest.metadata.id,
            occurredAt: latest.metadata.lastRevisedAt,
            summary: summary,
            relevance: 0.6,
            isUnresolved: needsClarification,
            clarificationQuestion: needsClarification
                ? "Would you like to review one capture that still needs clarification?"
                : nil,
            clarificationValue: needsClarification ? 0.8 : 0,
            sourceReferences: Array(captures.prefix(16).map(\.metadata.id))
        )
    }

    private func calendarChange(
        _ input: NativeReentryInput,
        since lastSeenAt: Date
    ) throws -> ReentryMaterialChange? {
        let items = try input.calendarSnapshot?.items.filter {
            guard let sourceVersion = $0.sourceVersion,
                  sourceVersion > lastSeenAt,
                  sourceVersion <= input.generatedAt
            else {
                return false
            }
            return try absoluteEnd($0) > input.generatedAt
        }.sorted {
            $0.identity.storageIdentifier < $1.identity.storageIdentifier
        } ?? []
        guard let occurredAt = items.compactMap(\.sourceVersion).max() else {
            return nil
        }
        let summary = items.count == 1
            ? "One known Calendar constraint changed while you were away."
            : "\(items.count) known Calendar constraints changed while you were away."
        let material = items.map {
            "\($0.identity.storageIdentifier):\($0.sourceVersion!.timeIntervalSince1970)"
        }.joined(separator: "|")
        return try ReentryMaterialChange(
            id: deterministicIdentifier(
                namespace: "calendar",
                occurredAt: occurredAt,
                material: material
            ),
            occurredAt: occurredAt,
            summary: summary,
            relevance: 0.8
        )
    }

    private func locationChange(
        _ input: NativeReentryInput,
        since lastSeenAt: Date
    ) throws -> ReentryMaterialChange? {
        guard let place = input.locationOverview?.cachedPlace,
              place.capturedAt > lastSeenAt,
              place.capturedAt <= input.generatedAt,
              place.expiresAt > input.generatedAt,
              place.timeZoneID != input.deviceTimeZoneID
        else {
            return nil
        }
        return try ReentryMaterialChange(
            id: deterministicIdentifier(
                namespace: "location",
                occurredAt: place.capturedAt,
                material: "\(place.placeIdentifier)|\(place.timeZoneID)"
            ),
            occurredAt: place.capturedAt,
            summary: "Current broad-place context now uses a different time zone.",
            relevance: 0.9
        )
    }

    private func absoluteEnd(_ item: CalendarMirrorItem) throws -> Date {
        switch item.interval.end {
        case let .instant(end):
            return end
        case let .localDate(end):
            guard let zone = TimeZone(identifier: item.timeZone.timeZoneID) else {
                throw NativeReentryError.invalidTimeZone
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = zone
            guard let endDate = calendar.date(from: DateComponents(
                timeZone: zone,
                year: end.year,
                month: end.month,
                day: end.day
            )) else {
                throw NativeReentryError.invalidClock
            }
            return endDate
        case nil:
            throw NativeReentryError.invalidClock
        }
    }

    private func deterministicIdentifier(
        namespace: String,
        occurredAt: Date,
        material: String
    ) throws -> UUIDv7 {
        let milliseconds = floor(occurredAt.timeIntervalSince1970 * 1_000)
        guard milliseconds >= 0,
              milliseconds <= Double(0x0000_ffff_ffff_ffff)
        else {
            throw NativeReentryError.invalidClock
        }
        let timestamp = String(format: "%012llx", UInt64(milliseconds))
        let digest = SHA256Digest.hexDigest(
            of: Data("\(namespace)|\(timestamp)|\(material)".utf8)
        )
        guard let variantSource = digest.dropFirst(3).first,
              let variantValue = Int(String(variantSource), radix: 16)
        else {
            throw NativeReentryError.invalidIdentifier
        }
        let variant = String(format: "%x", 8 + (variantValue & 0x3))
        let value = "\(timestamp.prefix(8))-\(timestamp.suffix(4))"
            + "-7\(digest.prefix(3))"
            + "-\(variant)\(digest.dropFirst(4).prefix(3))"
            + "-\(digest.dropFirst(7).prefix(12))"
        guard let identifier = UUID(uuidString: value) else {
            throw NativeReentryError.invalidIdentifier
        }
        return try UUIDv7(validating: identifier)
    }

    private func bounded(_ value: String, maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum - 1)) + "…"
    }
}
