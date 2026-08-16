#if !canImport(WeatherKit) || !canImport(CoreLocation)
import OdysseyIntegrations
import OdysseyWeather
import Testing

@Test
func systemWeatherAdapterFailsClosedWithoutWeatherKit() async {
    let adapter = SystemWeatherAdapter.make()
    let capability = await adapter.capability()

    #expect(capability.availability == .unavailable)
    #expect(await adapter.permissionState() == .notRequired)
}
#endif
