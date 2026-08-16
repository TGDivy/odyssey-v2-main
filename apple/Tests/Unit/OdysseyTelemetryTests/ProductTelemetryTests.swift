import Foundation
import OdysseyDomain
import OdysseyTelemetry
import Testing

private let productTelemetryDate = Date(timeIntervalSince1970: 1_786_838_400)

private func productTelemetryUUID(_ value: String) throws -> UUIDv7 {
    try UUIDv7(validating: #require(UUID(uuidString: value)))
}

private func tomorrowAvailabilityProperties() -> [String: ProductTelemetryPropertyValue] {
    [
        "calendar_state": .string("fresh"),
        "intentionally_absent": .boolean(false),
        "transition_count": .integer(2),
        "pressure_present": .boolean(true),
        "protected_open_present": .boolean(false),
    ]
}

@Test
func productTelemetryRegistryOwnsEveryStableEvent() {
    #expect(ProductTelemetryRegistry.questions.count == 2)
    #expect(ProductTelemetryRegistry.events.count == ProductTelemetryEventName.allCases.count)
    #expect(ProductTelemetryRegistry.events.allSatisfy { $0.localOnlyByDefault })
    #expect(ProductTelemetryRegistry.events.allSatisfy { $0.retentionDays == 30 })
}

@Test
func productTelemetryEventRejectsUnknownOrMistypedProperties() throws {
    let deviceID = try productTelemetryUUID("018f22d2-8a80-7000-8000-000000000002")
    var unknown = tomorrowAvailabilityProperties()
    unknown["calendar_title"] = .string("private")
    #expect(throws: ProductTelemetryValidationError.unknownProperty("calendar_title")) {
        try ProductTelemetryEvent(
            occurredAt: productTelemetryDate,
            receivedAt: productTelemetryDate,
            deviceID: deviceID,
            appBuild: "1.0.0+1",
            surface: "iphone_now",
            eventName: .tomorrowMapAvailabilityEvaluated,
            contextVersion: "native-now-context-1",
            properties: unknown
        )
    }

    var mistyped = tomorrowAvailabilityProperties()
    mistyped["transition_count"] = .boolean(true)
    #expect(throws: ProductTelemetryValidationError.invalidProperty("transition_count")) {
        try ProductTelemetryEvent(
            occurredAt: productTelemetryDate,
            receivedAt: productTelemetryDate,
            deviceID: deviceID,
            appBuild: "1.0.0+1",
            surface: "iphone_now",
            eventName: .tomorrowMapAvailabilityEvaluated,
            contextVersion: "native-now-context-1",
            properties: mistyped
        )
    }
}

@Test
func productTelemetryEventRoundTripsScalarWireValues() throws {
    let event = try ProductTelemetryEvent(
        eventID: productTelemetryUUID("018f22d2-8a80-7000-8000-000000000001"),
        occurredAt: productTelemetryDate,
        receivedAt: productTelemetryDate,
        deviceID: productTelemetryUUID("018f22d2-8a80-7000-8000-000000000002"),
        appBuild: "1.0.0+1",
        surface: "iphone_now",
        eventName: .tomorrowMapAvailabilityEvaluated,
        contextVersion: "native-now-context-1",
        properties: tomorrowAvailabilityProperties()
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(event)
    let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let properties = try #require(document["properties_typed"] as? [String: Any])
    let transitionCount = try #require(properties["transition_count"] as? Int)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(transitionCount == 2)
    #expect(try decoder.decode(ProductTelemetryEvent.self, from: data) == event)
    #expect(event.localOnly)
}
