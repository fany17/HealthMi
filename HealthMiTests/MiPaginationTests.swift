import XCTest
@testable import HealthMi

private actor PageFixture {
    var calls = 0
    let total: Int
    let repeated: Bool
    let missingCursor: Bool
    init(total: Int, repeated: Bool = false, missingCursor: Bool = false) {
        self.total = total; self.repeated = repeated; self.missingCursor = missingCursor
    }
    func load(_ cursor: String?) -> MiPage {
        calls += 1
        return MiPage(items: [], hasMore: calls < total, nextKey: missingCursor ? nil : (repeated ? "same" : "page-\(calls)"))
    }
}

final class MiPaginationTests: XCTestCase {
    func testExactly200PagesCanComplete() async throws {
        let fixture = PageFixture(total: 200)
        _ = try await MiPagination.fetch(delayNanoseconds: 0) { await fixture.load($0) }
        let calls = await fixture.calls
        XCTAssertEqual(calls, 200)
    }

    func testPage201IsNeverRequestedAndPartialResultIsNotReturned() async {
        let fixture = PageFixture(total: 201)
        do {
            _ = try await MiPagination.fetch(delayNanoseconds: 0) { await fixture.load($0) }
            XCTFail("Expected pagination limit")
        } catch MiAPIError.paginationLimit {} catch { XCTFail("\(error)") }
        let calls = await fixture.calls
        XCTAssertEqual(calls, 200)
    }

    func testRepeatedCursorStillStopsTheQuery() async {
        let fixture = PageFixture(total: 201, repeated: true)
        do {
            _ = try await MiPagination.fetch(delayNanoseconds: 0) { await fixture.load($0) }
            XCTFail("Expected cursor loop")
        } catch MiAPIError.cursorLoop {} catch { XCTFail("\(error)") }
        let calls = await fixture.calls
        XCTAssertEqual(calls, 2)
    }

    func testMissingContinuationIsFailureNotPartialSuccess() async {
        let fixture = PageFixture(total: 2, missingCursor: true)
        do {
            _ = try await MiPagination.fetch(delayNanoseconds: 0) { await fixture.load($0) }
            XCTFail("Expected missing cursor error")
        } catch MiAPIError.invalidResponse {} catch { XCTFail("\(error)") }
    }

    func testCancellationStopsPageDelayBeforeAnotherRequest() async {
        let fixture = PageFixture(total: 200)
        let task = Task { try await MiPagination.fetch(delayNanoseconds: 60_000_000_000) { await fixture.load($0) } }
        while await fixture.calls == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        let calls = await fixture.calls
        XCTAssertEqual(calls, 1)
    }

    func testOfflineAndCancelledNetworkErrorsAreNotRetried() {
        XCTAssertFalse(MiAPIError.network(URLError(.notConnectedToInternet)).isRetriable)
        XCTAssertFalse(MiAPIError.network(URLError(.cancelled)).isRetriable)
        XCTAssertTrue(MiAPIError.network(URLError(.timedOut)).isRetriable)
        XCTAssertFalse(MiAPIError.api(code: 70016, message: nil).isRetriable)
        XCTAssertTrue(MiAPIError.http(401).isAuthError)
    }
}
