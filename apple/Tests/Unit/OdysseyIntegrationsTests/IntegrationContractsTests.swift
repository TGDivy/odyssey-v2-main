import Foundation
import OdysseyIntegrations
import Testing

private let integrationObservedAt = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func capabilityMatrixIsPerDeviceAndRejectsDuplicateCapabilities() throws {
    let deniedHealth = IntegrationCapabilityStatus(
        capability: .healthSampleRead,
        availability: .available,
        permission: .denied
    )
    let matrix = try DeviceCapabilityMatrix(
        generatedAt: integrationObservedAt,
        device: .iPhone,
        capabilities: [
            IntegrationCapabilityStatus(
                capability: .foregroundLocation,
                availability: .available,
                permission: .notDetermined
            ),
            deniedHealth,
        ]
    )

    #expect(matrix.device == .iPhone)
    #expect(matrix.status(for: .healthSampleRead) == deniedHealth)
    #expect(matrix.capabilities.map(\.capability) == [
        .foregroundLocation,
        .healthSampleRead,
    ])
    #expect(throws: IntegrationContractError.duplicateCapability) {
        try DeviceCapabilityMatrix(
            generatedAt: integrationObservedAt,
            device: .iPhone,
            capabilities: [deniedHealth, deniedHealth]
        )
    }
}

@Test
func integrationHealthDerivesLagAndValidatesConnectorMeaning() throws {
    let snapshot = try IntegrationHealthSnapshot(
        connector: .calendar,
        observedAt: integrationObservedAt,
        operationalState: .degraded,
        permission: .denied,
        lastSuccessfulSync: nil,
        newestSourceTimestamp: integrationObservedAt.addingTimeInterval(-300),
        rejectedRecordCount: 2,
        revocationSupported: true,
        contribution: .calendarConstraints
    )

    #expect(snapshot.lag == 300)
    #expect(snapshot.permission == .denied)
    #expect(throws: IntegrationContractError.mismatchedContribution) {
        try IntegrationHealthSnapshot(
            connector: .weather,
            observedAt: integrationObservedAt,
            operationalState: .idle,
            permission: .notRequired,
            lastSuccessfulSync: nil,
            newestSourceTimestamp: nil,
            revocationSupported: false,
            contribution: .broadForegroundPlace
        )
    }
}

@Test
func integrationHealthCatalogRoundTripsAndRejectsDuplicateConnectors() throws {
    let snapshot = try IntegrationHealthSnapshot(
        connector: .location,
        observedAt: integrationObservedAt,
        operationalState: .healthy,
        permission: .authorized,
        lastSuccessfulSync: integrationObservedAt,
        newestSourceTimestamp: integrationObservedAt,
        revocationSupported: true,
        contribution: .broadForegroundPlace
    )
    let catalog = try IntegrationHealthCatalog(snapshots: [snapshot])
    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(IntegrationHealthCatalog.self, from: data)

    #expect(decoded == catalog)
    #expect(decoded.snapshot(for: .location) == snapshot)
    #expect(throws: IntegrationContractError.duplicateConnector) {
        try IntegrationHealthCatalog(snapshots: [snapshot, snapshot])
    }
}
