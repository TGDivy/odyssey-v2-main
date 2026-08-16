import Foundation
import OdysseyCalendar
import OdysseyHealth
import OdysseyIntegrations
import OdysseyLocation
import OdysseyWeather

public enum NativeIntegrationCapabilityMatrix {
    public static func make(
        generatedAt: Date = Date(),
        device: IntegrationDeviceKind,
        health: HealthImportOverview?,
        healthNutrientWritePermission: IntegrationPermissionState,
        calendar: CalendarMirrorOverview?,
        weather: WeatherMirrorOverview?,
        location: LocationContextOverview?
    ) throws -> DeviceCapabilityMatrix {
        try DeviceCapabilityMatrix(
            generatedAt: generatedAt,
            device: device,
            capabilities: [
                status(
                    capability: .healthSampleRead,
                    availability: health?.capability.availability,
                    supported: health?.capability.supportedKinds.isEmpty == false,
                    permission: health?.permission
                ),
                IntegrationCapabilityStatus(
                    capability: .healthNutrientWrite,
                    availability: healthNutrientWritePermission == .unavailable
                        ? .unavailable
                        : .available,
                    permission: healthNutrientWritePermission
                ),
                status(
                    capability: .calendarRead,
                    availability: calendar?.capability.availability,
                    supported: calendar?.capability.supportsFullAccessRead,
                    permission: calendar?.permission
                ),
                IntegrationCapabilityStatus(
                    capability: .calendarWrite,
                    availability: .disabledByPolicy,
                    permission: .notRequired
                ),
                status(
                    capability: .currentWeather,
                    availability: weather?.capability.availability,
                    supported: weather?.capability.supportsCurrentConditions,
                    permission: weather?.permission
                ),
                status(
                    capability: .weatherForecast,
                    availability: weather?.capability.availability,
                    supported: weather.map {
                        $0.capability.supportsHourlyForecast
                            || $0.capability.supportsDailyForecast
                    },
                    permission: weather?.permission
                ),
                status(
                    capability: .foregroundLocation,
                    availability: location?.capability.availability,
                    supported: location?.capability.supportsForegroundBroadPlace,
                    permission: location?.permission
                ),
                IntegrationCapabilityStatus(
                    capability: .significantLocation,
                    availability: .disabledByPolicy,
                    permission: .notRequired
                ),
            ]
        )
    }

    private static func status(
        capability: IntegrationCapability,
        availability: IntegrationCapabilityAvailability?,
        supported: Bool?,
        permission: IntegrationPermissionState?
    ) -> IntegrationCapabilityStatus {
        guard let availability, let supported, let permission else {
            return IntegrationCapabilityStatus(
                capability: capability,
                availability: .unavailable,
                permission: .unavailable
            )
        }
        return IntegrationCapabilityStatus(
            capability: capability,
            availability: availability == .available && !supported
                ? .unsupported
                : availability,
            permission: availability == .available && !supported
                ? .notRequired
                : permission
        )
    }
}
