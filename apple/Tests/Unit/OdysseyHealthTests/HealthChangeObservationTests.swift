import OdysseyHealth
import OdysseyIntegrations
import Testing

@Test
func healthChangeObservationIsExplicitScopedAndStoppedByRevocation() async throws {
    let adapter = SyntheticHealthImportAdapter(
        capability: HealthImportCapability(
            availability: .available,
            supportedKinds: [.workout, .sleepAnalysis]
        ),
        initialPermission: .partial,
        authorizationAfterRequest: .partial
    )
    let coordinator = HealthImportCoordinator(
        importer: adapter,
        store: SyntheticIntegrationLocalStore()
    )
    let recorder = ObservedHealthKindRecorder()

    let state = try await coordinator.startChangeObservation(
        for: [.workout, .sleepAnalysis]
    ) { kind in
        await recorder.record(kind)
    }
    #expect(state == .active)
    #expect(await adapter.emitObservedChange(for: .workout))
    #expect(await recorder.kinds() == [.workout])
    #expect(try await coordinator.overview().changeObservationState == .active)

    #expect(try await coordinator.revokeLocalHealthData() == 0)
    #expect(await adapter.changeObservationState() == .inactive)
    #expect(!(await adapter.emitObservedChange(for: .sleepAnalysis)))
    #expect(await recorder.kinds() == [.workout])
}

@Test
func healthChangeObservationRejectsUnsupportedKinds() async throws {
    let adapter = SyntheticHealthImportAdapter(
        capability: HealthImportCapability(
            availability: .available,
            supportedKinds: [.workout]
        ),
        initialPermission: .partial,
        authorizationAfterRequest: .partial
    )
    let coordinator = HealthImportCoordinator(
        importer: adapter,
        store: SyntheticIntegrationLocalStore()
    )

    await #expect(throws: HealthImportError.invalidObservation) {
        try await coordinator.startChangeObservation(for: [.heartRate]) { _ in }
    }
    #expect(await adapter.changeObservationState() == .inactive)
}

private actor ObservedHealthKindRecorder {
    private var recordedKinds = [HealthSampleKind]()

    func record(_ kind: HealthSampleKind) {
        recordedKinds.append(kind)
    }

    func kinds() -> [HealthSampleKind] {
        recordedKinds
    }
}
