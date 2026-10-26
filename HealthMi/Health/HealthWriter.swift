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
        try Task.checkCancellation()
        // 单次窗口查询避免时间戳相同的样本在分页边界反复返回。
        let samples = try await queryPage(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit)
        try Task.checkCancellation()
        return Set(samples.compactMap { $0.metadata?[HKMetadataKeyExternalUUID] as? String })
    }

    /// 一次性批量保存（空批次直接跳过）。
    func save(_ batch: [HKObject]) async throws {
        try Task.checkCancellation()
        guard !batch.isEmpty else { return }
        try await store.save(batch)
    }

    /// 用 `HKWorkoutBuilder` 构建并保存一条运动记录。
    /// 保留 externalUUID metadata（builder 支持 addMetadata），继续用于去重。
    /// 若草稿包含心率数据，创建关联心率样本并挂载到运动记录上。
    func saveWorkout(_ draft: TypeMapper.WorkoutDraft) async throws -> HKWorkout {
        try Task.checkCancellation()
        let config = HKWorkoutConfiguration()
        config.activityType = draft.activityType
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        do {
            try await builder.beginCollection(at: draft.start)
            try Task.checkCancellation()
            try await builder.addMetadata([HKMetadataKeyExternalUUID: draft.externalUUID])
            try await builder.endCollection(at: draft.end)
            try Task.checkCancellation()
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
        try Task.checkCancellation()
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
    func replace(_ batch: [HKObject], ofType type: HKSampleType, start: Date, end: Date,
                 selectedRange: ClosedRange<Date>? = nil) async throws {
        try Task.checkCancellation()
        guard !batch.isEmpty else { return }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID),
            HKQuery.predicateForObjects(from: HKSource.default()),
        ])
        let candidates = try await queryPage(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit)
        let ids = Set(batch.compactMap { $0.metadata?[HKMetadataKeyExternalUUID] as? String })
        let sleepSessions = ids.filter { $0.hasPrefix("mi_fitness_sleep_") && $0.hasSuffix("_inBed") }
            .map { String($0.dropLast("_inBed".count)) + "_" }
        let previous = candidates.filter { sample in
            let id = sample.metadata?[HKMetadataKeyExternalUUID] as? String ?? ""
            // 扩大的睡眠查重窗口不能误删旁边日期的另一段睡眠。
            if ids.contains(id) || sleepSessions.contains(where: { id.hasPrefix($0) }) { return true }
            let range = selectedRange ?? start...end
            return sample.startDate >= range.lowerBound && sample.endDate < range.upperBound.addingTimeInterval(1)
        }
        try Task.checkCancellation()
        try await store.save(batch)
        try Task.checkCancellation()
        // 保存失败时不会进入删除；删除失败则上抛，不返回成功游标。
        if !previous.isEmpty {
            try await store.delete(previous)
        }
    }

    /// 运动回填也先保存，再删除已捕获的旧对象，避免删除后保存失败造成丢失。
    func replaceWorkout(_ draft: TypeMapper.WorkoutDraft) async throws {
        try Task.checkCancellation()
        let ids = [draft.externalUUID, "\(draft.externalUUID)_avg_hr", "\(draft.externalUUID)_max_hr"]
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: ids),
            HKQuery.predicateForObjects(from: HKSource.default()),
        ])
        let workouts = try await queryPage(type: HKObjectType.workoutType(), predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit)
        let heartRates = try await queryPage(type: HKQuantityType(.heartRate), predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit)
        try Task.checkCancellation()
        _ = try await saveWorkout(draft)
        try Task.checkCancellation()
        let previous = workouts + heartRates
        if !previous.isEmpty { try await store.delete(previous) }
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
        let operation = HealthQueryOperation(store: store)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(sampleType: type, predicate: combined, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                    operation.complete(samples: samples ?? [], error: error)
                }
                operation.start(query: query, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

/// HKSampleQuery 没有原生 async 取消；停止查询并且只恢复 continuation 一次。
private final class HealthQueryOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HKHealthStore
    private var query: HKQuery?
    private var continuation: CheckedContinuation<[HKSample], Error>?
    private var cancelled = false

    init(store: HKHealthStore) { self.store = store }

    func start(query: HKQuery, continuation: CheckedContinuation<[HKSample], Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.query = query
        self.continuation = continuation
        store.execute(query)
        lock.unlock()
    }

    func complete(samples: [HKSample], error: Error?) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            query = nil
            return pending
        }
        if let error { pending?.resume(throwing: error) }
        else { pending?.resume(returning: samples) }
    }

    func cancel() {
        let pending = lock.withLock {
            cancelled = true
            let pending = (query, continuation)
            query = nil
            continuation = nil
            return pending
        }
        if let query = pending.0 { store.stop(query) }
        pending.1?.resume(throwing: CancellationError())
    }
}
