#if canImport(CoreLocation) && (os(iOS) || os(visionOS))
@preconcurrency import CoreLocation
import Foundation
import OdysseyIntegrations

public enum CoreLocationAdapterError: Error, Equatable, Sendable {
    case requestInProgress
    case acquisitionFailed
    case invalidProviderData
}

@MainActor
public final class CoreLocationAdapter: NSObject, LocationContextProviding,
    CLLocationManagerDelegate
{
    private static let maximumFixAge: TimeInterval = 5 * 60
    private static let maximumAccuracyMeters = 50_000.0
    private static let contextLifetime: TimeInterval = 2 * 60 * 60

    private let manager: CLLocationManager
    private let geocoder: CLGeocoder
    private let clock: @Sendable () -> Date
    private var authorizationContinuations = [
        CheckedContinuation<IntegrationPermissionState, Never>
    ]()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    public init(
        manager: CLLocationManager = CLLocationManager(),
        geocoder: CLGeocoder = CLGeocoder(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.manager = manager
        self.geocoder = geocoder
        self.clock = clock
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    public func capability() async -> LocationContextCapability {
        LocationContextCapability(
            availability: CLLocationManager.locationServicesEnabled()
                ? .available
                : .unavailable,
            supportsForegroundBroadPlace: true,
            supportsSignificantChanges: false
        )
    }

    public func authorizationState() async -> IntegrationPermissionState {
        Self.permission(manager.authorizationStatus)
    }

    public func requestWhenInUseAuthorization() async -> IntegrationPermissionState {
        let current = Self.permission(manager.authorizationStatus)
        guard current == .notDetermined else {
            return current
        }
        return await withCheckedContinuation { continuation in
            authorizationContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    public func currentBroadLocation() async throws -> BroadLocationResult {
        guard CLLocationManager.locationServicesEnabled() else {
            return try BroadLocationResult(outcome: .unavailable, fix: nil)
        }
        let permission = Self.permission(manager.authorizationStatus)
        switch permission {
        case .authorized:
            break
        case .restricted:
            return try BroadLocationResult(outcome: .restricted, fix: nil)
        case .unavailable:
            return try BroadLocationResult(outcome: .unavailable, fix: nil)
        case .denied, .notDetermined, .partial, .notRequired:
            return try BroadLocationResult(outcome: .permissionDenied, fix: nil)
        }

        let location: CLLocation
        do {
            location = try await oneShotLocation()
        } catch let error as CLError {
            switch error.code {
            case .denied:
                return try BroadLocationResult(outcome: .permissionDenied, fix: nil)
            case .locationUnknown, .network:
                return try BroadLocationResult(outcome: .noFix, fix: nil)
            default:
                throw CoreLocationAdapterError.acquisitionFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CoreLocationAdapterError {
            throw error
        } catch {
            throw CoreLocationAdapterError.acquisitionFailed
        }

        let observedAt = clock()
        guard observedAt.timeIntervalSinceReferenceDate.isFinite,
              location.timestamp.timeIntervalSinceReferenceDate.isFinite,
              location.timestamp <= observedAt.addingTimeInterval(Self.maximumFixAge),
              observedAt.timeIntervalSince(location.timestamp) <= Self.maximumFixAge
        else {
            return try BroadLocationResult(
                outcome: .noFix,
                fix: nil,
                rejectedRecordCount: 1
            )
        }
        guard location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.maximumAccuracyMeters,
              CLLocationCoordinate2DIsValid(location.coordinate)
        else {
            return try BroadLocationResult(
                outcome: .insufficientAccuracy,
                fix: nil,
                rejectedRecordCount: 1
            )
        }

        let placemark: CLPlacemark
        do {
            let placemarks = try await reverseGeocode(location)
            guard let first = placemarks.first else {
                return try BroadLocationResult(
                    outcome: .noFix,
                    fix: nil,
                    rejectedRecordCount: 1
                )
            }
            placemark = first
        } catch let error as CLError {
            switch error.code {
            case .geocodeCanceled, .geocodeFoundNoResult,
                 .geocodeFoundPartialResult, .network:
                return try BroadLocationResult(
                    outcome: .noFix,
                    fix: nil,
                    rejectedRecordCount: 1
                )
            case .denied:
                return try BroadLocationResult(outcome: .permissionDenied, fix: nil)
            default:
                throw CoreLocationAdapterError.acquisitionFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CoreLocationAdapterError.acquisitionFailed
        }

        guard let timeZone = placemark.timeZone,
              TimeZone(identifier: timeZone.identifier) != nil
        else {
            return try BroadLocationResult(
                outcome: .noFix,
                fix: nil,
                rejectedRecordCount: 1
            )
        }
        let selected = Self.selectedPlace(from: placemark)
        let identifier = Self.placeIdentifier(
            displayName: selected.displayName,
            countryCode: Self.normalizedText(placemark.isoCountryCode, maximum: 8),
            timeZoneID: timeZone.identifier,
            precision: selected.precision
        )
        do {
            let context = try BroadLocationContext(
                placeIdentifier: identifier,
                displayName: selected.displayName,
                timeZoneID: timeZone.identifier,
                capturedAt: location.timestamp,
                expiresAt: location.timestamp.addingTimeInterval(Self.contextLifetime),
                precision: selected.precision
            )
            return try BroadLocationResult(
                outcome: .acquired,
                fix: TransientLocationFix(
                    context: context,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracyMeters: location.horizontalAccuracy
                )
            )
        } catch {
            throw CoreLocationAdapterError.invalidProviderData
        }
    }

    public func stopMonitoring() async {
        manager.stopUpdatingLocation()
        geocoder.cancelGeocode()
        if let continuation = locationContinuation {
            locationContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    public func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        let permission = Self.permission(manager.authorizationStatus)
        guard permission != .notDetermined else { return }
        let continuations = authorizationContinuations
        authorizationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: permission)
        }
    }

    public func locationManager(
        _: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        manager.stopUpdatingLocation()
        guard let best = locations.filter({
            $0.horizontalAccuracy >= 0
                && CLLocationCoordinate2DIsValid($0.coordinate)
        }).sorted(by: {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.horizontalAccuracy > $1.horizontalAccuracy
        }).last else {
            continuation.resume(throwing: CoreLocationAdapterError.invalidProviderData)
            return
        }
        continuation.resume(returning: best)
    }

    public func locationManager(
        _: CLLocationManager,
        didFailWithError error: any Error
    ) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        manager.stopUpdatingLocation()
        continuation.resume(throwing: error)
    }

    private func oneShotLocation() async throws -> CLLocation {
        guard locationContinuation == nil else {
            throw CoreLocationAdapterError.requestInProgress
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                locationContinuation = continuation
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.stopMonitoring()
            }
        }
    }

    private func reverseGeocode(
        _ location: CLLocation
    ) async throws -> [CLPlacemark] {
        try await withCheckedThrowingContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: placemarks ?? [])
                }
            }
        }
    }

    private static func permission(
        _ status: CLAuthorizationStatus
    ) -> IntegrationPermissionState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorizedAlways, .authorizedWhenInUse:
            .authorized
        @unknown default:
            .unavailable
        }
    }

    private static func selectedPlace(
        from placemark: CLPlacemark
    ) -> (displayName: String?, precision: BroadPlacePrecision) {
        let locality = normalizedText(placemark.locality, maximum: 100)
        let administrativeArea = normalizedText(
            placemark.administrativeArea,
            maximum: 100
        )
        if let locality {
            let displayName: String
            if let administrativeArea, administrativeArea != locality {
                displayName = "\(locality), \(administrativeArea)"
            } else {
                displayName = locality
            }
            if LocationValidation.validText(displayName, maximum: 200) {
                return (displayName, .locality)
            }
            return (locality, .locality)
        }
        if let administrativeArea {
            return (administrativeArea, .administrativeArea)
        }
        return (nil, .timeZone)
    }

    private static func placeIdentifier(
        displayName: String?,
        countryCode: String?,
        timeZoneID: String,
        precision: BroadPlacePrecision
    ) -> String {
        let material = [
            precision.rawValue,
            countryCode?.lowercased() ?? "",
            displayName?.lowercased() ?? "",
            timeZoneID.lowercased(),
        ].joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in material.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "place_%016llx", hash)
    }

    private static func normalizedText(
        _ value: String?,
        maximum: Int
    ) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocationValidation.validText(normalized, maximum: maximum) else {
            return nil
        }
        return normalized
    }
}
#endif
