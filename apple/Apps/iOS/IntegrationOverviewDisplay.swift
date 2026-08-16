import OdysseyIntegrations

extension IntegrationDeviceKind {
    var ownerDisplayName: String {
        switch self {
        case .iPhone:
            "iPhone"
        case .iPad:
            "iPad"
        case .mac:
            "Mac"
        case .watch:
            "Apple Watch"
        }
    }
}

extension IntegrationCapability {
    var ownerDisplayName: String {
        switch self {
        case .healthSampleRead:
            "Apple Health context read"
        case .healthNutrientWrite:
            "Odyssey nutrient writes"
        case .calendarRead:
            "Calendar full-access read"
        case .calendarWrite:
            "Calendar write"
        case .currentWeather:
            "Current weather"
        case .weatherForecast:
            "Weather forecast"
        case .foregroundLocation:
            "Foreground broad location"
        case .significantLocation:
            "Significant/background location"
        }
    }
}

extension IntegrationConnector {
    var ownerDisplayName: String {
        switch self {
        case .health:
            "Apple Health"
        case .calendar:
            "Calendar"
        case .weather:
            "Weather"
        case .location:
            "Broad Location"
        }
    }
}

extension IntegrationContribution {
    var ownerDisplayName: String {
        switch self {
        case .approvedHealthContext:
            "Owner-approved Health context"
        case .calendarConstraints:
            "Calendar constraints"
        case .planningWeather:
            "Fresh planning weather"
        case .broadForegroundPlace:
            "Current broad foreground place"
        }
    }
}
