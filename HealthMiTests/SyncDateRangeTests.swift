import XCTest
@testable import HealthMi

final class SyncDateRangeTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testSingleDayContainsBothBoundariesInSelectedRegion() throws {
        let range = try SyncDateRange(start: date("2026-10-20T12:00:00Z"), end: date("2026-10-20T12:00:00Z"),
                                      timeZone: MiRegion.cn.timeZone, now: date("2026-10-27T00:00:00Z"))
        XCTAssertEqual(range.start, date("2026-10-19T16:00:00Z"))
        XCTAssertEqual(range.end, date("2026-10-20T15:59:59Z"))
        XCTAssertEqual(range.endTime - range.startTime + 1, 86400)
    }

    func testFutureDateUsesRegionDayRatherThanPhoneDay() throws {
        let now = date("2026-10-20T23:30:00Z") // China is already October 21.
        XCTAssertNoThrow(try SyncDateRange(start: date("2026-10-21T00:00:00Z"), end: date("2026-10-21T00:00:00Z"),
                                          timeZone: MiRegion.cn.timeZone, now: now))
        XCTAssertThrowsError(try SyncDateRange(start: date("2026-10-22T00:00:00Z"), end: date("2026-10-22T00:00:00Z"),
                                             timeZone: MiRegion.cn.timeZone, now: now))
    }

    func testReversedDaysAreRejectedButSameDayTimesAreAllowed() throws {
        let tz = MiRegion.cn.timeZone
        let now = date("2026-10-27T00:00:00Z")
        XCTAssertThrowsError(try SyncDateRange(start: date("2026-10-21T00:00:00Z"), end: date("2026-10-20T00:00:00Z"), timeZone: tz, now: now))
        XCTAssertNoThrow(try SyncDateRange(start: date("2026-10-20T12:00:00Z"), end: date("2026-10-20T00:00:00Z"), timeZone: tz, now: now))
    }

    func testPresetSevenDaysIncludesTodayExactlySevenTimes() {
        let range = SyncDateRange.recent(days: 7, timeZone: MiRegion.cn.timeZone, now: date("2026-01-03T08:00:00Z"))
        XCTAssertEqual(range.start, date("2025-12-27T16:00:00Z"))
        XCTAssertEqual(range.end, date("2026-01-03T15:59:59Z"))
        XCTAssertEqual(range.endTime - range.startTime + 1, 7 * 86400)
    }

    func testLeapDayAndDSTDayLengths() throws {
        let now = date("2026-12-31T00:00:00Z")
        let leap = try SyncDateRange(start: date("2024-02-28T12:00:00Z"), end: date("2024-03-01T12:00:00Z"), timeZone: MiRegion.cn.timeZone, now: now)
        XCTAssertEqual(leap.endTime - leap.startTime + 1, 3 * 86400)
        let spring = try SyncDateRange(start: date("2026-03-08T12:00:00Z"), end: date("2026-03-08T12:00:00Z"), timeZone: MiRegion.us.timeZone, now: now)
        let fall = try SyncDateRange(start: date("2026-11-01T12:00:00Z"), end: date("2026-11-01T12:00:00Z"), timeZone: MiRegion.us.timeZone, now: now)
        XCTAssertEqual(spring.endTime - spring.startTime + 1, 23 * 3600)
        XCTAssertEqual(fall.endTime - fall.startTime + 1, 25 * 3600)
    }

    func testExplicitHistoricalRangeIgnoresIncrementalCursor() async throws {
        let range = try SyncDateRange(start: date("2026-01-01T00:00:00Z"), end: date("2026-01-01T00:00:00Z"), timeZone: MiRegion.cn.timeZone)
        let engine = SyncEngine(timeZone: MiRegion.cn.timeZone)
        let window = await engine.syncWindow(highWater: Date(), backfillDays: 3650, forceBackfill: true, range: range)
        XCTAssertEqual(window.startTime, range.startTime)
        XCTAssertEqual(window.endTime, range.endTime)
    }

    @MainActor func testBackgroundCatchupKeepsOldCursorAndAdvancesOnlyOneDay() {
        let old = date("2026-01-01T00:00:00Z")
        let now = date("2026-10-01T00:00:00Z")
        XCTAssertEqual(AppModel.backgroundCutoff(highWater: old, now: now, timeZone: MiRegion.cn.timeZone), old.addingTimeInterval(86400))
        XCTAssertEqual(AppModel.backgroundCutoff(highWater: now, now: now, timeZone: MiRegion.cn.timeZone), now)
    }
}
