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
        await check("backfill arguments still reach the engine unchanged") {
            let model = AppModel()
            model.enabledTypes = [.sleep]
            model.backfillDays = 90
            let context = ModelContext()
            let old = Date(timeIntervalSince1970: 100)
            context.states[.sleep] = SyncState(lastSyncedEnd: old)
            await model.syncAll(modelContext: context, forceBackfill: true)
            guard let call = Fixture.calls.first else { return false }
            return Fixture.calls.count == 1 && call.type == .sleep && call.forceBackfill
                && call.backfillDays == 90 && call.highWater == old
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
        print("\(count - failures)/\(count) virtual scenarios passed")
        if failures != 0 { exit(1) }
    }
}
