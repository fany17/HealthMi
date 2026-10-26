import XCTest
@testable import HealthMi

@MainActor
private final class BackgroundGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; entered = true }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class BackgroundRunControllerTests: XCTestCase {
    func testExpirationCancelsWorkerAndCompletesOnlyOnceEvenIfWorkerReturnsSuccess() async {
        let gate = BackgroundGate()
        var completions: [Bool] = []
        var wasCancelled = false
        var finished = false
        let run = BackgroundRunController { completions.append($0) }
        run.start {
            await gate.wait()
            wasCancelled = Task.isCancelled
            finished = true
            return true
        }
        while !gate.entered { await Task.yield() }
        run.expire()
        run.expire()
        XCTAssertEqual(completions, [false])
        gate.release()
        while !finished { await Task.yield() }
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(completions, [false])
    }

    func testFailureIsNotReportedAsSuccess() async {
        var completions: [Bool] = []
        let run = BackgroundRunController { completions.append($0) }
        run.start { false }
        while completions.isEmpty { await Task.yield() }
        run.expire()
        XCTAssertEqual(completions, [false])
    }

    func testNormalCompletionIsNotRepeatedByLateExpiration() async {
        var completions: [Bool] = []
        let run = BackgroundRunController { completions.append($0) }
        run.start { true }
        while completions.isEmpty { await Task.yield() }
        run.expire()
        XCTAssertEqual(completions, [true])
    }

    func testExpirationBeforeStartPreventsWork() async {
        var completions: [Bool] = []
        var started = false
        let run = BackgroundRunController { completions.append($0) }
        run.expire()
        run.start { started = true; return true }
        await Task.yield()
        XCTAssertFalse(started)
        XCTAssertEqual(completions, [false])
    }
}
