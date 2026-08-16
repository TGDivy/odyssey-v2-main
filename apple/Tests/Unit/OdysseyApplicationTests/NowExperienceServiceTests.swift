import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseyIntelligence
import Testing

private let nowExperienceDate = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func nowExperiencePersistsVisitAndCorrectionWithoutLosingEither() async throws {
    let fixture = try NowExperienceFixture()
    defer { fixture.remove() }
    let service = NowExperienceService(
        store: fixture.store,
        clock: { nowExperienceDate }
    )
    let correction = try NowStateCorrection(
        state: .recovery,
        reason: .capacityChanged,
        createdAt: nowExperienceDate,
        expiresAt: nowExperienceDate.addingTimeInterval(3_600)
    )

    #expect(try await service.record() == NowExperienceRecord())
    _ = try await service.setCorrection(correction)
    let visited = try await service.recordVisit(
        at: nowExperienceDate.addingTimeInterval(60)
    )
    #expect(visited.lastSeenAt == nowExperienceDate.addingTimeInterval(60))
    #expect(visited.correction == correction)
    #expect(try await service.record() == visited)

    let delayed = try await service.recordVisit(at: nowExperienceDate)
    #expect(delayed.lastSeenAt == visited.lastSeenAt)

    let cleared = try await service.clearCorrection()
    #expect(cleared.lastSeenAt == visited.lastSeenAt)
    #expect(cleared.correction == nil)
}

@Test
func nowExperienceRejectsUnknownStoredSchema() async throws {
    let fixture = try NowExperienceFixture()
    defer { fixture.remove() }
    _ = try fixture.store.putLocalApplicationState(
        key: NowExperienceService.stateKey,
        schemaVersion: 2,
        document: Data("{}".utf8),
        updatedAt: nowExperienceDate
    )
    let service = NowExperienceService(store: fixture.store)

    await #expect(throws: NowExperienceError.invalidSchema) {
        try await service.record()
    }
}

private struct NowExperienceFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-now-experience-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("odyssey.sqlite"),
            deviceID: try UUIDv7(validating: UUID(
                uuidString: "018f3e1b-7c90-7abc-8def-000000000002"
            )!),
            preMigrationBackupDirectory: directory,
            clock: { nowExperienceDate }
        ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
