import Foundation
import HealthKit

/// 单次同步的结果摘要。
struct SyncOutcome: Sendable {
    let type: SyncDataType
    let fetched: Int
    let added: Int
    let highWater: Date
}

/// 同步引擎：取数 → 解析 → 映射 → 幂等写入。
///
/// 写法与已验证的 Python 工具保持一致：每次按类型从云端拉取时间区间数据，
/// 用 `HealthWriter` 按 externalID 去重后批量写入 HealthKit。
actor SyncEngine {
    private let client: MiAPIClient
    private let writer: HealthWriter
    private var userId: String?

    /// 增量同步时与上次游标的重叠天数（弥补迟到数据）。
    private let overlapDays = 1

    /// sleep 数据缓存：sleep、respiratoryRate、hrv 三个类型共享同一份睡眠原始数据，
    /// 避免同一次同步中把 sleep key 下载三遍。按 (startTime, endTime) 命中缓存。
    private var sleepCache: (startTime: Int, endTime: Int, items: [MiItem])?

    init(client: MiAPIClient = MiAPIClient(), writer: HealthWriter = HealthWriter()) {
        self.client = client
        self.writer = writer
    }

    /// 清除内部缓存，在一次同步会话开始前调用。
    func clearCache() {
        sleepCache = nil
    }

    /// 获取睡眠原始数据，带缓存（相同时间窗口只下载一次）。
    private func fetchSleepData(startTime: Int, endTime: Int) async throws -> [MiItem] {
        if let cache = sleepCache, cache.startTime == startTime, cache.endTime == endTime {
            return cache.items
        }
        let items = try await client.fetchData(key: "sleep", startTime: startTime, endTime: endTime)
        sleepCache = (startTime, endTime, items)
        return items
    }

    /// 登录并校验凭据。
    func connect(userId: String, passToken: String) async throws {
        try await client.connect(userId: userId, passToken: passToken)
        self.userId = userId
    }

    /// 同步一类数据。
    /// - Parameters:
    ///   - highWater: 上次游标；`nil` 表示首次同步
    ///   - backfillDays: 回填天数（仅在无游标或 `forceBackfill` 时生效）
    ///   - forceBackfill: 为 true 时忽略游标，按 `backfillDays` 重新拉取历史
    func sync(
        type: SyncDataType, highWater: Date?, backfillDays: Int, forceBackfill: Bool = false
    ) async throws -> SyncOutcome {
        let now = Date()
        let start: Date
        if forceBackfill {
            // 重新回填：忽略游标，按所选天数重拉历史
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        } else if let highWater {
            // 增量：从上次游标往前重叠一天，避免迟到数据被漏掉
            start = Calendar.current.date(byAdding: .day, value: -overlapDays, to: highWater) ?? highWater
        } else {
            // 首次同步：按所选天数回填
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        }
        let startTime = MiAPIClient.dayStartEpoch(of: start)
        let endTime = MiAPIClient.dayEndEpoch(of: now)
        // 查重/替换与云端查询使用同一日边界，覆盖首日零点到原始 start 之间的数据。
        let queryStart = Date(timeIntervalSince1970: Double(startTime))
        let queryEnd = Date(timeIntervalSince1970: Double(endTime))

        // 运动记录用 HKWorkoutBuilder 单独写入（不走通用分组保存）
        if type == .workouts {
            return try await syncWorkouts(
                startTime: startTime, endTime: endTime, start: queryStart, end: queryEnd,
                forceBackfill: forceBackfill
            )
        }

        let groups = try await fetchAndMap(type: type, startTime: startTime, endTime: endTime)

        var added = 0
        var fetched = 0
        for group in groups {
            // 云端按睡眠会话时间选中记录时，首段可能在查询日之前；查重必须覆盖完整片段。
            let samples = group.objects.compactMap { $0 as? HKSample }
            let existingStart = min(queryStart, samples.map(\.startDate).min() ?? queryStart)
            let existingEnd = max(queryEnd, samples.map(\.endDate).max() ?? queryEnd)
            if forceBackfill {
                try await writer.replace(
                    group.objects, ofType: group.sampleType, start: existingStart, end: existingEnd
                )
                added += group.objects.count
            } else {
                let existing = try await writer.existingExternalIDs(
                    ofType: group.sampleType, start: existingStart, end: existingEnd
                )
                let fresh = group.objects.filter { object in
                    guard let uuid = object.metadata?[HKMetadataKeyExternalUUID] as? String else {
                        return true
                    }
                    return !existing.contains(uuid)
                }
                try await writer.save(fresh)
                added += fresh.count
            }
            fetched += group.objects.count
        }

        return SyncOutcome(type: type, fetched: fetched, added: added, highWater: now)
    }

    /// 压力数据同步：从云端拉取 stress key，返回解析后的压力样本。
    /// 压力数据无 HealthKit 对应类型，由 AppModel 写入 SwiftData。
    /// - Returns: (压力样本列表, 同步结果摘要, 实际云端查询范围)
    func syncStress(
        highWater: Date?, backfillDays: Int, forceBackfill: Bool = false
    ) async throws -> (samples: [MiStressSample], outcome: SyncOutcome, range: ClosedRange<Date>) {
        let (_, now, startTime, endTime) = syncWindow(
            highWater: highWater, backfillDays: backfillDays, forceBackfill: forceBackfill
        )
        let items = try await client.fetchData(key: "stress", startTime: startTime, endTime: endTime)
        let samples = MiParser.stressSamples(items)
        let range = Date(timeIntervalSince1970: Double(startTime))...Date(timeIntervalSince1970: Double(endTime))
        return (samples, SyncOutcome(type: .stress, fetched: samples.count, added: 0, highWater: now), range)
    }

    // MARK: - 窗口计算

    func syncWindow(
        highWater: Date?, backfillDays: Int, forceBackfill: Bool
    ) -> (start: Date, end: Date, startTime: Int, endTime: Int) {
        let now = Date()
        let start: Date
        if forceBackfill {
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        } else if let highWater {
            start = Calendar.current.date(byAdding: .day, value: -overlapDays, to: highWater) ?? highWater
        } else {
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        }
        return (start, now, MiAPIClient.dayStartEpoch(of: start), MiAPIClient.dayEndEpoch(of: now))
    }

    // MARK: - 取数与映射

    private struct HKGroup {
        let sampleType: HKSampleType
        let objects: [HKObject]
    }

    private func fetchAndMap(type: SyncDataType, startTime: Int, endTime: Int) async throws -> [HKGroup] {
        switch type {
        case .dailyActivity:
            let steps = try await client.fetchData(key: "steps", startTime: startTime, endTime: endTime)
            let calories = try await client.fetchData(key: "calories", startTime: startTime, endTime: endTime)
            let samples = MiParser.dailyActivity(stepsItems: steps, calorieItems: calories)
                .flatMap(TypeMapper.dailyActivitySamples)
            return groupBySampleType(samples)

        case .heartRate:
            let hr = try await client.fetchData(key: "heart_rate", startTime: startTime, endTime: endTime)
            let resting = try await client.fetchData(key: "resting_heart_rate", startTime: startTime, endTime: endTime)
            let samples = MiParser.heartRateSamples(hr, restingItems: resting)
                .compactMap(TypeMapper.heartRateSample)
            return groupBySampleType(samples)

        case .sleep:
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            let samples = MiParser.sleepSessions(items).flatMap(TypeMapper.sleepSamples)
            return groupBySampleType(samples)

        case .spo2:
            let items = try await client.fetchData(key: "spo2", startTime: startTime, endTime: endTime)
            let samples = MiParser.spo2Samples(items).compactMap(TypeMapper.spo2Sample)
            return groupBySampleType(samples)

        case .respiratoryRate:
            // 呼吸频率数据来自睡眠记录的 avg_breath，按睡眠时段各写一条样本
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            let samples = MiParser.respiratoryRateSamples(items)
                .compactMap(TypeMapper.respiratoryRateSample)
            return groupBySampleType(samples)

        case .hrv:
            // HRV 数据来自睡眠记录的 avg_hrv / hrv_median，按睡眠时段各写一条样本
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            let samples = MiParser.hrvSamples(items).compactMap(TypeMapper.hrvSample)
            return groupBySampleType(samples)

        case .bodyMeasurements:
            let items = try await client.fetchData(key: "weight", startTime: startTime, endTime: endTime)
            let samples = MiParser.bodyMeasurements(items).flatMap(TypeMapper.bodyMeasurementSamples)
            return groupBySampleType(samples)

        case .stress:
            // 压力数据不走 HealthKit，由 syncStress 方法处理
            return []

        case .workouts:
            // 不会走到这里：sync() 已将运动路由到 syncWorkouts（HKWorkoutBuilder 专用）
            return []
        }
    }

    /// 运动记录：取数 → 生成草稿 → 用 HKWorkoutBuilder 逐条写入（按 externalUUID 去重）。
    private func syncWorkouts(
        startTime: Int, endTime: Int, start: Date, end: Date, forceBackfill: Bool
    ) async throws -> SyncOutcome {
        let items = try await client.fetchSportRecords(startTime: startTime, endTime: endTime)
        let drafts = MiParser.workouts(items).compactMap(TypeMapper.workoutDraft)
        let workoutType = HKObjectType.workoutType() as HKSampleType
        let existing = try await writer.existingExternalIDs(ofType: workoutType, start: start, end: end)

        var added = 0
        for draft in drafts {
            if forceBackfill {
                if existing.contains(draft.externalUUID) {
                    try await writer.delete(ofType: workoutType, externalIDs: [draft.externalUUID])
                    // 同时删除关联心率样本（avg_hr / max_hr）
                    let hrType = HKQuantityType(.heartRate) as HKObjectType
                    let hrIDs: Set<String> = [
                        "\(draft.externalUUID)_avg_hr",
                        "\(draft.externalUUID)_max_hr",
                    ]
                    try await writer.delete(ofType: hrType, externalIDs: hrIDs)
                }
                _ = try await writer.saveWorkout(draft)
                added += 1
            } else if !existing.contains(draft.externalUUID) {
                _ = try await writer.saveWorkout(draft)
                added += 1
            }
        }
        return SyncOutcome(type: .workouts, fetched: drafts.count, added: added, highWater: Date())
    }

    /// 按 HealthKit 样本类型分组（同一个同步批次内的不同 HK 类型需要分别去重）。
    private func groupBySampleType(_ samples: [HKSample]) -> [HKGroup] {
        Dictionary(grouping: samples, by: { $0.sampleType })
            .map { type, values in
                var seen = Set<String>()
                let unique = values.filter { sample in
                    guard let id = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return true }
                    return seen.insert(id).inserted
                }
                return HKGroup(sampleType: type, objects: unique)
            }
    }
}
