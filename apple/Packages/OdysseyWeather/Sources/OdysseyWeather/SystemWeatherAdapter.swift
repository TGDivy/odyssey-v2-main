import Foundation

public enum SystemWeatherAdapter {
    public static func make() -> any WeatherContextProviding {
        #if canImport(WeatherKit) && canImport(CoreLocation)
        WeatherKitAdapter()
        #else
        UnavailableWeatherAdapter()
        #endif
    }
}
