import Foundation
import OdysseyApplication
import OdysseyCalendar
import OdysseyHealth
import OdysseyIntegrations
import Testing

private let activationFixtureDate = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func nativeIntegrationActivationRequiresDurablePriorOptIn() throws {
    let healthCapability = HealthImportCapability(
        availability: .available,
        supportedKinds: [.workout]
    )
    let revokedHealth = try HealthImportOverview(
        observedAt: activationFixtureDate,
        capability: healthCapability,
        permission: .partial,
        sampleCountByKind: [:],
        newestSourceTimestamp: nil,
        cursorKindCount: 0
    )
    let activeHealth = try HealthImportOverview(
        observedAt: activationFixtureDate,
        capability: healthCapability,
        permission: .partial,
        sampleCountByKind: [:],
        newestSourceTimestamp: nil,
        cursorKindCount: 1
    )
    let calendarCapability = CalendarMirrorCapability(
        availability: .available,
        supportsFullAccessRead: true
    )
    let revokedCalendar = try CalendarMirrorOverview(
        observedAt: activationFixtureDate,
        capability: calendarCapability,
        permission: .authorized,
        localItemCount: 0,
        lastSuccessfulRefreshAt: nil,
        newestSourceVersion: nil,
        lastWindow: nil
    )
    let activeCalendar = try CalendarMirrorOverview(
        observedAt: activationFixtureDate,
        capability: calendarCapability,
        permission: .authorized,
        localItemCount: 0,
        lastSuccessfulRefreshAt: activationFixtureDate,
        newestSourceVersion: nil,
        lastWindow: CalendarQueryWindow(
            startDate: activationFixtureDate,
            endDate: activationFixtureDate.addingTimeInterval(86_400),
            timeZoneID: "UTC"
        )
    )

    #expect(!NativeIntegrationActivationPolicy.shouldResumeHealthImport(nil))
    #expect(!NativeIntegrationActivationPolicy.shouldResumeHealthImport(revokedHealth))
    #expect(NativeIntegrationActivationPolicy.shouldResumeHealthImport(activeHealth))
    #expect(!NativeIntegrationActivationPolicy.shouldResumeCalendarMirror(nil))
    #expect(!NativeIntegrationActivationPolicy.shouldResumeCalendarMirror(revokedCalendar))
    #expect(NativeIntegrationActivationPolicy.shouldResumeCalendarMirror(activeCalendar))
}
