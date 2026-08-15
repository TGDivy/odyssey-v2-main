import Foundation
import OdysseyDomain

public struct TechnicalSignal: Codable, Hashable, Sendable {
    public let name: String
    public let occurredAt: Date
    public let correlationID: UUID
    public let dimensions: [String: String]

    public init(
        name: String,
        occurredAt: Date,
        correlationID: UUID,
        dimensions: [String: String]
    ) {
        self.name = name
        self.occurredAt = occurredAt
        self.correlationID = correlationID
        self.dimensions = dimensions
    }
}

public protocol TelemetryRecording: Sendable {
    func record(_ signal: TechnicalSignal) async
}

public actor NoOpTelemetryRecorder: TelemetryRecording {
    public init() {}
    public func record(_: TechnicalSignal) async {}
}

