public enum SystemLocationAdapter {
    public static func make() -> any LocationContextProviding {
        #if canImport(CoreLocation) && (os(iOS) || os(visionOS))
        CoreLocationAdapter()
        #else
        UnavailableLocationAdapter()
        #endif
    }
}
