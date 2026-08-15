import Foundation
import OdysseyApplication
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

private func servicesIdentifierForReducer(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
