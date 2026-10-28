import XCTest
@testable import HealthMi

final class BackfillTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-12-31T12:00:00Z") }
    private func range(_ first: String, _ last: String, region: MiRegion = .cn) -> SyncDateRange {
        try! SyncDateRange(start: date(first + "T12:00:00Z"), end: date(last + "T12:00:00Z"),
                           timeZone: region.timeZone, now: now)
    }
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("backfill-test-\(UUID())/progress.json")
    }

    func testMonthsClipBothEndsAndIncludeLeapDayWithoutGaps() {
        let selected = range("2024-01-31", "2024-03-01")
        let pieces = BackfillPlanner.split(selected, size: .month)
        XCTAssertEqual(pieces, [range("2024-01-31", "2024-01-31"), range("2024-02-01", "2024-02-29"), range("2024-03-01", "2024-03-01")])
        for index in 1..<pieces.count { XCTAssertEqual(pieces[index - 1].endTime + 1, pieces[index].startTime) }
    }

    func testSingleDayNeverExpandsToOtherDates() {
        let selected = range("2026-01-02", "2026-01-02")
        for size in [BackfillPlanner.Size.month, .week, .day] {
            XCTAssertEqual(BackfillPlanner.split(selected, size: size), [selected])
        }
    }

    func testSplittingDSTKeeps23And25HourDaysAndExactCoverage() {
        for (first, last, hours) in [("2026-03-07", "2026-03-09", 23), ("2026-10-31", "2026-11-02", 25)] {
            let selected = range(first, last, region: .us)
            let pieces = BackfillPlanner.split(selected, size: .day)
            XCTAssertEqual(pieces.count, 3)
            XCTAssertEqual(pieces[1].endTime - pieces[1].startTime + 1, hours * 3600)
            XCTAssertEqual(pieces.first?.start, selected.start)
            XCTAssertEqual(pieces.last?.end, selected.end)
            XCTAssertEqual(pieces[0].endTime + 1, pieces[1].startTime)
            XCTAssertEqual(pieces[1].endTime + 1, pieces[2].startTime)
        }
    }

    func testScopeSeparatesAccountAndRegionWithoutStoringRawID() {
        let a = BackfillScope.key(userID: "synthetic-account-a", region: .cn)
        XCTAssertEqual(a, BackfillScope.key(userID: "synthetic-account-a", region: .cn))
        XCTAssertNotEqual(a, BackfillScope.key(userID: "synthetic-account-b", region: .cn))
        XCTAssertNotEqual(a, BackfillScope.key(userID: "synthetic-account-a", region: .us))
        XCTAssertEqual(a.count, 64)
        XCTAssertFalse(a.contains("synthetic"))
    }

    @MainActor func testCheckpointSurvivesRestartAndKeepsHolesTypesAndAccountsSeparate() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BackfillProgressStore(url: url)
        let whole = range("2026-01-01", "2026-01-31")
        try store.record(scope: "A", type: .sleep, range: range("2026-01-02", "2026-01-30"), now: now)
        let reopened = try BackfillProgressStore(url: url)
        XCTAssertEqual(reopened.pending(scope: "A", type: .sleep, range: whole, now: now),
                       [range("2026-01-01", "2026-01-01"), range("2026-01-31", "2026-01-31")])
        XCTAssertEqual(reopened.pending(scope: "A", type: .hrv, range: whole, now: now), [whole])
        XCTAssertEqual(reopened.pending(scope: "B", type: .sleep, range: whole, now: now), [whole])
    }

    @MainActor func testOverlappingCompletionsMergeAndRecheckPreservesOutsideRange() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BackfillProgressStore(url: url)
        let whole = range("2026-01-01", "2026-01-31")
        try store.record(scope: "A", type: .sleep, range: range("2026-01-01", "2026-01-20"), now: now)
        try store.record(scope: "A", type: .sleep, range: range("2026-01-15", "2026-01-31"), now: now)
        XCTAssertTrue(store.pending(scope: "A", type: .sleep, range: whole, now: now).isEmpty)
        let recheck = range("2026-01-10", "2026-01-12")
        try store.invalidate(scope: "A", types: [.sleep], range: recheck)
        XCTAssertEqual(try BackfillProgressStore(url: url).pending(scope: "A", type: .sleep, range: whole, now: now), [recheck])
    }

    @MainActor func testTodayAndYesterdayAlwaysRemainOpenAcrossRuns() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BackfillProgressStore(url: url)
        let whole = range("2026-12-01", "2026-12-31")
        try store.record(scope: "A", type: .sleep, range: whole, now: now)
        XCTAssertEqual(store.pending(scope: "A", type: .sleep, range: whole, now: now), [range("2026-12-30", "2026-12-31")])
        // A day checked while still open must be checked again after it ages out.
        XCTAssertEqual(store.pending(scope: "A", type: .sleep, range: whole, now: now.addingTimeInterval(3 * 86400)),
                       [range("2026-12-30", "2026-12-31")])
    }

    @MainActor func testEmptySuccessfulResponseIsRecordedAndNotQueriedAgain() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BackfillProgressStore(url: url)
        let selected = range("2026-01-01", "2026-01-31")
        var calls = 0
        for _ in 0..<2 {
            try await BackfillRunner.run(range: selected, type: .sleep, scope: "A", store: store, now: now) { _ in
                calls += 1 // Successful empty query: no writes to perform.
            } completed: { _ in }
        }
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testPaginationCapShrinksMonthToWeeksThenDaysOnlyWhenNeeded() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BackfillProgressStore(url: url)
        let selected = range("2026-01-01", "2026-01-31")
        var attempted: [SyncDateRange] = []
        var completed: [SyncDateRange] = []
        try await BackfillRunner.run(range: selected, type: .sleep, scope: "A", store: store, now: now) { part in
            attempted.append(part)
            if part != selected && part.start > selected.start { return }
            if part.endTime - part.startTime + 1 > 86400 { throw MiAPIError.paginationLimit }
        } completed: { completed.append($0) }
        XCTAssertEqual(attempted[0], selected)
        XCTAssertEqual(attempted[1], range("2026-01-01", "2026-01-07"))
        XCTAssertEqual(attempted[2], range("2026-01-01", "2026-01-01"))
        XCTAssertEqual(completed.count, 11) // Seven days + four remaining week fragments.
        XCTAssertTrue(store.pending(scope: "A", type: .sleep, range: selected, now: now).isEmpty)
        for index in 1..<completed.count { XCTAssertEqual(completed[index - 1].endTime + 1, completed[index].startTime) }
    }

    @MainActor func testSingleDayLimitFailsWithoutCheckpointOrRecursion() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BackfillProgressStore(url: url)
        let selected = range("2026-01-01", "2026-01-01")
        var calls = 0
        do {
            try await BackfillRunner.run(range: selected, type: .sleep, scope: "A", store: store, now: now) { _ in
                calls += 1
                throw MiAPIError.paginationLimit
            } completed: { _ in XCTFail("Failed day must not complete") }
            XCTFail("Expected failure")
        } catch let error as BackfillFailure { XCTAssertEqual(error.range, selected) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.pending(scope: "A", type: .sleep, range: selected, now: now), [selected])
    }

    @MainActor func testCursorLoopNetworkAuthAndServerFailuresNeverSubdivide() async throws {
        for error in [MiAPIError.cursorLoop, .network(URLError(.notConnectedToInternet)), .api(code: 70016, message: nil), .http(500)] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = try BackfillProgressStore(url: url)
            let selected = range("2026-01-01", "2026-01-31")
            var calls = 0
            do {
                try await BackfillRunner.run(range: selected, type: .sleep, scope: "A", store: store, now: now) { _ in
                    calls += 1
                    throw error
                } completed: { _ in XCTFail("Must not complete") }
                XCTFail("Expected failure")
            } catch {}
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(store.pending(scope: "A", type: .sleep, range: selected, now: now), [selected])
        }
    }

    @MainActor func testCompletedMonthSurvivesLaterFailureAndResumeSkipsIt() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let selected = range("2026-01-01", "2026-03-31")
        let store = try BackfillProgressStore(url: url)
        var calls = 0
        do {
            try await BackfillRunner.run(range: selected, type: .sleep, scope: "A", store: store, now: now) { _ in
                calls += 1
                if calls == 2 { throw MiAPIError.network(URLError(.notConnectedToInternet)) }
            } completed: { _ in }
            XCTFail("Expected failure")
        } catch {}
        var resumed: [SyncDateRange] = []
        try await BackfillRunner.run(range: selected, type: .sleep, scope: "A", store: BackfillProgressStore(url: url), now: now) {
            resumed.append($0)
        } completed: { _ in }
        XCTAssertEqual(resumed, [range("2026-02-01", "2026-02-28"), range("2026-03-01", "2026-03-31")])
    }

    @MainActor func testCancellationAfterWriteDoesNotMarkCurrentSegment() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BackfillProgressStore(url: url)
        let selected = range("2026-01-01", "2026-01-31")
        let task = Task { @MainActor in
            try await BackfillRunner.run(range: selected, type: .sleep, scope: "A", store: store, now: self.now) { _ in
                withUnsafeCurrentTask { $0?.cancel() } // Simulate cancellation arriving as the write finishes.
            } completed: { _ in XCTFail("Cancelled write must not be checkpointed") }
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.pending(scope: "A", type: .sleep, range: selected, now: now), [selected])
    }

    @MainActor func testCheckpointWriteFailureIsReportedWithoutInMemoryProgress() async throws {
        let parent = temporaryURL().deletingLastPathComponent()
        try Data("blocked-directory".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try BackfillProgressStore(url: parent.appendingPathComponent("progress.json"))
        let selected = range("2026-01-01", "2026-01-31")
        do {
            try await BackfillRunner.run(range: selected, type: .sleep, scope: "A", store: store, now: now) { _ in }
                completed: { _ in XCTFail("Checkpoint failed") }
            XCTFail("Expected storage failure")
        } catch let error as BackfillFailure { XCTAssertTrue(error.underlying is BackfillProgressStore.StoreError) }
        XCTAssertEqual(store.pending(scope: "A", type: .sleep, range: selected, now: now), [selected])
    }

    @MainActor func testCorruptedProgressIsNotTrustedAsCompleted() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try BackfillProgressStore(url: url))
    }
}
