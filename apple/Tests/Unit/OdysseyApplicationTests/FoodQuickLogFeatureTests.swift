import Foundation
import OdysseyApplication
import OdysseyDomain
import Testing

private let quickLogDate = Date(timeIntervalSince1970: 1_786_752_000)

@Test
func foodQuickLogProjectorRanksFourAndKeepsSearchListStable() throws {
    let oats = try quickLogPreset(id: 1, name: "Oats")
    let apple = try quickLogPreset(id: 2, name: "Apple")
    let tea = try quickLogPreset(id: 3, name: "Tea")
    let yogurt = try quickLogPreset(id: 4, name: "Yogurt")
    let coffee = try quickLogPreset(id: 5, name: "Coffee")
    let usageContext = try FoodPresetRankingContext(
        occurredAt: quickLogDate.addingTimeInterval(-3_600),
        timeZoneID: "UTC"
    )
    let usages = try [1, 2].map { value in
        try FoodPresetUsage(
            usageID: quickLogIdentifier(100 + value),
            presetID: coffee.metadata.id,
            occurredAt: quickLogDate.addingTimeInterval(Double(-value * 3_600)),
            context: usageContext
        )
    }

    let snapshot = try FoodQuickLogProjector.project(
        presets: [tea, yogurt, coffee, oats, apple],
        usages: usages,
        recentOccurrences: [],
        at: quickLogDate,
        timeZoneID: "UTC"
    )

    #expect(snapshot.activePresets.map(\.name) == ["Apple", "Coffee", "Oats", "Tea", "Yogurt"])
    #expect(snapshot.rankedPresets.count == 4)
    #expect(snapshot.rankedPresets.first?.preset == coffee)
    #expect(snapshot.rankedPresets.first?.reason == .oftenInSimilarContext)
}

@Test
func applicationReducerOwnsFoodLoadingMutationAndFailureLifecycle() throws {
    var state = ApplicationFeatureState()
    let snapshot = FoodQuickLogSnapshot(
        activePresets: [],
        rankedPresets: [],
        recentOccurrences: [],
        generatedAt: quickLogDate,
        timeZoneID: "UTC"
    )

    ApplicationFeatureReducer.reduce(state: &state, action: .foodLoadStarted)
    #expect(state.foodPhase == .idle)

    ApplicationFeatureReducer.reduce(state: &state, action: .localReady)
    ApplicationFeatureReducer.reduce(state: &state, action: .foodLoadStarted)
    #expect(state.foodPhase == .loading)
    ApplicationFeatureReducer.reduce(state: &state, action: .foodLoaded(snapshot))
    #expect(state.foodPhase == .ready)
    #expect(state.canUseFoodQuickLog)

    ApplicationFeatureReducer.reduce(state: &state, action: .foodMutationStarted)
    #expect(state.foodPhase == .saving)
    #expect(!state.canUseFoodQuickLog)
    let occurrenceID = try quickLogIdentifier(200)
    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .foodMutationSucceeded(
            .occurrenceRecorded(occurrenceID, at: quickLogDate),
            snapshot
        )
    )
    #expect(
        state.foodPhase == .succeeded(
            .occurrenceRecorded(occurrenceID, at: quickLogDate)
        )
    )
    ApplicationFeatureReducer.reduce(state: &state, action: .foodDismissed)
    #expect(state.foodPhase == .ready)

    ApplicationFeatureReducer.reduce(state: &state, action: .foodLoadStarted)
    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .foodFailed("The food library could not be read safely.")
    )
    #expect(state.foodPhase == .failed("The food library could not be read safely."))
    ApplicationFeatureReducer.reduce(
        state: &state,
        action: .localUnavailable("Local storage failed safely.")
    )
    #expect(state.foodPhase == .idle)
    #expect(state.foodSnapshot == nil)
}

private func quickLogPreset(id: Int, name: String) throws -> FoodPreset {
    try FoodPreset(
        metadata: EntityMetadata(
            id: quickLogIdentifier(id),
            createdAt: quickLogDate.addingTimeInterval(-86_400),
            createdBy: ActorRef(actorType: .user, actorID: "owner"),
            lastRevisedAt: quickLogDate.addingTimeInterval(-86_400),
            revision: 1,
            sensitivity: .sensitive,
            provenanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        ),
        name: name,
        servingDescription: "1 serving"
    )
}

private func quickLogIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
