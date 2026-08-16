import Foundation
import OdysseyIntelligence
import Testing

@Test
func nowWidgetSnapshotIsBoundedFreshAndRoundTrips() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_786_847_400)
    let snapshot = try NowWidgetSnapshot(
        generatedAt: generatedAt,
        expiresAt: generatedAt.addingTimeInterval(6 * 60 * 60),
        timeZoneID: "Europe/London",
        state: .preparation,
        summary: "A known commitment makes preparation valuable.",
        tomorrowSummary: "Tomorrow has two known commitments.",
        nextTransitionAt: generatedAt.addingTimeInterval(3_600)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    #expect(try decoder.decode(
        NowWidgetSnapshot.self,
        from: encoder.encode(snapshot)
    ) == snapshot)
    #expect(snapshot.isFresh(at: generatedAt.addingTimeInterval(60)))
    #expect(!snapshot.isFresh(at: snapshot.expiresAt.addingTimeInterval(1)))
    #expect(throws: NowWidgetSnapshotError.invalidClock) {
        try NowWidgetSnapshot(
            generatedAt: generatedAt,
            expiresAt: generatedAt.addingTimeInterval(
                NowWidgetSnapshot.maximumLifetime + 1
            ),
            timeZoneID: "UTC",
            state: .clear,
            summary: "Nothing requires attention."
        )
    }
}
