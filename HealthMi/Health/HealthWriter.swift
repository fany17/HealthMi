import HealthKit
import Foundation

/// 幂等写入器，复刻 `healthloom.app` 的 `HealthKitWriter` 模式：
/// - 每个样本带 `HKMetadataKeyExternalUUID`；
/// - 写入前按「类型 + 时间段」一次查询已有的 externalID，内存里 diff 后只保存新增批次；
/// - 普通样本回填先保存新数据，再按旧对象身份清理（HK 样本不可变）。
actor HealthWriter {
    private let store: HKHealthStore

    init(store: HKHealthStore = HealthKitManager.healthStore) {
        self.store = store
    }

    /// 该类型在 `[start, end]` 内已写入的 externalID 集合。
    /// 使用软边界（不限制 strictStart/strictEnd），确保跨越窗口起点的睡眠会话不会被漏掉。
    func existingExternalIDs(ofType type: HKSampleType, start: Date, end: Date) async throws -> Set<String> {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID),
            HKQuery.predicateForObjects(from: HKSource.default()),
        ])
        var ids = Set<String>()
        var anchor: Date? = nil
        while true {
            let samples = try await queryPage(type: type, predicate: predicate, anchor: anchor)
            guard !samples.isEmpty else { break }
            for sample in samples {
                if let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String {
                    ids.insert(uuid)
                }
                if let last = samples.last, last.startDate > (anchor ?? .distantPast) {
                    anchor = last.startDate
                }
            }
            if samples.count < Self.pageSize { break }
        }
        return ids
    }

    /// 一次性批量保存（空批次直接跳过）。
    func save(_ batch: [HKObject]) async throws {
        guard !batch.isEmpty else { return }
        try await store.save(batch)
    }

    /// 用 `HKWorkoutBuilder` 构建并保存一条运动记录。
    /// 保留 externalUUID metadata（builder 支持 addMetadata），继续用于去重。
    /// 若草稿包含心率数据，创建关联心率样本并挂载到运动记录上。
    func saveWorkout(_ draft: TypeMapper.WorkoutDraft) async throws -> HKWorkout {
        let config = HKWorkoutConfiguration()
        config.activityType = draft.activityType
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        do {
            try await builder.beginCollection(at: draft.start)
            try await builder.addMetadata([HKMetadataKeyExternalUUID: draft.externalUUID])
            try await builder.endCollection(at: draft.end)
            guard let workout = try await builder.finishWorkout() else {
                throw HealthWriterError.workoutBuildFailed
            }

            // 关联心率样本（平均/最大），用 externalUUID 前缀确保去重
            var hrSamples: [HKQuantitySample] = []
            let hrType = HKQuantityType(.heartRate)
            let hrUnit = HKUnit.count().unitDivided(by: .minute())
            if let avg = draft.avgHeartRateBpm, avg > 0 {
                hrSamples.append(HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: hrUnit, doubleValue: Double(avg)),
                    start: draft.start, end: draft.end,
                    metadata: [HKMetadataKeyExternalUUID: "\(draft.externalUUID)_avg_hr"]
                ))
            }
            if let max = draft.maxHeartRateBpm, max > 0 {
                hrSamples.append(HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: hrUnit, doubleValue: Double(max)),
                    start: draft.start, end: draft.end,
                    metadata: [HKMetadataKeyExternalUUID: "\(draft.externalUUID)_max_hr"]
                ))
            }
            if !hrSamples.isEmpty {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    store.add(hrSamples, to: workout) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if !success {
                            continuation.resume(throwing: HealthWriterError.workoutBuildFailed)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }

            return workout
        } catch {
            builder.discardWorkout()
            throw error
        }
    }

    enum HealthWriterError: LocalizedError {
        case workoutBuildFailed
        var errorDescription: String? { "运动记录构建失败" }
    }

    /// 按 externalID 删除指定类型的对象，返回删除数量。
    @discardableResult
    func delete(ofType type: HKObjectType, externalIDs: Set<String>) async throws -> Int {
        guard !externalIDs.isEmpty else { return 0 }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: Array(externalIDs)),
            HKQuery.predicateForObjects(from: HKSource.default()),
        ])
        return try await withCheckedThrowingContinuation { continuation in
            store.deleteObjects(of: type, predicate: predicate) { _, count, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: count)
                }
            }
        }
    }

    /// 普通样本回填：先保存新数据，再删除本次查询捕获的旧对象。
    /// 不按 externalID 在保存后重查，否则会把相同 externalID 的新样本一并删除。
    /// 这不是原子事务：清理失败/进程中断可能暂留重复，重跑同范围回填可再次清理。
    func replace(_ batch: [HKObject], ofType type: HKSampleType, start: Date, end: Date) async throws {
        guard !batch.isEmpty else { return }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID),
            HKQuery.predicateForObjects(from: HKSource.default()),
        ])
        let previous = try await queryPage(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit)
        try await store.save(batch)
        // 保存失败时不会进入删除；删除失败则上抛，不返回成功游标。
        if !previous.isEmpty {
            try await store.delete(previous)
        }
    }

    // MARK: - 分页查询

    private static let pageSize = 1000

    private func queryPage(
        type: HKSampleType, predicate: NSPredicate, anchor: Date?, limit: Int = HealthWriter.pageSize
    ) async throws -> [HKSample] {
        var combined = predicate
        if let anchor {
            combined = NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate,
                HKQuery.predicateForSamples(withStart: anchor, end: nil),
            ])
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: combined,
                limit: limit, sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }
}
