import Foundation
import OdysseyDomain

public struct HealthContextSummary: Codable, Hashable, Sendable {
    public let asOf: Date
    public let sourceIdentifiers: [String]
    public let sleepDuration: TimeInterval?
    public let activeEnergyKilocalories: Double?
    public let dataFreshness: String

    public init(
        asOf: Date,
        sourceIdentifiers: [String],
        sleepDuration: TimeInterval?,
        activeEnergyKilocalories: Double?,
        dataFreshness: String
    ) {
        self.asOf = asOf
        self.sourceIdentifiers = sourceIdentifiers
        self.sleepDuration = sleepDuration
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.dataFreshness = dataFreshness
    }
}

public protocol HealthContextProviding: Sendable {
    func requestIncrementalAuthorization() async throws
    func context(asOf: Date) async throws -> HealthContextSummary?
    func revokeDerivedAccess() async throws
}

#if canImport(HealthKit)
import HealthKit

public actor HealthKitAdapter: HealthContextProviding {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public func requestIncrementalAuthorization() async throws {}

    public func context(asOf _: Date) async throws -> HealthContextSummary? { nil }

    public func revokeDerivedAccess() async throws {}
}
#endif

