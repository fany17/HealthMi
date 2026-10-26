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

    /// 同步进度文字，如 "正在同步 3/9"。
    var syncProgressText: String? {
        guard isSyncing, totalSyncCount > 0 else { return nil }
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
                 range: SyncDateRange? = nil) async -> SyncRunResult {
        guard !isSyncing else { return .busy }
        if isBackground && !automaticSyncEnabled { return .disabled }
        isSyncing = true
        backgroundRun = isBackground
        lastError = nil
        let task = Task { await self.performSync(modelContext: modelContext, forceBackfill: forceBackfill,
                                                 isBackground: isBackground, range: range) }
        activeTask = task
        defer { activeTask = nil; isSyncing = false; backgroundRun = false }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performSync(modelContext: ModelContext, forceBackfill: Bool, isBackground: Bool,
                             range: SyncDateRange?) async -> SyncRunResult {
        let startedAt = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let region = MiRegion.current
        var result: SyncRunResult = .success
        var runEngine: SyncEngine?
        var messages: [String] = []
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

            if engineRegion != region { engine = nil; connected = false; engineRegion = region }
            if engine == nil { engine = SyncEngine(); connected = false }
            guard let engine else { throw AppError.noCredentials }
            runEngine = engine
            await engine.beginRun(background: isBackground)
            try await ensureEngine()
            try Task.checkCancellation()
            for type in types {
                currentSyncIndex += 1
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
                    if type == .stress {
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
                    outcomes[type] = outcome
                    messages.append("\(type.displayName) +\(outcome.added)")
                    SyncLogStore.append(type: type, fetched: outcome.fetched, added: outcome.added, success: true, in: modelContext)
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        result = .cancelled
                        lastError = "同步已取消；未完成类型的游标保持不变，可稍后重试。"
                    } else {
                        result = .failed
                        lastError = "\(type.displayName) · \(queriedRange.label)：\(Self.describeSyncError(error))"
                    }
                    messages.append("\(type.displayName) 未完成")
                    SyncLogStore.append(type: type, fetched: 0, added: 0, success: false, errorMessage: lastError, in: modelContext)
                    if Self.isAuthError(error) { authNeedsRefresh = true; connected = false; self.engine = nil }
                    // 断网、锁屏、认证过期或系统取消时不对后续类型重复无效请求。
                    if result == .cancelled || Self.shouldDeferRemainingTypes(error) { break }
                }
            }
        } catch {
            result = Task.isCancelled || error is CancellationError ? .cancelled : .failed
            if error is AppError { result = result == .cancelled ? .cancelled : .deferred }
            lastError = result == .cancelled ? "同步已取消；未完成类型的游标保持不变，可稍后重试。" : Self.describeSyncError(error)
            if Self.isAuthError(error) { authNeedsRefresh = true; connected = false; engine = nil }
        }
        if Task.isCancelled { result = .cancelled; lastError = "同步已取消；未完成类型的游标保持不变，可稍后重试。" }
        statusMessage = messages.isEmpty ? (lastError ?? "本轮未处理数据") : messages.joined(separator: "  ")
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

    static func backgroundCutoff(highWater: Date?, now: Date, timeZone: TimeZone) -> Date {
        guard let highWater else { return now }
        return min(now, SyncDateRange.calendar(in: timeZone).date(byAdding: .day, value: 1, to: highWater)!)
    }

    static func describeSyncError(_ error: Error) -> String {
        if let error = error as? AppError { return error.localizedDescription }
        if let error = error as? SyncDateRange.RangeError { return error.localizedDescription }
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
