import Foundation

/// Only completed cloud-query/write intervals, never health values or credentials.
/// Kept separately from SwiftData incremental cursors. Atomic writes make a lost
/// checkpoint cause a safe repeat, rather than skipping unfinished dates.
@MainActor
final class BackfillProgressStore {
    struct Interval: Codable, Equatable {
        var start: Date
        var end: Date
    }
    private struct Document: Codable {
        var version = 1
        var scopes: [String: [String: [Interval]]] = [:]
    }
    enum StoreError: LocalizedError {
        case unreadable, writeFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取本机回填进度；未跳过任何日期，请检查设备存储后重试。"
            case .writeFailed: return "无法保存本机回填进度；本段未记为完成，重试时会重新检查。"
            }
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackfillProgress-v1.json")
    }
    private let url: URL
    private var document: Document

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard document.version == 1,
                      document.scopes.values.allSatisfy({ types in
                          types.values.allSatisfy { $0.allSatisfy { $0.start <= $0.end } }
                      }) else { throw StoreError.unreadable }
            } catch { throw StoreError.unreadable }
        } else {
            document = Document()
        }
    }

    /// Today and yesterday remain open, preserving the existing late-data lookback.
    func pending(scope: String, type: SyncDataType, range: SyncDateRange, now: Date) -> [SyncDateRange] {
        let stableEnd = Self.stableEnd(timeZone: range.timeZone, now: now)
        let completed = (document.scopes[scope]?[type.rawValue] ?? []).compactMap { item -> Interval? in
            let end = min(item.end, stableEnd)
            return item.start <= end ? Interval(start: item.start, end: end) : nil
        }
        return Self.subtract(completed, from: [Interval(start: range.start, end: range.end)]).map {
            // All boundaries originate in region calendar days, including DST days.
            try! SyncDateRange(start: $0.start, end: $0.end, timeZone: range.timeZone, now: range.end)
        }
    }

    func record(scope: String, type: SyncDataType, range: SyncDateRange, now: Date) throws {
        try Task.checkCancellation()
        let end = min(range.end, Self.stableEnd(timeZone: range.timeZone, now: now))
        guard range.start <= end else { return }
        var updated = document
        var types = updated.scopes[scope] ?? [:]
        types[type.rawValue] = Self.merge((types[type.rawValue] ?? []) + [Interval(start: range.start, end: end)])
        updated.scopes[scope] = types
        try persist(updated)
    }

    /// Invalidate BEFORE a forced recheck so cancellation can resume that recheck.
    func invalidate(scope: String, types: [SyncDataType], range: SyncDateRange) throws {
        var updated = document
        for type in types {
            let existing = updated.scopes[scope]?[type.rawValue] ?? []
            updated.scopes[scope, default: [:]][type.rawValue] = Self.subtract(
                [Interval(start: range.start, end: range.end)], from: existing
            )
        }
        try persist(updated)
    }

    static func removeAll(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { throw StoreError.writeFailed }
    }

    private func persist(_ updated: Document) throws {
        try Task.checkCancellation()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        } catch { throw StoreError.writeFailed }
        document = updated
    }

    private static func stableEnd(timeZone: TimeZone, now: Date) -> Date {
        let calendar = SyncDateRange.calendar(in: timeZone)
        return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!.addingTimeInterval(-1)
    }

    private static func merge(_ intervals: [Interval]) -> [Interval] {
        var result: [Interval] = []
        for item in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, item.start <= last.end.addingTimeInterval(1) {
                result[result.count - 1].end = max(last.end, item.end)
            } else { result.append(item) }
        }
        return result
    }

    private static func subtract(_ removed: [Interval], from intervals: [Interval]) -> [Interval] {
        var remaining = intervals
        for cut in merge(removed) {
            remaining = remaining.flatMap { item -> [Interval] in
                guard cut.start <= item.end && cut.end >= item.start else { return [item] }
                var pieces: [Interval] = []
                if item.start < cut.start { pieces.append(Interval(start: item.start, end: cut.start.addingTimeInterval(-1))) }
                if item.end > cut.end { pieces.append(Interval(start: cut.end.addingTimeInterval(1), end: item.end)) }
                return pieces
            }
        }
        return remaining
    }
}
