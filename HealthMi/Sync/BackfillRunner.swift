import Foundation

enum BackfillPlanner {
    enum Size { case month, week, day }

    /// Calendar months first; an overfull month becomes up-to-seven-day pieces,
    /// then single calendar days. No fixed-second assumptions across DST.
    static func split(_ range: SyncDateRange, size: Size) -> [SyncDateRange] {
        let calendar = SyncDateRange.calendar(in: range.timeZone)
        var start = range.start
        var pieces: [SyncDateRange] = []
        while start <= range.end {
            let next: Date
            switch size {
            case .month: next = calendar.dateInterval(of: .month, for: start)!.end
            case .week: next = calendar.date(byAdding: .day, value: 7, to: start)!
            case .day: next = calendar.date(byAdding: .day, value: 1, to: start)!
            }
            let end = min(range.end, next.addingTimeInterval(-1))
            pieces.append(try! SyncDateRange(start: start, end: end, timeZone: range.timeZone, now: range.end))
            start = end.addingTimeInterval(1)
        }
        return pieces
    }
}

struct BackfillFailure: Error {
    let range: SyncDateRange
    let underlying: Error
}

/// Runs on the same actor/occupancy guard as AppModel. A successful callback must
/// mean ALL writes for that type/range finished before the checkpoint is saved.
@MainActor
enum BackfillRunner {
    static func run(
        range: SyncDateRange, type: SyncDataType, scope: String,
        store: BackfillProgressStore, now: Date,
        attempt: (SyncDateRange) async throws -> Void,
        completed: (SyncDateRange) -> Void
    ) async throws {
        for pending in store.pending(scope: scope, type: type, range: range, now: now) {
            for month in BackfillPlanner.split(pending, size: .month) {
                try await visit(month, size: .month, type: type, scope: scope, store: store,
                                now: now, attempt: attempt, completed: completed)
            }
        }
    }

    private static func visit(
        _ range: SyncDateRange, size: BackfillPlanner.Size, type: SyncDataType,
        scope: String, store: BackfillProgressStore, now: Date,
        attempt: (SyncDateRange) async throws -> Void, completed: (SyncDateRange) -> Void
    ) async throws {
        do {
            try Task.checkCancellation()
            try await attempt(range)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if case MiAPIError.paginationLimit = error,
               SyncDateRange.calendar(in: range.timeZone).startOfDay(for: range.end) > range.start {
                let smaller: BackfillPlanner.Size = size == .month ? .week : .day
                // A short month fragment may already fit within seven days. In
                // that case skip an identical request and split directly by day.
                let weeks = BackfillPlanner.split(range, size: smaller)
                let pieces = weeks.count > 1 ? weeks : BackfillPlanner.split(range, size: .day)
                let actualSize: BackfillPlanner.Size = weeks.count > 1 ? smaller : .day
                for piece in pieces {
                    try await visit(piece, size: actualSize, type: type, scope: scope, store: store,
                                    now: now, attempt: attempt, completed: completed)
                }
                return
            }
            // Cursor loops, auth, network and write failures never trigger subdivision.
            throw BackfillFailure(range: range, underlying: error)
        }
        do {
            try store.record(scope: scope, type: type, range: range, now: now)
            completed(range)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw BackfillFailure(range: range, underlying: error)
        }
    }
}
