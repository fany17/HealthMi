import SwiftData
import XCTest
@testable import HealthMi

@MainActor
final class SyncStateStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    nonisolated override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run {
            let schema = Schema([SyncState.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try ModelContainer(for: schema, configurations: [config])
            context = container.mainContext
        }
    }

    func testRecordUpdatesState() {
        let type: SyncDataType = .heartRate
        let highWater = Date()
        SyncStateStore.record(type: type, highWater: highWater, added: 42, in: context)

        let state = SyncStateStore.state(for: type, in: context)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.lastSyncedEnd?.timeIntervalSince(highWater) ?? -1, 0, accuracy: 1)
        XCTAssertEqual(state?.lastAddedCount, 42)
    }

    func testClearAllRemovesAllStates() {
        SyncStateStore.record(type: .heartRate, highWater: Date(), added: 10, in: context)
        SyncStateStore.record(type: .sleep, highWater: Date(), added: 5, in: context)
        SyncStateStore.record(type: .spo2, highWater: Date(), added: 3, in: context)

        SyncStateStore.clearAll(in: context)

        for type in SyncDataType.allCases {
            XCTAssertNil(SyncStateStore.state(for: type, in: context))
        }
    }

    func testRecordTwiceUpdatesSameRow() {
        let type: SyncDataType = .heartRate
        SyncStateStore.record(type: type, highWater: Date(timeIntervalSinceNow: -3600), added: 10, in: context)
        SyncStateStore.record(type: type, highWater: Date(), added: 20, in: context)

        let state = SyncStateStore.state(for: type, in: context)
        XCTAssertEqual(state?.lastAddedCount, 20)
    }

    func testStressBackfillPreservesOutsideHistoryAndDeduplicatesInput() throws {
        let schema = Schema([StressRecord.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true),
        ])
        let context = ModelContext(container)
        let before = MiStressSample(timestamp: Date(timeIntervalSince1970: 99), stressScore: 10)
        let inside = MiStressSample(timestamp: Date(timeIntervalSince1970: 100), stressScore: 20)
        let after = MiStressSample(timestamp: Date(timeIntervalSince1970: 201), stressScore: 30)
        for sample in [before, inside, after] {
            context.insert(StressRecord(externalID: sample.id, timestamp: sample.timestamp, stressScore: sample.stressScore))
        }
        try context.save()
        let updated = MiStressSample(timestamp: inside.timestamp, stressScore: 40)
        let added = try StressStore.replace(
            samples: [updated, updated],
            range: Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 200), in: context
        )
        // Read with another context to check committed data rather than cached objects.
        let records = try ModelContext(container).fetch(FetchDescriptor<StressRecord>())
        XCTAssertEqual(added, 1)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.first { $0.externalID == inside.id }?.stressScore, 40)
        XCTAssertEqual(records.first { $0.externalID == before.id }?.stressScore, 10)
        XCTAssertEqual(records.first { $0.externalID == after.id }?.stressScore, 30)
    }

    func testEmptyStressBackfillClearsOnlyRequestedRange() throws {
        let schema = Schema([StressRecord.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true),
        ])
        let context = ModelContext(container)
        for seconds in [99, 100, 200, 201] {
            context.insert(StressRecord(externalID: "test_\(seconds)", timestamp: Date(timeIntervalSince1970: Double(seconds)), stressScore: 10))
        }
        try context.save()
        let added = try StressStore.replace(
            samples: [], range: Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 200), in: context
        )
        let records = try ModelContext(container).fetch(FetchDescriptor<StressRecord>())
        XCTAssertEqual(added, 0)
        XCTAssertEqual(Set(records.map(\.externalID)), ["test_99", "test_201"])
    }
}
