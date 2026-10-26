import Foundation

/// 仅计数，不保存 URL、请求体、账号、Token 或健康样本。
struct RequestCounts: Codable, Equatable, Sendable {
    var requests = 0
    var retries = 0
    var pages = 0
}

final class RequestMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = RequestCounts()
    func request() { lock.withLock { counts.requests += 1 } }
    func retry() { lock.withLock { counts.retries += 1 } }
    func page() { lock.withLock { counts.pages += 1 } }
    func reset() { lock.withLock { counts = RequestCounts() } }
    var snapshot: RequestCounts { lock.withLock { counts } }
}

enum SyncRunResult: String, Codable, Sendable {
    case success, failed, cancelled, deferred, busy, disabled
    var succeeded: Bool { self == .success }
    var displayName: String {
        switch self {
        case .success: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .deferred: return "待重试"
        case .busy: return "已有同步运行"
        case .disabled: return "自动同步关闭"
        }
    }
}

struct SyncRunMetric: Codable, Identifiable, Sendable {
    var id = UUID()
    let startedAt: Date
    let durationSeconds: Double
    let background: Bool
    let backfill: Bool
    let result: SyncRunResult
    let counts: RequestCounts
}

/// 不改变 SwiftData schema；旧版本的游标、压力记录及日志保持兼容。
@MainActor
enum SyncMetricsStore {
    private static let key = "sync_run_metrics_v1"
    static func load() -> [SyncRunMetric] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SyncRunMetric].self, from: data)) ?? []
    }
    static func append(_ metric: SyncRunMetric) {
        let entries = Array((load() + [metric]).suffix(50))
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
