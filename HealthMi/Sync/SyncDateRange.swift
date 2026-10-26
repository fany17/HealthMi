import Foundation

/// 小米区域日历中的闭区间，包含起止两天；结束秒由下一天零点推导，兼容夏令时。
struct SyncDateRange: Equatable, Sendable {
    let start: Date
    let end: Date
    let timeZone: TimeZone

    init(start: Date, end: Date, timeZone: TimeZone, now: Date = Date()) throws {
        let calendar = Self.calendar(in: timeZone)
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last else { throw RangeError.reversed }
        guard last <= calendar.startOfDay(for: now) else { throw RangeError.future }
        self.start = first
        self.end = calendar.date(byAdding: .day, value: 1, to: last)!.addingTimeInterval(-1)
        self.timeZone = timeZone
    }

    static func recent(days: Int, timeZone: TimeZone, now: Date = Date()) -> Self {
        let calendar = calendar(in: timeZone)
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today)!
        // first <= today, so this cannot fail validation.
        return try! Self(start: first, end: today, timeZone: timeZone, now: now)
    }

    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    var startTime: Int { Int(start.timeIntervalSince1970) }
    var endTime: Int { Int(end.timeIntervalSince1970) }
    var closedRange: ClosedRange<Date> { start...end }
    var label: String {
        let formatter = DateFormatter()
        formatter.calendar = Self.calendar(in: timeZone)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: start)) 至 \(formatter.string(from: end))（含起止两天，\(timeZone.identifier)）"
    }

    enum RangeError: LocalizedError {
        case reversed, future
        var errorDescription: String? {
            switch self {
            case .reversed: return "开始日期不能晚于结束日期。"
            case .future: return "不能选择小米区域时区中的未来日期。"
            }
        }
    }
}
