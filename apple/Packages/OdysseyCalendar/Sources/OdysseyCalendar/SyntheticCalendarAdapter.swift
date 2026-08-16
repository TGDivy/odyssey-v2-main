import Foundation
import OdysseyIntegrations

public struct SyntheticCalendarPage: Hashable, Sendable {
    public let expectedWindow: CalendarQueryWindow
    public let page: CalendarMirrorPage

    public init(
        expectedWindow: CalendarQueryWindow,
        page: CalendarMirrorPage
    ) {
        self.expectedWindow = expectedWindow
        self.page = page
    }
}

public actor SyntheticCalendarAdapter: CalendarContextProviding {
    private let mirrorCapability: CalendarMirrorCapability
    private let authorizationAfterRequest: IntegrationPermissionState
    private var pages: [SyntheticCalendarPage]
    private let clock: @Sendable () -> Date
    private var permission: IntegrationPermissionState

    public init(
        capability: CalendarMirrorCapability,
        initialPermission: IntegrationPermissionState,
        authorizationAfterRequest: IntegrationPermissionState,
        pages: [SyntheticCalendarPage] = [],
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        mirrorCapability = capability
        permission = initialPermission
        self.authorizationAfterRequest = authorizationAfterRequest
        self.pages = pages
        self.clock = clock
    }

    public func capability() async -> CalendarMirrorCapability {
        mirrorCapability
    }

    public func authorizationState() async -> IntegrationPermissionState {
        permission
    }

    public func requestReadAuthorization() async throws -> IntegrationPermissionState {
        if permission == .notDetermined || permission == .partial {
            permission = authorizationAfterRequest
        }
        return permission
    }

    public func events(
        in window: CalendarQueryWindow
    ) async throws -> CalendarMirrorPage {
        switch permission {
        case .authorized:
            break
        case .denied:
            return try unavailablePage(window: window, outcome: .permissionDenied)
        case .restricted:
            return try unavailablePage(window: window, outcome: .restricted)
        case .unavailable:
            return try unavailablePage(window: window, outcome: .unavailable)
        case .notDetermined, .notRequired, .partial:
            return try unavailablePage(window: window, outcome: .permissionDenied)
        }
        guard mirrorCapability.availability == .available,
              mirrorCapability.supportsFullAccessRead
        else {
            return try unavailablePage(window: window, outcome: .unavailable)
        }
        guard let pageIndex = pages.firstIndex(where: {
            $0.expectedWindow == window
        }) else {
            throw CalendarMirrorError.unexpectedSyntheticWindow
        }
        let page = pages.remove(at: pageIndex)
        guard page.page.window == window else {
            throw CalendarMirrorError.invalidBatch
        }
        return page.page
    }

    private func unavailablePage(
        window: CalendarQueryWindow,
        outcome: CalendarMirrorOutcome
    ) throws -> CalendarMirrorPage {
        try CalendarMirrorPage(
            window: window,
            queriedAt: clock(),
            items: [],
            outcome: outcome
        )
    }
}

public struct UnavailableCalendarAdapter: CalendarContextProviding {
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    public func capability() async -> CalendarMirrorCapability {
        CalendarMirrorCapability(
            availability: .unavailable,
            supportsFullAccessRead: false
        )
    }

    public func authorizationState() async -> IntegrationPermissionState {
        .unavailable
    }

    public func requestReadAuthorization() async throws -> IntegrationPermissionState {
        .unavailable
    }

    public func events(
        in window: CalendarQueryWindow
    ) async throws -> CalendarMirrorPage {
        try CalendarMirrorPage(
            window: window,
            queriedAt: clock(),
            items: [],
            outcome: .unavailable
        )
    }
}
