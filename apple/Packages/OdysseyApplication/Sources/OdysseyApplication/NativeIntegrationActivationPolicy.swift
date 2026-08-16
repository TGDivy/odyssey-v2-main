import OdysseyCalendar
import OdysseyHealth

public enum NativeIntegrationActivationPolicy {
    public static func shouldResumeHealthImport(
        _ overview: HealthImportOverview?
    ) -> Bool {
        guard let overview,
              overview.capability.availability == .available,
              overview.permission == .authorized || overview.permission == .partial
        else {
            return false
        }
        return overview.cursorKindCount > 0
    }

    public static func shouldResumeCalendarMirror(
        _ overview: CalendarMirrorOverview?
    ) -> Bool {
        guard let overview,
              overview.capability.availability == .available,
              overview.capability.supportsFullAccessRead,
              overview.permission == .authorized
        else {
            return false
        }
        return overview.lastWindow != nil
    }
}
