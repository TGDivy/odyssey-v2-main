import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

@Test
func applicationReducerKeepsOfflineCaptureIndependentFromRemoteReadiness() throws {
    var state = ApplicationFeatureState()
    ApplicationFeatureReducer.reduce(state: &state, action: .bootstrapStarted)
    ApplicationFeatureReducer.reduce(state: &state, action: .localReady)
    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .remoteUnavailable("Remote configuration is unavailable.")
    )

    #expect(state.canCapture)
    #expect(!state.canSynchronize)

    let captureID = try servicesIdentifierForReducer(1)
    let capturedAt = Date(timeIntervalSince1970: 1_730_000_000)
    ApplicationFeatureReducer.reduce(state: &state, action: .captureStarted)
    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .captureSucceeded(captureID: captureID, at: capturedAt)
    )

    #expect(state.capturePhase == .saved(captureID: captureID, at: capturedAt))
    #expect(state.remoteReadiness == .unavailable("Remote configuration is unavailable."))
}

@Test
func applicationReducerAllowsSyncOnlyAfterCredentialIsStored() throws {
    var state = ApplicationFeatureState()
    ApplicationFeatureReducer.reduce(state: &state, action: .localReady)
    ApplicationFeatureReducer.reduce(state: &state, action: .remoteReady)
    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .enrollmentObserved(stored: false)
    )
    ApplicationFeatureReducer.reduce(state: &state, action: .syncStarted)
    #expect(state.syncPhase == .idle)

    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .enrollmentObserved(stored: true)
    )
    ApplicationFeatureReducer.reduce(state: &state, action: .syncStarted)
    #expect(state.syncPhase == .synchronizing)

    let report = SyncRunReport(
        pushedOperationCount: 1,
        pulledChangeCount: 2,
        conflictCount: 0,
        finalCursor: try SyncCursor(value: 2),
        completedAt: Date(timeIntervalSince1970: 1_730_000_001)
    )
    ApplicationFeatureReducer.reduce(state: &state, action: .syncSucceeded(report))
    #expect(state.syncPhase == .succeeded(report))
}

@Test
func applicationReducerOwnsWorkshopLoadingAndDeliveryLifecycle() {
    var state = ApplicationFeatureState()
    let snapshot = emptyWorkshopSnapshot()

    ApplicationFeatureReducer.reduce(state: &state, action: .workshopLoadStarted)
    #expect(state.workshopPhase == .idle)

    ApplicationFeatureReducer.reduce(state: &state, action: .localReady)
    ApplicationFeatureReducer.reduce(state: &state, action: .workshopLoadStarted)
    #expect(state.workshopPhase == .loading)
    #expect(!state.canUseWorkshop)

    ApplicationFeatureReducer.reduce(state: &state, action: .workshopLoaded(snapshot))
    #expect(state.workshopPhase == .ready)
    #expect(state.workshopSnapshot == snapshot)
    #expect(state.canUseWorkshop)

    ApplicationFeatureReducer.reduce(state: &state, action: .workshopDeliveryStarted)
    #expect(state.workshopPhase == .delivering)
    #expect(!state.canUseWorkshop)

    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .workshopDeliveryFinished(snapshot)
    )
    #expect(state.workshopPhase == .ready)
    #expect(state.canUseWorkshop)
}

@Test
func applicationReducerClearsWorkshopStateWhenLocalStorageFails() {
    var state = ApplicationFeatureState(localReadiness: .ready)
    let snapshot = emptyWorkshopSnapshot()
    ApplicationFeatureReducer.reduce(state: &state, action: .workshopLoadStarted)
    ApplicationFeatureReducer.reduce(state: &state, action: .workshopLoaded(snapshot))
    ApplicationFeatureReducer.reduce(state: &state, action: .workshopSaveStarted)
    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .localUnavailable("Local storage failed safely.")
    )

    #expect(state.workshopPhase == .idle)
    #expect(state.workshopSnapshot == nil)
    #expect(state.workshopReview == nil)
    #expect(!state.canUseWorkshop)
}

@Test
func applicationReducerRequiresPreparedReviewBeforeQueueing() throws {
    var state = ApplicationFeatureState(localReadiness: .ready)
    let snapshot = emptyWorkshopSnapshot()
    ApplicationFeatureReducer.reduce(state: &state, action: .workshopLoadStarted)
    ApplicationFeatureReducer.reduce(state: &state, action: .workshopLoaded(snapshot))
    ApplicationFeatureReducer.reduce(state: &state, action: .workshopQueueStarted)
    #expect(state.workshopPhase == .ready)

    let timestamp = Date(timeIntervalSince1970: 1_730_000_002)
    let proposal = try LifeModelWorkshopDraftFactory(
        timeZoneID: "UTC",
        clock: { timestamp }
    ).initialCharter()
    let draft = try LifeModelDraftRecord(
        draftID: servicesIdentifierForReducer(50),
        kind: proposal.kind,
        versionID: proposal.versionID,
        logicalID: proposal.logicalID,
        versionNumber: proposal.versionNumber,
        baseVersionID: proposal.baseVersionID,
        acceptanceMethod: proposal.acceptanceMethod,
        document: proposal.document,
        contentRevision: 1,
        stateRevision: 1,
        phase: .editing,
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let review = LifeModelDraftReview(
        draft: draft,
        changes: [],
        warnings: [],
        reviewDigest: String(repeating: "a", count: 64)
    )

    ApplicationFeatureReducer.reduce(state: &state, action: .workshopReviewStarted)
    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .workshopReviewPrepared(review: review, snapshot: snapshot)
    )
    #expect(state.workshopReview == review)
    ApplicationFeatureReducer.reduce(state: &state, action: .workshopQueueStarted)
    #expect(state.workshopPhase == .queueing)
    ApplicationFeatureReducer.reduce(state: &state, action: .workshopQueued(snapshot))
    #expect(state.workshopPhase == .ready)
    #expect(state.workshopReview == nil)
}

private func emptyWorkshopSnapshot() -> LifeModelWorkshopSnapshot {
    LifeModelWorkshopSnapshot(
        drafts: [],
        acceptanceCommands: [],
        acceptedVersions: [],
        queueDiagnostics: LifeModelQueueDiagnostics(
            queuedCount: 0,
            conflictCount: 0,
            rejectedCount: 0,
            oldestQueuedAt: nil
        )
    )
}

private func servicesIdentifierForReducer(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
