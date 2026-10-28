import Foundation

@main @MainActor enum Scenarios {
    static var failures = 0
    static var count = 0

    static func check(_ name: String, _ body: () async -> Bool) async {
        Fixture.reset()
        count += 1
        if await body() { print("PASS \(name)") }
        else { failures += 1; print("FAIL \(name)") }
    }

    static func main() async {
        await check("sleep works when steps permission is denied") {
            Fixture.stepPermission = .sharingDenied
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            await model.syncAll(modelContext: context)
            return Fixture.writes == [.sleep] && context.states[.sleep]?.lastSyncedEnd == Fixture.clock
                && model.lastError == nil && !model.isSyncing && model.healthKitAuthorized
        }
        await check("denied steps do not block authorized sleep; failed cursor stays unchanged") {
            Fixture.stepPermission = .sharingDenied
            let model = AppModel()
            model.enabledTypes = [.dailyActivity, .sleep]
            let context = ModelContext()
            let old = Date(timeIntervalSince1970: 100)
            context.states[.dailyActivity] = SyncState(lastSyncedEnd: old)
            context.states[.sleep] = SyncState(lastSyncedEnd: old)
            await model.syncAll(modelContext: context, isBackground: true)
            return Fixture.writes == [.sleep] && context.states[.dailyActivity]?.lastSyncedEnd == old
                && context.states[.sleep]?.lastSyncedEnd == Fixture.clock
                && context.failures == [.dailyActivity] && Fixture.notifications.isEmpty && Fixture.summaryReads == 0
        }
        await check("denied sleep never writes or advances its cursor") {
            Fixture.sleepPermission = .sharingDenied
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            await model.syncAll(modelContext: context)
            return Fixture.writes.isEmpty && context.states.isEmpty
                && context.failures == [.sleep] && model.lastError != nil && !model.isSyncing
        }
        for background in [false, true] {
            await check("overlapping \(background ? "background" : "foreground") request is ignored") {
                let gate = ConnectionGate()
                Fixture.gate = gate
                let model = AppModel()
                model.enabledTypes = [.sleep]
                let context = ModelContext()
                let first = Task { await model.syncAll(modelContext: context) }
                await gate.waitUntilEntered()
                // Only the first connect pauses. Old code starts a second sync and
                // finishes it here; fixed code returns without disturbing the first.
                model.statusMessage = "first task is waiting"
                model.lastError = "preserve active task status"
                await model.syncAll(modelContext: context, forceBackfill: true, isBackground: background)
                let preserved = model.isSyncing && Fixture.connectionCount == 1 && Fixture.calls.isEmpty
                    && model.statusMessage == "first task is waiting"
                    && model.lastError == "preserve active task status"
                gate.release()
                _ = await first.value
                return preserved && Fixture.writes == [.sleep] && !model.isSyncing
            }
        }
        await check("a later sequential sync is still permitted") {
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            await model.syncAll(modelContext: context)
            await model.syncAll(modelContext: context)
            return Fixture.calls.count == 2 && Fixture.connectionCount == 1
                && Fixture.calls.last?.highWater == Fixture.clock && !model.isSyncing
        }
        await check("missing credentials releases guard and allows retry") {
            Fixture.credentialsExist = false
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            await model.syncAll(modelContext: context)
            let failedCleanly = !model.isSyncing && model.lastError != nil && Fixture.calls.isEmpty
            Fixture.credentialsExist = true
            await model.syncAll(modelContext: context)
            return failedCleanly && Fixture.writes == [.sleep] && !model.isSyncing
        }
        await check("connection failure releases guard and allows retry") {
            Fixture.failConnection = true
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            await model.syncAll(modelContext: context)
            let failedCleanly = !model.isSyncing && model.authNeedsRefresh && Fixture.calls.isEmpty
            Fixture.failConnection = false
            await model.syncAll(modelContext: context)
            return failedCleanly && Fixture.writes == [.sleep] && !model.isSyncing
        }
        await check("unavailable HealthKit stops before connecting") {
            Fixture.available = false
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            await model.syncAll(modelContext: context)
            return Fixture.connectionCount == 0 && Fixture.calls.isEmpty
                && context.states.isEmpty && model.lastError != nil && !model.isSyncing
        }
        await check("90-day backfill is calendar-month bounded and ignores incremental cursor") {
            let model = AppModel()
            model.enabledTypes = [.sleep]
            model.backfillDays = 90
            let context = ModelContext()
            let old = Date(timeIntervalSince1970: 100)
            context.states[.sleep] = SyncState(lastSyncedEnd: old)
            await model.syncAll(modelContext: context, forceBackfill: true)
            guard let call = Fixture.calls.first else { return false }
            let range = SyncDateRange.recent(days: 90, timeZone: MiRegion.cn.timeZone)
            return Fixture.calls.count >= 3 && call.type == .sleep && call.forceBackfill
                && call.backfillDays == 90 && call.highWater == nil
                && call.range?.start == range.start && Fixture.calls.last?.range?.end == range.end
                && context.states[.sleep]?.lastSyncedEnd == old
        }
        await check("pressure backfill preserves history outside the selected range") {
            let model = AppModel()
            model.enabledTypes = [.stress]
            let context = ModelContext()
            let old = MiStressSample(timestamp: Fixture.clock.addingTimeInterval(-30 * 86400), stressScore: 20)
            let stale = MiStressSample(timestamp: Fixture.clock.addingTimeInterval(-86400), stressScore: 30)
            let fresh = MiStressSample(timestamp: stale.timestamp, stressScore: 40)
            context.stressRecords = [old, stale]
            Fixture.stressSamples = [fresh]
            await model.syncAll(modelContext: context, forceBackfill: true)
            return context.stressRecords == [old, fresh] && context.states[.stress] == nil
        }
        await check("pressure save failure preserves history and does not advance cursor") {
            let model = AppModel()
            model.enabledTypes = [.stress]
            let context = ModelContext()
            let old = MiStressSample(timestamp: Fixture.clock.addingTimeInterval(-86400), stressScore: 20)
            context.stressRecords = [old]
            Fixture.stressSamples = [MiStressSample(timestamp: old.timestamp, stressScore: 40)]
            Fixture.failStressSave = true
            await model.syncAll(modelContext: context, forceBackfill: true)
            return context.stressRecords == [old] && context.states[.stress] == nil
                && context.failures == [.stress] && model.lastError != nil
        }
        for withCursor in [false, true] {
            await check("custom single-day backfill never creates or changes incremental cursor: \(withCursor)") {
                let model = AppModel()
                model.enabledTypes = [.sleep, .stress]
                let context = ModelContext()
                let old = Fixture.clock.addingTimeInterval(-60 * 86400)
                if withCursor {
                    context.states[.sleep] = SyncState(lastSyncedEnd: old)
                    context.states[.stress] = SyncState(lastSyncedEnd: old)
                }
                let day = Fixture.clock.addingTimeInterval(-30 * 86400)
                let range = try! SyncDateRange(start: day, end: day, timeZone: MiRegion.cn.timeZone)
                let result = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
                let repeated = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
                return result == .success && repeated == .success
                    && context.states[.sleep]?.lastSyncedEnd == (withCursor ? old : nil)
                    && context.states[.stress]?.lastSyncedEnd == (withCursor ? old : nil)
                    && Fixture.calls.allSatisfy { $0.forceBackfill && $0.range == range }
            }
        }
        await check("old historical backfill cannot roll a newer incremental cursor backward") {
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            context.states[.sleep] = SyncState(lastSyncedEnd: Fixture.clock)
            let day = Fixture.clock.addingTimeInterval(-100 * 86400)
            let range = try! SyncDateRange(start: day, end: day, timeZone: MiRegion.cn.timeZone)
            await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            return context.states[.sleep]?.lastSyncedEnd == Fixture.clock
        }
        await check("pagination failure includes type, selected dates, 200-page limit and segmentation advice") {
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            let old = Fixture.clock.addingTimeInterval(-5 * 86400)
            context.states[.sleep] = SyncState(lastSyncedEnd: old)
            let day = Fixture.clock.addingTimeInterval(-30 * 86400)
            let range = try! SyncDateRange(start: day, end: day, timeZone: MiRegion.cn.timeZone)
            Fixture.syncError = MiAPIError.paginationLimit
            let result = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            let error = model.lastError ?? ""
            return result == .failed && context.states[.sleep]?.lastSyncedEnd == old
                && error.contains("睡眠") && error.contains(range.label) && error.contains("200")
                && error.contains("按月、周或天") && model.lastSuccessfulSyncAt == nil
                && model.lastRunMetric?.result == .failed
        }
        await check("background skips first sync without connecting or refreshing UI") {
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            let result = await model.syncAll(modelContext: context, isBackground: true)
            return result == .deferred && Fixture.connectionCount == 0 && Fixture.calls.isEmpty
                && Fixture.summaryReads == 0 && Fixture.authorizationRequests == 0 && context.states.isEmpty
        }
        await check("background does incremental catchup only, retains lookback and avoids UI reads") {
            let model = AppModel()
            model.enabledTypes = [.sleep]
            model.backfillDays = 3650
            let context = ModelContext()
            let old = Fixture.clock.addingTimeInterval(-90 * 86400)
            context.states[.sleep] = SyncState(lastSyncedEnd: old)
            let result = await model.syncAll(modelContext: context, isBackground: true)
            guard let call = Fixture.calls.first else { return false }
            return result == .success && !call.forceBackfill && call.range == nil && call.highWater == old
                && abs(call.now.timeIntervalSince(old) - 86400) < 1
                && Fixture.summaryReads == 0 && Fixture.authorizationRequests == 0
                && model.lastSuccessfulSyncAt != nil
        }
        await check("background refuses explicit backfill even if called incorrectly") {
            let model = AppModel()
            let result = await model.syncAll(modelContext: ModelContext(), forceBackfill: true, isBackground: true)
            return result == .deferred && Fixture.calls.isEmpty && Fixture.connectionCount == 0
        }
        await check("automatic sync switch off prevents a queued background run") {
            let model = AppModel()
            model.automaticSyncEnabled = false
            let result = await model.syncAll(modelContext: ModelContext(), isBackground: true)
            return result == .disabled && Fixture.connectionCount == 0 && Fixture.calls.isEmpty
        }
        await check("locked background defers without making requests or moving cursor") {
            Fixture.protectedDataAvailable = false
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            context.states[.sleep] = SyncState(lastSyncedEnd: Fixture.clock)
            let result = await model.syncAll(modelContext: context, isBackground: true)
            return result == .deferred && Fixture.connectionCount == 0 && Fixture.calls.isEmpty
                && context.states[.sleep]?.lastSyncedEnd == Fixture.clock && Fixture.summaryReads == 0
        }
        await check("offline background stops subsequent types and preserves both cursors") {
            Fixture.syncError = MiAPIError.network(URLError(.notConnectedToInternet))
            let model = AppModel()
            model.enabledTypes = [.heartRate, .sleep]
            let context = ModelContext()
            let old = Fixture.clock.addingTimeInterval(-86400)
            context.states[.heartRate] = SyncState(lastSyncedEnd: old)
            context.states[.sleep] = SyncState(lastSyncedEnd: old)
            let result = await model.syncAll(modelContext: context, isBackground: true)
            return result == .failed && Fixture.calls.count == 1
                && context.states[.heartRate]?.lastSyncedEnd == old && context.states[.sleep]?.lastSyncedEnd == old
                && Fixture.summaryReads == 0 && model.lastSyncFailure != nil
        }
        await check("expired credentials stop later types and require foreground login") {
            Fixture.syncError = MiAPIError.api(code: 70016, message: "synthetic-secret-must-not-be-logged")
            let model = AppModel()
            model.enabledTypes = [.heartRate, .sleep]
            let context = ModelContext()
            context.states[.heartRate] = SyncState(lastSyncedEnd: Fixture.clock)
            context.states[.sleep] = SyncState(lastSyncedEnd: Fixture.clock)
            let result = await model.syncAll(modelContext: context, isBackground: true)
            return result == .failed && Fixture.calls.count == 1 && model.authNeedsRefresh && !model.connected
                && !(model.lastError ?? "").contains("synthetic-secret")
        }
        await check("background cancellation retains cursor and lock until in-flight work returns") {
            let gate = ConnectionGate()
            Fixture.syncGate = gate
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            let old = Fixture.clock.addingTimeInterval(-86400)
            context.states[.sleep] = SyncState(lastSyncedEnd: old)
            let task = Task { await model.syncAll(modelContext: context, isBackground: true) }
            await gate.waitUntilEntered()
            task.cancel()
            model.cancelSync()
            let second = await model.syncAll(modelContext: context, forceBackfill: true)
            let stillLocked = model.isSyncing && second == .busy && Fixture.calls.count == 1
            gate.release()
            let result = await task.value
            return stillLocked && result == .cancelled && !model.isSyncing
                && context.states[.sleep]?.lastSyncedEnd == old && context.successes.isEmpty
                && Fixture.summaryReads == 0 && model.lastSuccessfulSyncAt == nil
        }
        await check("disabling automatic sync cancels active background without advancing cursor") {
            let gate = ConnectionGate()
            Fixture.syncGate = gate
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            context.states[.sleep] = SyncState(lastSyncedEnd: Fixture.clock)
            let task = Task { await model.syncAll(modelContext: context, isBackground: true) }
            await gate.waitUntilEntered()
            model.setAutomaticSyncEnabled(false)
            gate.release()
            let result = await task.value
            return result == .cancelled && context.states[.sleep]?.lastSyncedEnd == Fixture.clock
                && context.successes.isEmpty && !model.isSyncing
        }
        await check("all-history range is bounded by calendar months and shared between types") {
            let model = AppModel()
            model.enabledTypes = [.sleep, .respiratoryRate, .hrv]
            let context = ModelContext()
            let range = SyncDateRange.recent(days: 3650, timeZone: MiRegion.cn.timeZone)
            let result = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            let months = BackfillPlanner.split(range, size: .month)
            let calls = Fixture.calls
            return result == .success && calls.count == months.count * 3 && context.states.isEmpty
                && calls.enumerated().allSatisfy { index, call in
                    call.range == months[index / 3] && call.forceBackfill && call.highWater == nil
                } && model.backfillCompletedSegments == calls.count
        }
        await check("successful historical empty query is skipped even after AppModel restarts") {
            let context = ModelContext()
            let model = AppModel()
            model.enabledTypes = [.sleep]
            Fixture.emptyResponse = true
            let range = oldRange("2026-01-01", "2026-02-28")
            let first = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            let count = Fixture.calls.count
            let reopened = AppModel()
            reopened.enabledTypes = [.sleep]
            let again = await reopened.syncAll(modelContext: context, forceBackfill: true, range: range)
            return first == .success && again == .success && count == 2 && Fixture.calls.count == count
                && reopened.backfillCompletedSegments == 0 && context.states.isEmpty
        }
        await check("failed later month resumes only unfinished dates after restart") {
            let context = ModelContext()
            context.states[.sleep] = SyncState(lastSyncedEnd: Fixture.clock)
            let model = AppModel()
            model.enabledTypes = [.sleep]
            Fixture.errorForCall = { _ in Fixture.calls.count == 2 ? MiAPIError.network(URLError(.notConnectedToInternet)) : nil }
            let range = oldRange("2026-01-01", "2026-03-31")
            let first = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            let saved = model.backfillCompletedSegments
            Fixture.errorForCall = nil
            Fixture.calls = []
            let reopened = AppModel()
            reopened.enabledTypes = [.sleep]
            let second = await reopened.syncAll(modelContext: context, forceBackfill: true, range: range)
            return first == .failed && saved == 1 && second == .success && Fixture.calls.count == 2
                && Fixture.calls.first?.range?.start == oldRange("2026-02-01", "2026-02-28").start
                && context.states[.sleep]?.lastSyncedEnd == Fixture.clock
        }
        await check("overfull month splits to weeks then days without marking failed parents") {
            let context = ModelContext()
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let range = oldRange("2026-01-01", "2026-01-31")
            Fixture.errorForCall = { call in
                guard let part = call.range else { return MiAPIError.notConnected }
                return part.endTime - part.startTime + 1 > 86400 ? MiAPIError.paginationLimit : nil
            }
            let first = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            let attempts = Fixture.calls.count
            let segments = model.backfillCompletedSegments
            Fixture.calls = []
            let again = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            return first == .success && attempts == 37 && segments == 31 && again == .success
                && Fixture.calls.isEmpty && context.states.isEmpty
        }
        await check("cursor loop on a month is not bypassed by date subdivision") {
            let context = ModelContext()
            let model = AppModel()
            model.enabledTypes = [.sleep]
            Fixture.syncError = MiAPIError.cursorLoop
            let result = await model.syncAll(modelContext: context, forceBackfill: true, range: oldRange("2026-01-01", "2026-01-31"))
            return result == .failed && Fixture.calls.count == 1 && model.backfillCompletedSegments == 0
                && (model.lastError ?? "").contains("分页游标循环") && context.states.isEmpty
        }
        await check("forced recheck resets only selected dates and resumes after failure") {
            let context = ModelContext()
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let whole = oldRange("2026-01-01", "2026-03-31")
            _ = await model.syncAll(modelContext: context, forceBackfill: true, range: whole)
            Fixture.syncError = MiAPIError.network(URLError(.notConnectedToInternet))
            _ = await model.syncAll(modelContext: context, forceBackfill: true,
                                    range: oldRange("2026-02-10", "2026-02-12"), recheckCompleted: true)
            Fixture.syncError = nil
            Fixture.calls = []
            let resumed = await model.syncAll(modelContext: context, forceBackfill: true, range: whole)
            return resumed == .success && Fixture.calls.count == 1
                && Fixture.calls[0].range == oldRange("2026-02-10", "2026-02-12")
        }
        await check("recent two days are rechecked while old dates remain skipped") {
            let context = ModelContext()
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let range = SyncDateRange.recent(days: 90, timeZone: MiRegion.cn.timeZone)
            _ = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            Fixture.calls = []
            let result = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            let recent = SyncDateRange.recent(days: 2, timeZone: MiRegion.cn.timeZone)
            return result == .success && Fixture.calls.first?.range?.start == recent.start
                && Fixture.calls.last?.range?.end == recent.end
                && Fixture.calls.allSatisfy { $0.range!.start >= recent.start }
        }
        await check("completion is isolated by account region and newly enabled type") {
            let context = ModelContext()
            let range = oldRange("2026-01-01", "2026-01-31")
            let model = AppModel()
            model.enabledTypes = [.sleep]
            _ = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            model.enabledTypes = [.sleep, .hrv]
            Fixture.calls = []
            _ = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            let newTypeOnly = Fixture.calls.map(\.type) == [.hrv]
            Fixture.userID = "another-synthetic-user"
            let otherAccount = AppModel()
            otherAccount.enabledTypes = [.sleep]
            _ = await otherAccount.syncAll(modelContext: context, forceBackfill: true, range: range)
            MiRegion.current = .us
            let otherRegion = AppModel()
            otherRegion.enabledTypes = [.sleep]
            let regionalRange = try! SyncDateRange(start: range.start, end: range.end, timeZone: MiRegion.us.timeZone)
            _ = await otherRegion.syncAll(modelContext: context, forceBackfill: true, range: regionalRange)
            return newTypeOnly && Fixture.calls.contains { $0.type == .sleep && $0.range == range }
                && Fixture.calls.last?.range?.timeZone == MiRegion.us.timeZone && context.states.isEmpty
        }
        await check("cancelling second month keeps first checkpoint and excludes concurrent background") {
            let gate = ConnectionGate()
            let context = ModelContext()
            context.states[.sleep] = SyncState(lastSyncedEnd: Fixture.clock)
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let range = oldRange("2026-01-01", "2026-03-31")
            Fixture.errorForCall = { _ in
                if Fixture.calls.count == 2 { Fixture.syncGate = gate }
                return nil
            }
            let task = Task { await model.syncAll(modelContext: context, forceBackfill: true, range: range) }
            await gate.waitUntilEntered()
            model.cancelSync()
            let overlapping = await model.syncAll(modelContext: context, isBackground: true)
            let locked = model.isSyncing
            gate.release()
            let cancelled = await task.value
            let checkpointCount = model.backfillCompletedSegments
            Fixture.errorForCall = nil
            Fixture.syncGate = nil
            Fixture.calls = []
            let resumed = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            return overlapping == .busy && locked && cancelled == .cancelled && checkpointCount == 1
                && resumed == .success && Fixture.calls.count == 2
                && context.states[.sleep]?.lastSyncedEnd == Fixture.clock
        }
        await check("checkpoint write failure reports failure and does not mark a successful cloud response") {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-\(UUID())")
            try! Data("blocked".utf8).write(to: parent)
            defer { try? FileManager.default.removeItem(at: parent) }
            let model = AppModel(backfillProgressURL: parent.appendingPathComponent("progress.json"))
            model.enabledTypes = [.sleep, .hrv]
            let context = ModelContext()
            let range = oldRange("2026-01-01", "2026-01-31")
            let result = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            return result == .failed && Fixture.calls.count == 1 && model.backfillCompletedSegments == 0
                && context.states.isEmpty && (model.lastError ?? "").contains("无法保存本机回填进度")
        }
        await check("logout clears historical completion so cleared local stress can be restored") {
            let model = AppModel()
            model.enabledTypes = [.sleep]
            let context = ModelContext()
            let range = oldRange("2026-01-01", "2026-01-31")
            _ = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            model.disconnect(modelContext: context)
            Fixture.calls = []
            _ = await model.syncAll(modelContext: context, forceBackfill: true, range: range)
            return Fixture.calls.count == 1
        }
        await check("failed credential replacement cannot retain the previous live session") {
            let model = AppModel()
            model.enabledTypes = [.sleep]
            _ = await model.syncAll(modelContext: ModelContext())
            guard model.connected else { return false }
            Fixture.failCredentialSave = true
            do {
                try await model.saveCredentials(userId: "synthetic-replacement", passToken: "synthetic-token")
                return false
            } catch { return !model.connected }
        }
        print("\(count - failures)/\(count) virtual scenarios passed")
        if failures != 0 { exit(1) }
    }

    static func oldRange(_ start: String, _ end: String) -> SyncDateRange {
        let formatter = ISO8601DateFormatter()
        return try! SyncDateRange(start: formatter.date(from: start + "T12:00:00Z")!,
                                  end: formatter.date(from: end + "T12:00:00Z")!, timeZone: MiRegion.cn.timeZone)
    }
}
