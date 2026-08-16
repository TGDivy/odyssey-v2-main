import Foundation
import OdysseyApplication
import OdysseyCalendar
import OdysseyHealth
import OdysseyIntegrations
import OdysseyLocation
import OdysseyWeather
import Testing

private let capabilityFixtureDate = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func nativeCapabilityMatrixCombinesRuntimeSupportPermissionAndPolicy() throws {
    let matrix = try NativeIntegrationCapabilityMatrix.make(
        generatedAt: capabilityFixtureDate,
        device: .iPad,
        health: HealthImportOverview(
            observedAt: capabilityFixtureDate,
            capability: HealthImportCapability(
                availability: .available,
                supportedKinds: [.workout]
            ),
            permission: .partial,
            sampleCountByKind: [:],
            newestSourceTimestamp: nil
        ),
        healthNutrientWritePermission: .denied,
        calendar: CalendarMirrorOverview(
            observedAt: capabilityFixtureDate,
            capability: CalendarMirrorCapability(
                availability: .available,
                supportsFullAccessRead: true
            ),
            permission: .authorized,
            localItemCount: 0,
            lastSuccessfulRefreshAt: nil,
            newestSourceVersion: nil,
            lastWindow: nil
        ),
        weather: WeatherMirrorOverview(
            observedAt: capabilityFixtureDate,
            capability: WeatherMirrorCapability(
                availability: .available,
                supportsCurrentConditions: true,
                supportsHourlyForecast: false,
                supportsDailyForecast: false
            ),
            permission: .notRequired,
            cachedPlace: nil,
            cacheIsFresh: false,
            lastAttemptAt: nil,
            lastSuccessfulRefreshAt: nil,
            newestSourceTimestamp: nil,
            expiresAt: nil,
            lastOutcome: nil,
            rateLimitState: .notApplicable,
            rejectedRecordCount: 0,
            attribution: nil
        ),
        location: LocationContextOverview(
            observedAt: capabilityFixtureDate,
            capability: LocationContextCapability(
                availability: .available,
                supportsForegroundBroadPlace: true,
                supportsSignificantChanges: false
            ),
            permission: .notDetermined,
            cachedPlace: nil,
            cacheIsFresh: false,
            lastAttemptAt: nil,
            lastSuccessfulRefreshAt: nil,
            lastOutcome: nil,
            rejectedRecordCount: 0
        )
    )

    #expect(matrix.device == .iPad)
    #expect(matrix.capabilities.count == IntegrationCapability.allCases.count)
    #expect(matrix.status(for: .healthSampleRead)?.permission == .partial)
    #expect(matrix.status(for: .healthNutrientWrite)?.permission == .denied)
    #expect(matrix.status(for: .calendarRead)?.availability == .available)
    #expect(matrix.status(for: .calendarWrite)?.availability == .disabledByPolicy)
    #expect(matrix.status(for: .currentWeather)?.availability == .available)
    #expect(matrix.status(for: .weatherForecast)?.availability == .unsupported)
    #expect(matrix.status(for: .foregroundLocation)?.permission == .notDetermined)
    #expect(matrix.status(for: .significantLocation)?.availability == .disabledByPolicy)
}

@Test
func nativeCapabilityMatrixReportsUninspectedAdaptersAsUnavailable() throws {
    let matrix = try NativeIntegrationCapabilityMatrix.make(
        generatedAt: capabilityFixtureDate,
        device: .iPhone,
        health: nil,
        healthNutrientWritePermission: .unavailable,
        calendar: nil,
        weather: nil,
        location: nil
    )

    for capability in IntegrationCapability.allCases
        where capability != .calendarWrite && capability != .significantLocation
    {
        #expect(matrix.status(for: capability)?.availability == .unavailable)
        #expect(matrix.status(for: capability)?.permission == .unavailable)
    }
    #expect(matrix.status(for: .calendarWrite)?.availability == .disabledByPolicy)
    #expect(matrix.status(for: .significantLocation)?.availability == .disabledByPolicy)
}
