import Foundation
import OdysseyApplication
import OdysseyCalendar
import OdysseyData
import OdysseyDomain
import OdysseyIntegrations
import OdysseyIntelligence
import OdysseyLocation
import Testing

private let nativeReentryNow = Date(timeIntervalSince1970: 1_786_867_200)

@Test
func nativeReentryRequiresARecordedThreeDayAbsence() throws {
    let projector = NativeReentryProjector()
    let firstVisit = try NativeReentryInput(
        lastSeenAt: nil,
        generatedAt: nativeReentryNow,
        deviceTimeZoneID: "UTC"
    )
    let shortAbsence = try NativeReentryInput(
        lastSeenAt: nativeReentryNow.addingTimeInterval(-2 * 24 * 60 * 60),
        generatedAt: nativeReentryNow,
        deviceTimeZoneID: "UTC"
    )

    #expect(try projector.project(firstVisit) == nil)
    #expect(try projector.project(shortAbsence) == nil)
}

@Test
func nativeReentryRanksBoundedMaterialChangesWithStableIdentifiers() throws {
    let lastSeen = nativeReentryNow.addingTimeInterval(-4 * 24 * 60 * 60)
    let season = try nativeReentrySeasonVersion(
        acceptedAt: nativeReentryNow.addingTimeInterval(-2 * 60 * 60)
    )
    let calendarItem = try nativeReentryCalendarItem(
        sourceVersion: nativeReentryNow.addingTimeInterval(-60 * 60)
    )
    let location = try nativeReentryLocationOverview(
        capturedAt: nativeReentryNow.addingTimeInterval(-30 * 60)
    )
    let input = try NativeReentryInput(
        lastSeenAt: lastSeen,
        generatedAt: nativeReentryNow,
        deviceTimeZoneID: "UTC",
        acceptedSeasonVersions: [season],
        recentCaptures: [try nativeReentryCapture(
            revisedAt: nativeReentryNow.addingTimeInterval(-90 * 60)
        )],
        calendarSnapshot: CalendarLocalSnapshot(
            items: [calendarItem],
            lastWindow: nil,
            lastQueriedAt: nativeReentryNow
        ),
        locationOverview: location
    )

    let firstProjection = try NativeReentryProjector().project(input)
    let secondProjection = try NativeReentryProjector().project(input)
    let first = try #require(firstProjection)
    let second = try #require(secondProjection)

    #expect(first.summary.count == 3)
    #expect(first.summary.map(\.summary) == [
        "An accepted Season version changed while you were away.",
        "Current broad-place context now uses a different time zone.",
        "One known Calendar constraint changed while you were away.",
    ])
    #expect(first.summary.map(\.changeID) == second.summary.map(\.changeID))
    #expect(first.summary[0].changeID == season.versionID)
    #expect(first.oneQuestion
        == "Would you like to review one capture that still needs clarification?")
    #expect(first.options == [.continue, .reviseSeason, .stayQuiet])
    #expect(first.suppressBacklog)
    #expect(first.noAbsencePenalty)
}

@Test
func nativeReentryCaptureSummaryDoesNotExposeOriginalPayload() throws {
    let capture = try nativeReentryCapture(
        revisedAt: nativeReentryNow.addingTimeInterval(-60 * 60)
    )
    let input = try NativeReentryInput(
        lastSeenAt: nativeReentryNow.addingTimeInterval(-4 * 24 * 60 * 60),
        generatedAt: nativeReentryNow,
        deviceTimeZoneID: "UTC",
        recentCaptures: [capture]
    )

    let projection = try NativeReentryProjector().project(input)
    let surface = try #require(projection)

    #expect(surface.summary.map(\.summary)
        == ["One recent capture was added or reinterpreted locally."])
    #expect(!surface.summary[0].summary.contains("private test note"))
    #expect(surface.summary[0].sourceReferences == [capture.metadata.id])
    #expect(surface.oneQuestion
        == "Would you like to review one capture that still needs clarification?")
}

private func nativeReentrySeasonVersion(
    acceptedAt: Date
) throws -> CachedLifeModelVersion {
    let document = Data("{}".utf8)
    return try CachedLifeModelVersion(
        kind: .season,
        versionID: nativeReentryIdentifier(1),
        logicalID: nativeReentryIdentifier(2),
        versionNumber: 1,
        acceptanceSequence: 1,
        supersedesVersionID: nil,
        status: "active",
        acceptanceMethod: .ownerAuthored,
        acceptedAt: acceptedAt,
        contentHash: SHA256Digest.hexDigest(of: document),
        document: document,
        eventID: nativeReentryIdentifier(3),
        ledgerSequence: 1,
        policyVersion: "test.v1",
        cachedAt: acceptedAt
    )
}

private func nativeReentryCapture(revisedAt: Date) throws -> CaptureRecord {
    let identifier = try nativeReentryIdentifier(10)
    return CaptureRecord(
        metadata: try EntityMetadata(
            id: identifier,
            createdAt: revisedAt.addingTimeInterval(-60),
            createdBy: ActorRef(actorType: .user, actorID: "owner"),
            lastRevisedAt: revisedAt,
            revision: 2,
            sensitivity: .private,
            provenanceID: UUID(uuidString: "018f0000-0000-4000-8000-000000000010")!
        ),
        capturedAt: revisedAt.addingTimeInterval(-60),
        originalPayload: CaptureOriginalPayload(
            kind: .text,
            contentOrObjectRef: "private test note",
            contentHash: String(repeating: "0", count: 64)
        ),
        initialContext: CaptureInitialContext(
            deviceID: try nativeReentryIdentifier(11),
            timeZoneID: "UTC",
            locationPermissionState: .unavailable,
            broadLocation: nil,
            invokingSurface: .iPhoneNow
        ),
        attachments: [],
        interpretationStatus: .needsClarification,
        interpretationVersions: []
    )
}

private func nativeReentryCalendarItem(
    sourceVersion: Date
) throws -> CalendarMirrorItem {
    try CalendarMirrorItem(
        identity: CalendarEventIdentity(eventIdentifier: "reentry-calendar-item"),
        title: "Private calendar title",
        interval: TemporalInterval(
            start: .instant(nativeReentryNow.addingTimeInterval(60 * 60)),
            end: .instant(nativeReentryNow.addingTimeInterval(2 * 60 * 60)),
            timeZoneID: "UTC",
            startPrecision: .exact,
            endPrecision: .exact
        ),
        source: CalendarSourceMetadata(
            calendarIdentifier: "synthetic",
            calendarTitle: "Synthetic",
            sourceIdentifier: "synthetic",
            sourceTitle: "Synthetic",
            sourceKind: .local,
            allowsContentModifications: false
        ),
        sourceVersion: sourceVersion,
        status: .confirmed,
        availability: .busy,
        timeZone: CalendarTimeZoneContext(
            timeZoneID: "UTC",
            source: .event,
            startUTCOffsetSeconds: 0,
            endUTCOffsetSeconds: 0
        ),
        hasRecurrenceRules: false
    )
}

private func nativeReentryLocationOverview(
    capturedAt: Date
) throws -> LocationContextOverview {
    let place = try BroadLocationContext(
        placeIdentifier: "synthetic_tokyo",
        displayName: "Synthetic Tokyo",
        timeZoneID: "Asia/Tokyo",
        capturedAt: capturedAt,
        expiresAt: nativeReentryNow.addingTimeInterval(60 * 60),
        precision: .locality
    )
    return try LocationContextOverview(
        observedAt: nativeReentryNow,
        capability: LocationContextCapability(
            availability: .available,
            supportsForegroundBroadPlace: true,
            supportsSignificantChanges: false
        ),
        permission: .authorized,
        cachedPlace: place,
        cacheIsFresh: true,
        lastAttemptAt: capturedAt,
        lastSuccessfulRefreshAt: capturedAt,
        lastOutcome: .acquired,
        rejectedRecordCount: 0
    )
}

private func nativeReentryIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
