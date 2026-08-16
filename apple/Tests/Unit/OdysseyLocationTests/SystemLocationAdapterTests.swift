#if !canImport(CoreLocation) || (!os(iOS) && !os(visionOS))
import OdysseyIntegrations
import OdysseyLocation
import Testing

@Test
func systemLocationAdapterFailsClosedOutsideSupportedAppleTargets() async {
    let adapter = SystemLocationAdapter.make()
    let capability = await adapter.capability()

    #expect(capability.availability == .unavailable)
    #expect(await adapter.authorizationState() == .unavailable)
    #expect(await adapter.requestWhenInUseAuthorization() == .unavailable)
}
#endif
