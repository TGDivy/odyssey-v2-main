import Foundation
import OdysseyDomain

public enum NowState: String, Codable, Sendable {
    case clear
    case choice
    case preparation
    case recovery
    case open
    case disrupted
}

public struct DeterministicContextInput: Codable, Hashable, Sendable {
    public let unresolvedDecisionCount: Int
    public let preparationDeadlineCount: Int
    public let materialHealthConstraintCount: Int
    public let disruptionCount: Int
    public let explicitlyOpen: Bool

    public init(
        unresolvedDecisionCount: Int,
        preparationDeadlineCount: Int,
        materialHealthConstraintCount: Int,
        disruptionCount: Int,
        explicitlyOpen: Bool
    ) {
        self.unresolvedDecisionCount = unresolvedDecisionCount
        self.preparationDeadlineCount = preparationDeadlineCount
        self.materialHealthConstraintCount = materialHealthConstraintCount
        self.disruptionCount = disruptionCount
        self.explicitlyOpen = explicitlyOpen
    }
}

public struct DeterministicContextProjector: Sendable {
    public init() {}

    public func project(_ input: DeterministicContextInput) -> NowState {
        if input.disruptionCount > 0 { return .disrupted }
        if input.materialHealthConstraintCount > 0 { return .recovery }
        if input.preparationDeadlineCount > 0 { return .preparation }
        if input.unresolvedDecisionCount > 0 { return .choice }
        if input.explicitlyOpen { return .open }
        return .clear
    }
}

public protocol StructuredSynthesisProviding: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    func synthesize(_ input: Input) async throws -> Output
}

