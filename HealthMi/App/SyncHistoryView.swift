import SwiftData
import SwiftUI

/// 同步历史日志页面。
struct SyncHistoryView: View {
    @Query(sort: \SyncLogEntry.timestamp, order: .reverse) private var entries: [SyncLogEntry]
    @State private var metrics: [SyncRunMetric] = []

    var body: some View {
        List {
            Section("最近 50 轮运行指标（仅本机）") {
                ForEach(metrics.reversed()) { metric in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(metric.background ? "后台增量" : (metric.backfill ? "历史回填" : "前台增量")) · \(metric.result.displayName)")
                        Text(metric.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(String(format: "%.1f", metric.durationSeconds)) 秒 · \(metric.counts.requests) 次请求 · \(metric.counts.retries) 次重试 · \(metric.counts.pages) 页")
                            .font(.caption)
                    }
                }
            }
            Section("各类数据同步记录") {
            if entries.isEmpty {
                ContentUnavailableView("暂无同步记录", systemImage: "clock")
            } else {
                ForEach(entries, id: \.persistentModelID) { entry in
                    logRow(entry)
                }
            }
            }
        }
        .navigationTitle("同步历史")
        .task { metrics = SyncMetricsStore.load() }
    }

    private func logRow(_ entry: SyncLogEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.displayName)
                        .font(.subheadline)
                    if entry.success {
                        Text("+\(entry.added)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                if let error = entry.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("拉取 \(entry.fetched)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SyncHistoryView()
            .modelContainer(for: SyncLogEntry.self)
    }
}
