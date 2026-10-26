import Foundation

/// 每次系统任务独立持有工作和完成门闩；到期和正常返回只能完成一次。
@MainActor
final class BackgroundRunController {
    private var worker: Task<Void, Never>?
    private var completed = false
    private let completion: @MainActor (Bool) -> Void

    init(completion: @escaping @MainActor (Bool) -> Void) { self.completion = completion }

    func start(operation: @escaping @MainActor () async -> Bool) {
        guard worker == nil, !completed else { return }
        worker = Task {
            let success = await operation()
            finish(success && !Task.isCancelled)
        }
    }

    func expire() {
        worker?.cancel()
        finish(false)
    }

    private func finish(_ success: Bool) {
        guard !completed else { return }
        completed = true
        completion(success)
    }
}
