@preconcurrency import BackgroundTasks
import Foundation
import os

/// 目标间隔一小时；earliestBeginDate 只是最早时间，实际由 iOS 决定。
@MainActor
enum BackgroundSync {
    static let taskIdentifier = "com.healthmi.HealthMi.sync"
    static let targetInterval: TimeInterval = 60 * 60
    private static var registered = false

    static func register(syncHandler: @escaping @MainActor () async -> SyncRunResult) {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard UserDefaults.standard.bool(forKey: "automatic_sync_enabled") else {
                    refreshTask.setTaskCompleted(success: false)
                    return
                }
                schedule()
                let run = BackgroundRunController { success in
                    refreshTask.setTaskCompleted(success: success)
                    refreshTask.expirationHandler = nil
                }
                refreshTask.expirationHandler = {
                    Task { @MainActor in run.expire() }
                }
                run.start { await syncHandler().succeeded }
            }
        }
    }

    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        guard UserDefaults.standard.bool(forKey: "automatic_sync_enabled") else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: targetInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.backgroundSync.error("后台同步调度失败：\(error.localizedDescription)")
        }
    }
}
