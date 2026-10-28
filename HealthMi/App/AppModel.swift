import Foundation
import HealthKit
import Observation
import SwiftData

enum AppError: LocalizedError {
    case noCredentials
    case healthKitUnavailable
    case protectedDataUnavailable
    case needsInitialSync
    case backgroundBackfill

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "未找到小米凭据，请先在设置页登录。"
        case .healthKitUnavailable: return "当前设备不支持 HealthKit。"
        case .protectedDataUnavailable: return "设备锁定或健康数据暂不可访问；保留进度，待解锁后的调度重试。"
        case .needsInitialSync: return "尚无增量游标，请先在前台完成首次增量同步；历史回填不会建立日常游标。"
        case .backgroundBackfill: return "后台只执行增量同步，请在前台选择历史回填范围。"
        }
    }
}

/// 应用全局状态（主线程）。
@MainActor
@Observable
final class AppModel {
    var isConfigured = false
    var connected = false
    var accountID = ""
    var healthKitAuthorized = false
    var isSyncing = false
    var backfillDays = 30
    var statusMessage = ""
    var lastError: String?
    var outcomes: [SyncDataType: SyncOutcome] = [:]
    /// 最近 N 天数据概览（从 HealthKit 读回，用于 App 内回显）。
    var summary: HealthSummary?
    /// 最近 N 天每日趋势（用于 Charts）。
    var trends: [DailyTrend] = []
    /// 当前正在同步的类型索引和总数（用于进度显示）。
    var currentSyncIndex: Int = 0
    var totalSyncCount: Int = 0
    var backfillCompletedSegments = 0
    var backfillCurrentRange: String?
    private let backfillProgressURL: URL

    init(backfillProgressURL: URL = BackfillProgressStore.defaultURL) {
        self.backfillProgressURL = backfillProgressURL
    }

    /// 同步进度文字，如 "正在同步 3/9"。
    var syncProgressText: String? {
        guard isSyncing, totalSyncCount > 0 else { return nil }
        if let backfillCurrentRange {
            return "本轮已完成 \(backfillCompletedSegments) 段 · \(backfillCurrentRange)"
        }
        return "正在处理第 \(currentSyncIndex) 类（共 \(totalSyncCount) 类）"
    }

    /// 小米凭据是否已过期/无效（需要用户重新登录获取新 token）。
    var authNeedsRefresh = false

    /// 已启用的同步类别（持久化到 UserDefaults，默认全部启用）。
    var enabledTypes: Set<SyncDataType> = Set(SyncDataType.allCases)

    private var engine: SyncEngine?
    private var engineRegion = MiRegion.current
    private var activeTask: Task<SyncRunResult, Never>?
    private var backgroundRun = false
    var automaticSyncEnabled = UserDefaults.standard.bool(forKey: "automatic_sync_enabled")
    var lastSuccessfulSyncAt = UserDefaults.standard.object(forKey: "last_successful_sync_at") as? Date
    var lastSyncFailure = UserDefaults.standard.string(forKey: "last_sync_failure")
    var lastRunMetric: SyncRunMetric?

    func setAutomaticSyncEnabled(_ enabled: Bool) {
        automaticSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "automatic_sync_enabled")
        if !enabled && backgroundRun { activeTask?.cancel() }
        BackgroundSync.schedule()
    }

    func cancelSync() { activeTask?.cancel() }


    // MARK: - 初始化 / 凭据

    func bootstrap() {
        CredentialStore.migrateIfNeeded()
        loadEnabledTypes()
        lastRunMetric = SyncMetricsStore.load().last
        if let cred = CredentialStore.load() {
            isConfigured = true
            accountID = mask(cred.userId)
        }
        refreshHealthKitStatus()
    }

    // MARK: - 同步类别开关

    func isTypeEnabled(_ type: SyncDataType) -> Bool {
        enabledTypes.contains(type)
    }

    func setTypeEnabled(_ type: SyncDataType, enabled: Bool) {
        if enabled {
            enabledTypes.insert(type)
        } else {
            enabledTypes.remove(type)
        }
        UserDefaults.standard.set(
            enabledTypes.map(\.rawValue).sorted(),
            forKey: Self.enabledTypesKey
        )
    }

    private static let enabledTypesKey = "enabled_sync_types"

    private func loadEnabledTypes() {
        guard let raw = UserDefaults.standard.array(forKey: Self.enabledTypesKey) as? [String] else {
            return
        }
        let stored = Set(raw.compactMap(SyncDataType.init(rawValue:)))
        enabledTypes = stored
    }

    func saveCredentials(userId: String, passToken: String) async throws {
        guard !isSyncing else { return }
        try CredentialStore.save(userId: userId, passToken: passToken)
        // A failed account replacement must not keep the previous account's live session.
        self.engine = nil
        connected = false
        let engine = SyncEngine()
        try await engine.connect(userId: userId, passToken: passToken)
        self.engine = engine
        engineRegion = .current
        isConfigured = true
        connected = true
        authNeedsRefresh = false
        accountID = mask(userId)
        refreshHealthKitStatus()
    }

    func disconnect(modelContext: ModelContext? = nil) {
        guard !isSyncing else { return }
        // Stress records are cleared below, so their completion ledger must also
        // be cleared. If disk access fails, leave the account intact for retry.
        do { try BackfillProgressStore.removeAll(url: backfillProgressURL) }
        catch { lastError = Self.describeSyncError(error); return }
        setAutomaticSyncEnabled(false)
        engine = nil
        CredentialStore.delete()
        isConfigured = false
        connected = false
        accountID = ""
        outcomes = [:]
        // 清除同步游标和压力记录，防止切换账号时新账号继承上一个账号的数据
        if let modelContext {
            SyncStateStore.clearAll(in: modelContext)
            StressStore.clearAll(in: modelContext)
            SyncLogStore.clearAll(in: modelContext)
        }
    }

    // MARK: - HealthKit

    func requestHealthKit() async throws {
        guard HealthKitManager.isAvailable else { throw AppError.healthKitUnavailable }
        try await HealthKitManager.requestAuthorization()
        refreshHealthKitStatus()
    }

    func refreshHealthKitStatus() {
        guard HealthKitManager.isAvailable else {
            healthKitAuthorized = false
            return
        }
        // 允许用户只授权睡眠等部分类型，不以步数权限代表全部权限。
        healthKitAuthorized = HealthKitManager.typesToShare.contains { type in
            HealthKitManager.healthStore.authorizationStatus(for: type) == .sharingAuthorized
        }
    }

    // MARK: - 同步

    /// 读取最近 N 天健康摘要和趋势数据用于 App 内回显。
    func refreshSummary(days: Int = 7) async {
        summary = await HealthKitReader.summary(days: days)
        trends = await HealthKitReader.trendSeries(days: days)
    }

    /// 若存在尚未请求过授权的类型（如后来新增的呼吸频率），先弹出 HealthKit 授权。
    func ensureHealthKitAuthorization() async {
        guard HealthKitManager.isAvailable else { return }
        let notDetermined = HealthKitManager.typesToShare.contains { type in
            HealthKitManager.healthStore.authorizationStatus(for: type) == .notDetermined
        }
        guard notDetermined else { return }
        do {
            try await HealthKitManager.requestAuthorization()
            refreshHealthKitStatus()
        } catch {
            lastError = "HealthKit 授权失败：\(error.localizedDescription)"
        }
    }

    /// 所有入口共用 MainActor 上的占用标记，取消后等待工作真正退出才释放。
    @discardableResult
    func syncAll(modelContext: ModelContext, forceBackfill: Bool = false, isBackground: Bool = false,
                 range: SyncDateRange? = nil, recheckCompleted: Bool = false) async -> SyncRunResult {
        guard !isSyncing else { return .busy }
        if isBackground && !automaticSyncEnabled { return .disabled }
        isSyncing = true
        backgroundRun = isBackground
        lastError = nil
        backfillCompletedSegments = 0
        backfillCurrentRange = nil
        let task = Task { await self.performSync(modelContext: modelContext, forceBackfill: forceBackfill,
                                                 isBackground: isBackground, range: range,
                                                 recheckCompleted: recheckCompleted) }
        activeTask = task
        defer { activeTask = nil; isSyncing = false; backgroundRun = false; backfillCurrentRange = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performSync(modelContext: ModelContext, forceBackfill: Bool, isBackground: Bool,
                             range: SyncDateRange?, recheckCompleted: Bool) async -> SyncRunResult {
        let startedAt = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let region = MiRegion.current
        var result: SyncRunResult = .success
        var runEngine: SyncEngine?
        var messages: [SyncDataType: String] = [:]
        var runOutcomes: [SyncDataType: SyncOutcome] = [:]
        do {
            try Task.checkCancellation()
            if isBackground && forceBackfill { throw AppError.backgroundBackfill }
            guard HealthKitManager.isAvailable else { throw AppError.healthKitUnavailable }
            if isBackground && !HealthKitManager.protectedDataAvailable { throw AppError.protectedDataUnavailable }
            if !isBackground { await ensureHealthKitAuthorization() }
            try Task.checkCancellation()
            refreshHealthKitStatus()

            let selected = try range.map {
                try SyncDateRange(start: $0.start, end: $0.end, timeZone: $0.timeZone, now: startedAt)
            } ?? (forceBackfill ? SyncDateRange.recent(days: backfillDays, timeZone: region.timeZone, now: startedAt) : nil)
            let enabled = SyncDataType.allCases.filter { enabledTypes.contains($0) }
            let types = enabled.filter {
                !isBackground || SyncStateStore.state(for: $0, in: modelContext)?.lastSyncedEnd != nil
            }
            if isBackground && types.count < enabled.count {
                result = .deferred
                lastError = AppError.needsInitialSync.localizedDescription
            }
            guard !types.isEmpty else { throw AppError.needsInitialSync }
            totalSyncCount = types.count
            currentSyncIndex = 0

            var backfillStore: BackfillProgressStore?
            var backfillScope = ""
            if forceBackfill, let selected {
                guard let credentials = CredentialStore.load() else { throw AppError.noCredentials }
                backfillScope = BackfillScope.key(userID: credentials.userId, region: region)
                let store = try BackfillProgressStore(url: backfillProgressURL)
                if recheckCompleted { try store.invalidate(scope: backfillScope, types: types, range: selected) }
                backfillStore = store
            }

            if engineRegion != region { engine = nil; connected = false; engineRegion = region }
            if engine == nil { engine = SyncEngine(); connected = false }
            guard let engine else { throw AppError.noCredentials }
            runEngine = engine
            await engine.beginRun(background: isBackground)
            try await ensureEngine()
            try Task.checkCancellation()
            // Keep all types for a month together so sleep / breathing / HRV can
            // reuse the same bounded raw response instead of downloading years
            // of sleep three times. Failed types resume on the next user retry.
            let work: [(type: SyncDataType, range: SyncDateRange?)]
            if forceBackfill, let selected {
                work = BackfillPlanner.split(selected, size: .month).flatMap { part in
                    types.map { (type: $0, range: Optional(part)) }
                }
            } else { work = types.map { (type: $0, range: nil) } }
            var failedTypes = Set<SyncDataType>()
            for item in work {
                let type = item.type
                if failedTypes.contains(type) { continue }
                currentSyncIndex = (types.firstIndex(of: type) ?? 0) + 1
                let highWater = SyncStateStore.state(for: type, in: modelContext)?.lastSyncedEnd
                // 老游标分轮向前追赶；从旧游标回看一天，不能直接跳到最近一天。
                let cutoff = isBackground ? Self.backgroundCutoff(highWater: highWater, now: startedAt, timeZone: region.timeZone) : startedAt
                let window = await engine.syncWindow(highWater: highWater, backfillDays: backfillDays,
                                                     forceBackfill: forceBackfill, range: selected, now: cutoff)
                let queriedRange = try SyncDateRange(start: Date(timeIntervalSince1970: Double(window.startTime)),
                                                    end: Date(timeIntervalSince1970: Double(window.endTime)),
                                                    timeZone: region.timeZone, now: startedAt)
                do {
                    try Task.checkCancellation()
                    if isBackground && !HealthKitManager.protectedDataAvailable { throw AppError.protectedDataUnavailable }
                    let outcome: SyncOutcome
                    if let backfillStore, let part = item.range {
                        outcome = try await syncBackfill(type: type, range: part, scope: backfillScope,
                                                         store: backfillStore, engine: engine,
                                                         modelContext: modelContext, now: startedAt)
                    } else if type == .stress {
                        let fetched = try await engine.syncStress(highWater: highWater, backfillDays: backfillDays,
                                                                 forceBackfill: forceBackfill, range: selected, now: cutoff)
                        try Task.checkCancellation()
                        let added = forceBackfill
                            ? try StressStore.replace(samples: fetched.samples, range: fetched.range, in: modelContext)
                            : try StressStore.save(samples: fetched.samples, in: modelContext)
                        outcome = SyncOutcome(type: .stress, fetched: fetched.samples.count, added: added, highWater: fetched.outcome.highWater)
                    } else {
                        outcome = try await engine.sync(type: type, highWater: highWater, backfillDays: backfillDays,
                                                        forceBackfill: forceBackfill, range: selected, now: cutoff)
                    }
                    try Task.checkCancellation()
                    // 历史重写完全独立于日常游标，既不提前也不回退，首次回填也不创建游标。
                    if !forceBackfill {
                        try SyncStateStore.record(type: type, highWater: outcome.highWater, added: outcome.added, in: modelContext)
                    }
                    let previous = runOutcomes[type]
                    let total = SyncOutcome(type: type, fetched: (previous?.fetched ?? 0) + outcome.fetched,
                                            added: (previous?.added ?? 0) + outcome.added, highWater: outcome.highWater)
                    runOutcomes[type] = total
                    outcomes[type] = total
                    messages[type] = "\(type.displayName) +\(total.added)"
                    SyncLogStore.append(type: type, fetched: outcome.fetched, added: outcome.added, success: true, in: modelContext)
                } catch {
                    let failure = error as? BackfillFailure
                    let cause = failure?.underlying ?? error
                    if Task.isCancelled || error is CancellationError {
                        result = .cancelled
                        lastError = Self.cancellationMessage
                    } else {
                        result = .failed
                        let detail = failure.map { "\n未完成分段：\($0.range.label)" } ?? ""
                        let singleDayLimit: Bool
                        if case MiAPIError.paginationLimit = cause, let failure {
                            singleDayLimit = SyncDateRange.calendar(in: region.timeZone).isDate(failure.range.start, inSameDayAs: failure.range.end)
                        } else { singleDayLimit = false }
                        let advice = singleDayLimit ? "\n已拆到单日仍超过 200 页，本日未记为完成；请稍后重试或检查云端数据。" : ""
                        lastError = "\(type.displayName) · 所选范围：\(queriedRange.label)\(detail)：\(Self.describeSyncError(cause))\(advice)"
                    }
                    failedTypes.insert(type)
                    messages[type] = "\(type.displayName) 未完成"
                    SyncLogStore.append(type: type, fetched: 0, added: 0, success: false, errorMessage: lastError, in: modelContext)
                    if Self.isAuthError(cause) { authNeedsRefresh = true; connected = false; self.engine = nil }
                    // 断网、锁屏、认证过期或系统取消时不对后续类型重复无效请求。
                    if result == .cancelled || Self.shouldDeferRemainingTypes(cause) { break }
                }
            }
        } catch {
            result = Task.isCancelled || error is CancellationError ? .cancelled : .failed
            if error is AppError { result = result == .cancelled ? .cancelled : .deferred }
            lastError = result == .cancelled ? Self.cancellationMessage : Self.describeSyncError(error)
            if Self.isAuthError(error) { authNeedsRefresh = true; connected = false; engine = nil }
        }
        if Task.isCancelled { result = .cancelled; lastError = Self.cancellationMessage }
        statusMessage = messages.isEmpty ? (lastError ?? "本轮未处理数据")
            : SyncDataType.allCases.compactMap { messages[$0] }.joined(separator: "  ")
        if forceBackfill { statusMessage += "\n本轮完成 \(backfillCompletedSegments) 个日期/类型分段；已完成的旧日期会在下次跳过。" }
        if result == .success {
            lastSuccessfulSyncAt = Date()
            lastSyncFailure = nil
            lastError = nil
            UserDefaults.standard.set(lastSuccessfulSyncAt, forKey: "last_successful_sync_at")
            UserDefaults.standard.removeObject(forKey: "last_sync_failure")
        } else {
            lastSyncFailure = lastError
            UserDefaults.standard.set(lastSyncFailure, forKey: "last_sync_failure")
        }
        let counts = await runEngine?.requestCounts() ?? RequestCounts()
        let metric = SyncRunMetric(startedAt: startedAt, durationSeconds: max(0, ProcessInfo.processInfo.systemUptime - uptime),
                                   background: isBackground, backfill: forceBackfill, result: result, counts: counts)
        lastRunMetric = metric
        SyncMetricsStore.append(metric)
        // 后台绝不为 UI 刷趋势/统计，也不弹健康授权；失败原因保留到下次打开 App。
        if !isBackground && !Task.isCancelled { await refreshSummary() }
        return result
    }

    private static let cancellationMessage = "同步已取消；已完成的回填分段已保存，未完成分段下次重试，未完成类型的日常游标不变。"

    private func syncBackfill(type: SyncDataType, range: SyncDateRange, scope: String,
                              store: BackfillProgressStore, engine: SyncEngine,
                              modelContext: ModelContext, now: Date) async throws -> SyncOutcome {
        var fetched = 0
        var added = 0
        try await BackfillRunner.run(range: range, type: type, scope: scope, store: store, now: now) { part in
            self.backfillCurrentRange = "\(type.displayName) · \(part.label)"
            let outcome: SyncOutcome
            if type == .stress {
                let result = try await engine.syncStress(highWater: nil, backfillDays: self.backfillDays,
                                                         forceBackfill: true, range: part, now: now)
                try Task.checkCancellation()
                let saved = try StressStore.replace(samples: result.samples, range: result.range, in: modelContext)
                outcome = SyncOutcome(type: type, fetched: result.samples.count, added: saved, highWater: now)
            } else {
                outcome = try await engine.sync(type: type, highWater: nil, backfillDays: self.backfillDays,
                                                forceBackfill: true, range: part, now: now)
            }
            try Task.checkCancellation()
            fetched += outcome.fetched
            added += outcome.added
        } completed: { _ in
            self.backfillCompletedSegments += 1
        }
        return SyncOutcome(type: type, fetched: fetched, added: added, highWater: now)
    }

    static func backgroundCutoff(highWater: Date?, now: Date, timeZone: TimeZone) -> Date {
        guard let highWater else { return now }
        return min(now, SyncDateRange.calendar(in: timeZone).date(byAdding: .day, value: 1, to: highWater)!)
    }

    static func describeSyncError(_ error: Error) -> String {
        if let error = error as? AppError { return error.localizedDescription }
        if let error = error as? SyncDateRange.RangeError { return error.localizedDescription }
        if let error = error as? BackfillProgressStore.StoreError { return error.localizedDescription }
        if isAuthError(error) { return "小米凭据已过期或无效，请在前台重新登录；进度已保留。" }
        let nsError = error as NSError
        if nsError.domain == HKErrorDomain {
            if nsError.code == HKError.Code.errorAuthorizationDenied.rawValue
                || nsError.code == HKError.Code.errorAuthorizationNotDetermined.rawValue {
                return "健康权限未允许（请在 设置 → 健康 → 数据访问 中允许 HealthMi）"
            }
            if nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue {
                return AppError.protectedDataUnavailable.localizedDescription
            }
            return "健康数据操作失败（code=\(nsError.code)）；未完成进度已保留。"
        }
        if let api = error as? MiAPIError {
            switch api {
            case .paginationLimit, .cursorLoop: return api.localizedDescription
            case .network: return "网络暂不可用；保留进度，稍后重试。"
            case .http(let code): return "云端 HTTP \(code)；保留进度，稍后重试。"
            case .api(let code, _): return "小米 API 错误（code=\(code)）；未完成进度已保留。"
            default: return "云端响应不完整或会话不可用；未完成进度已保留。"
            }
        }
        if error is URLError { return "网络暂不可用；保留进度，稍后重试。" }
        return "同步未完成（\(nsError.domain)，code=\(nsError.code)）；进度已保留。"
    }

    private static func shouldDeferRemainingTypes(_ error: Error) -> Bool {
        if error is BackfillProgressStore.StoreError { return true }
        if isAuthError(error) || error is URLError { return true }
        if case MiAPIError.network = error { return true }
        if case MiAPIError.http(let code) = error, code == 429 || code >= 500 { return true }
        if case AppError.protectedDataUnavailable = error { return true }
        let ns = error as NSError
        return ns.domain == HKErrorDomain && ns.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }

    private func ensureEngine() async throws {
        if connected && engine != nil { return }
        guard let cred = CredentialStore.load(), let engine else { throw AppError.noCredentials }
        try await engine.connect(userId: cred.userId, passToken: cred.passToken)
        try Task.checkCancellation()
        connected = true
        authNeedsRefresh = false
        accountID = mask(cred.userId)
    }

    private static func isAuthError(_ error: Error) -> Bool {
        if case MiLoginError.loginRejected = error { return true }
        return (error as? MiAPIError)?.isAuthError == true
    }

    // MARK: - 工具

    private func mask(_ value: String) -> String {
        guard value.count > 4 else { return "****" }
        return value.prefix(4) + "****"
    }
}
