import Foundation
import SwiftData
import os

/// 压力记录（来自小米云端 stress key，无 HealthKit 对应类型，存 SwiftData 供 App 内展示）。
@Model
final class StressRecord {
    @Attribute(.unique) var externalID: String
    var timestamp: Date
    var stressScore: Int

    init(externalID: String, timestamp: Date, stressScore: Int) {
        self.externalID = externalID
        self.timestamp = timestamp
        self.stressScore = stressScore
    }
}

/// 压力数据存取（MainActor，SwiftData 上下文非 Sendable）。
@MainActor
enum StressStore {

    /// 批量写入压力记录，按 externalID 去重，返回新增条数。
    @discardableResult
    static func save(samples: [MiStressSample], in context: ModelContext) -> Int {
        guard !samples.isEmpty else { return 0 }
        let ids = Set(samples.map(\.id))
        let existing = fetchExistingIDs(ids: ids, in: context)
        var added = 0
        for sample in samples where !existing.contains(sample.id) {
            context.insert(StressRecord(
                externalID: sample.id,
                timestamp: sample.timestamp,
                stressScore: sample.stressScore
            ))
            added += 1
        }
        if added > 0 {
            do {
                try context.save()
            } catch {
                AppLog.stressStore.error("保存压力记录失败：\(error.localizedDescription)")
            }
        }
        return added
    }

    /// 只替换本次云端查询范围；使用独立上下文一次提交，保存失败不删除持久化历史。
    /// 禁用自动保存，失败时丢弃未提交的上下文，不回滚界面上下文中的其他修改。
    static func replace(samples: [MiStressSample], range: ClosedRange<Date>, in context: ModelContext) throws -> Int {
        let writeContext = ModelContext(context.container)
        writeContext.autosaveEnabled = false
        let start = range.lowerBound
        let end = range.upperBound
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end }
        )
        for record in try writeContext.fetch(descriptor) {
            writeContext.delete(record)
        }
        var seen = Set<String>()
        for sample in samples where range.contains(sample.timestamp) && seen.insert(sample.id).inserted {
            writeContext.insert(StressRecord(externalID: sample.id, timestamp: sample.timestamp, stressScore: sample.stressScore))
        }
        try writeContext.save()
        return seen.count
    }

    /// 删除指定时间范围内的压力记录。
    static func deleteRange(start: Date, end: Date, in context: ModelContext) {
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end }
        )
        if let records = try? context.fetch(descriptor) {
            for record in records {
                context.delete(record)
            }
            try? context.save()
        }
    }

    /// 清除所有压力记录（退出登录时调用）。
    static func clearAll(in context: ModelContext) {
        let descriptor = FetchDescriptor<StressRecord>()
        if let records = try? context.fetch(descriptor) {
            for record in records {
                context.delete(record)
            }
            try? context.save()
        }
    }

    /// 查询最近 N 天的压力记录（按时间排序）。
    static func recent(days: Int, in context: ModelContext) -> [StressRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchExistingIDs(ids: Set<String>, in context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<StressRecord>(
            predicate: #Predicate { ids.contains($0.externalID) }
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return Set(records.map(\.externalID))
    }
}
