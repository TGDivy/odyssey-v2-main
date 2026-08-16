import Foundation
import OdysseyDomain
import OdysseyHealth
import Testing

private let healthWriteDate = Date(timeIntervalSince1970: 1_786_752_000)

@Test
func foodHealthPlanUsesExactSupportedUnitsAndReportsAlcoholOmission() throws {
    let occurrence = try healthOccurrence(revision: 1, energy: 420, protein: 31)
    let plan = FoodHealthWritePlan(occurrence: occurrence)

    #expect(plan.samples.map(\.kind) == [
        .energyKilocalories,
        .proteinGrams,
        .caffeineMilligrams,
    ])
    #expect(plan.samples.map(\.value) == [420, 31, 95])
    #expect(plan.samples.allSatisfy { $0.occurrenceID == occurrence.metadata.id })
    #expect(plan.samples.allSatisfy { $0.occurrenceRevision == 1 })
    #expect(plan.omittedAlcoholGrams == 12)
}

@Test
func foodHealthCoordinatorRequiresPermissionAndReplacesIdempotently() async throws {
    let writer = FakeFoodHealthWriter(state: .notDetermined)
    let coordinator = FoodHealthWriteCoordinator(writer: writer)
    let first = try healthOccurrence(revision: 1, energy: 420, protein: 31)

    #expect(try await coordinator.writeIfAuthorized(first) == .authorizationRequired)
    #expect(await writer.replaceCount == 0)
    #expect(
        try await coordinator.requestAuthorization(for: FoodHealthWritePlan(
            occurrence: first
        ).nutrientKinds) == .authorized
    )
    #expect(
        try await coordinator.writeIfAuthorized(first)
            == .written(sampleCount: 3, omittedAlcoholGrams: 12)
    )
    #expect(
        try await coordinator.writeIfAuthorized(first)
            == .written(sampleCount: 3, omittedAlcoholGrams: 12)
    )
    #expect(await writer.replaceCount == 2)
    #expect(await writer.sampleCount(for: first.metadata.id) == 3)

    let corrected = try healthOccurrence(revision: 2, energy: 500, protein: 40)
    _ = try await coordinator.writeIfAuthorized(corrected)
    let storedEnergy = await writer.sample(
        occurrenceID: corrected.metadata.id,
        kind: .energyKilocalories
    )
    #expect(storedEnergy?.value == 500)
    #expect(storedEnergy?.occurrenceRevision == 2)
    #expect(await writer.sampleCount(for: corrected.metadata.id) == 3)

    await writer.setAuthorizationState(.denied)
    let deniedCorrection = try healthOccurrence(
        revision: 3,
        energy: 510,
        protein: 41
    )
    #expect(
        try await coordinator.writeIfAuthorized(
            deniedCorrection,
            replacingExisting: true
        ) == .denied
    )
    #expect(await writer.sampleCount(for: corrected.metadata.id) == 0)
    await writer.setAuthorizationState(.authorized)
    _ = try await coordinator.writeIfAuthorized(deniedCorrection)

    let alcoholOnly = try healthOccurrence(
        revision: 4,
        energy: nil,
        protein: nil,
        caffeine: nil
    )
    #expect(
        try await coordinator.writeIfAuthorized(
            alcoholOnly,
            replacingExisting: true
        ) == .written(sampleCount: 0, omittedAlcoholGrams: 12)
    )
    #expect(await writer.sampleCount(for: corrected.metadata.id) == 0)

    #expect(
        try await coordinator.deleteOwnedSamples(occurrenceID: corrected.metadata.id)
            == .deleted
    )
    #expect(await writer.sampleCount(for: corrected.metadata.id) == 0)
}

private actor FakeFoodHealthWriter: FoodHealthSampleWriting {
    private var state: FoodHealthAuthorizationState
    private var stored = [UUIDv7: [FoodHealthNutrientKind: FoodHealthSample]]()
    private(set) var replaceCount = 0

    init(state: FoodHealthAuthorizationState) {
        self.state = state
    }

    func authorizationState(
        for _: Set<FoodHealthNutrientKind>
    ) async -> FoodHealthAuthorizationState {
        state
    }

    func requestAuthorization(
        for _: Set<FoodHealthNutrientKind>
    ) async throws -> FoodHealthAuthorizationState {
        state = .authorized
        return state
    }

    func setAuthorizationState(_ state: FoodHealthAuthorizationState) {
        self.state = state
    }

    func replaceOwnedSamples(
        occurrenceID: UUIDv7,
        with samples: [FoodHealthSample]
    ) async throws {
        replaceCount += 1
        stored[occurrenceID] = Dictionary(
            uniqueKeysWithValues: samples.map { ($0.kind, $0) }
        )
    }

    func deleteOwnedSamples(occurrenceID: UUIDv7) async throws {
        stored[occurrenceID] = nil
    }

    func sampleCount(for occurrenceID: UUIDv7) -> Int {
        stored[occurrenceID]?.count ?? 0
    }

    func sample(
        occurrenceID: UUIDv7,
        kind: FoodHealthNutrientKind
    ) -> FoodHealthSample? {
        stored[occurrenceID]?[kind]
    }
}

private func healthOccurrence(
    revision: Int,
    energy: Double?,
    protein: Double?,
    caffeine: Double? = 95
) throws -> FoodOccurrence {
    let occurredAt = healthWriteDate.addingTimeInterval(-3_600)
    let revisedAt = healthWriteDate.addingTimeInterval(Double(revision))
    return try FoodOccurrence(
        metadata: EntityMetadata(
            id: healthIdentifier(1),
            createdAt: healthWriteDate,
            createdBy: ActorRef(actorType: .user, actorID: "owner"),
            lastRevisedAt: revisedAt,
            revision: revision,
            sensitivity: .sensitive,
            provenanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        ),
        presetID: healthIdentifier(2),
        presetRevision: revision,
        presetNameSnapshot: "Lunch",
        servingDescriptionSnapshot: "1 bowl",
        quantity: 1,
        nutrientTotals: FoodNutrientProfile(
            energyKilocalories: energy,
            proteinGrams: protein,
            caffeineMilligrams: caffeine,
            alcoholGrams: 12,
            sourceKind: .ownerEstimate
        ),
        occurredAt: occurredAt,
        timeZoneID: "UTC",
        originalUTCOffsetSeconds: 0
    )
}

private func healthIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
