import Foundation

public enum SystemCalendarAdapter {
    public static func make() -> any CalendarContextProviding {
        #if canImport(EventKit)
        EventKitCalendarAdapter()
        #else
        UnavailableCalendarAdapter()
        #endif
    }
}
