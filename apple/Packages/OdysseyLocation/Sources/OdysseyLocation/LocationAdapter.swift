import Foundation
import OdysseyDomain

public struct BroadLocationContext: Codable, Hashable, Sendable {
    public let placeLabel: String?
    public let locality: String?
    public let countryCode: String?
    public let capturedAt: Date
    public let precision: String
}

public protocol LocationContextProviding: Sendable {
    func requestWhenInUseAuthorization() async
    func broadContext() async throws -> BroadLocationContext?
    func stopMonitoring() async
}

#if canImport(CoreLocation)
import CoreLocation

public actor CoreLocationAdapter: LocationContextProviding {
    private let manager: CLLocationManager

    public init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
    }

    public func requestWhenInUseAuthorization() async {
        manager.requestWhenInUseAuthorization()
    }

    public func broadContext() async throws -> BroadLocationContext? { nil }

    public func stopMonitoring() async { manager.stopMonitoringSignificantLocationChanges() }
}
#endif

