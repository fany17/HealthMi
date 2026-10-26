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
            await model.syncAll(modelContext: context, isBackground: true)
            return Fixture.writes == [.sleep] && context.states[.dailyActivity]?.lastSyncedEnd == old
                && context.states[.sleep]?.lastSyncedEnd == Fixture.clock
                && context.failures == [.dailyActivity] && Fixture.notifications.count == 1
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
                await first.value
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
            return context.stressRecords == [old, fresh] && context.states[.stress]?.lastSyncedEnd == Fixture.clock
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
        print("\(count - failures)/\(count) virtual scenarios passed")
        if failures != 0 { exit(1) }
    }
}
