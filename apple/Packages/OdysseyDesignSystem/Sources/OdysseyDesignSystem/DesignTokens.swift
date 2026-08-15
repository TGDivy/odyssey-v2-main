import Foundation
import OdysseyDomain

public enum OdysseyColorToken: String, Codable, Sendable {
    case background
    case surface
    case primaryText
    case secondaryText
    case path
    case landmark
    case uncertainty
    case recovery
}

public enum OdysseyMotionToken: String, Codable, Sendable {
    case immediate
    case responsive
    case contextual
    case reflective
}

public struct AtmosphereState: Codable, Hashable, Sendable {
    public let uncertainty: ConfidenceBand
    public let nowState: String
    public let reducedMotion: Bool

    public init(uncertainty: ConfidenceBand, nowState: String, reducedMotion: Bool) {
        self.uncertainty = uncertainty
        self.nowState = nowState
        self.reducedMotion = reducedMotion
    }
}

