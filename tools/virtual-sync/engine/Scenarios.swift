import Foundation

@main enum Scenarios {
    static func sleepItem(_ start: Date) throws -> MiItem {
        let ts = Int(start.timeIntervalSince1970)
        let data = try JSONSerialization.data(withJSONObject: [
            "bedtime": ts, "wake_up_time": ts + 3600,
            "items": [["start_time": ts, "end_time": ts + 3600, "state": 2]]
        ])
        return MiItem(time: ts + 3600, zoneOffset: 28800, zoneName: "Asia/Shanghai", sid: "synthetic", key: "sleep", category: nil, valueData: data)
    }
    static func main() async throws {
        var failed = 0
        var count = 0
        func check(_ name: String, _ result: Bool) {
            count += 1
            if !result { failed += 1 }
            print("\(result ? "PASS" : "FAIL") \(name)")
        }
        let today = Date(timeIntervalSince1970: Double(MiAPIClient.dayStartEpoch(of: Date())))
        let morning = today.addingTimeInterval(-86400 + 3600)
        let noon = today.addingTimeInterval(12 * 3600)
        let item = try sleepItem(morning)
        let old = TypeMapper.sleepSamples(MiParser.sleepSessions([item])[0])[0]
        let store = VirtualStore()
        store.samples = [old]
        let engine = SyncEngine(client: MiAPIClient(items: [item]), writer: HealthWriter(store: store))
        _ = try await engine.sync(type: .sleep, highWater: noon, backfillDays: 7)
        check("incremental dedup includes early samples on window's first day", store.samples.count == 1)
        _ = try await engine.sync(type: .sleep, highWater: noon, backfillDays: 7)
        check("repeating incremental sync remains idempotent", store.samples.count == 1)

        let boundary = Int(today.timeIntervalSince1970) - 86400
        let crossingPayload = try JSONSerialization.data(withJSONObject: [
            "bedtime": boundary - 7200, "wake_up_time": boundary + 3600,
            "items": [["start_time": boundary - 7200, "end_time": boundary - 3600, "state": 2],
                      ["start_time": boundary, "end_time": boundary + 3600, "state": 3]]
        ])
        let crossBoundaryItem = MiItem(time: boundary + 3600, zoneOffset: 28800, zoneName: "Asia/Shanghai", sid: "synthetic", key: "sleep", category: nil, valueData: crossingPayload)
        store.samples = TypeMapper.sleepSamples(MiParser.sleepSessions([crossBoundaryItem])[0])
        let crossing = SyncEngine(client: MiAPIClient(items: [crossBoundaryItem]), writer: HealthWriter(store: store))
        _ = try await crossing.sync(type: .sleep, highWater: noon, backfillDays: 7)
        check("sleep stages entirely before the first query day are not duplicated", store.samples.count == 2)

        // A foreign source may even reuse the same external ID. It must remain,
        // and must not suppress this app's own import.
        store.samples = [HKSample(id: old.metadata?[HKMetadataKeyExternalUUID] as! String, type: old.sampleType, start: old.startDate, end: old.endDate, owned: false)]
        await engine.clearCache()
        _ = try await engine.sync(type: .sleep, highWater: noon, backfillDays: 7)
        check("another source's ID does not suppress our import", store.samples.count == 2 && store.samples.filter(\.owned).count == 1)
        store.samples = []
        let duplicateCloud = SyncEngine(client: MiAPIClient(items: [item, item]), writer: HealthWriter(store: store))
        _ = try await duplicateCloud.sync(type: .sleep, highWater: noon, backfillDays: 7)
        check("duplicate cloud records within one batch write once", store.samples.count == 1)
        _ = try await duplicateCloud.sync(type: .sleep, highWater: nil, backfillDays: 7, forceBackfill: true)
        check("backfill also removes duplicates within its incoming batch", store.samples.count == 1)

        // The first selected day's early record must be replaced, not appended.
        let firstDay = today.addingTimeInterval(-6 * 86400 + 1)
        let historyItem = try sleepItem(firstDay)
        let original = TypeMapper.sleepSamples(MiParser.sleepSessions([historyItem])[0])[0]
        store.samples = [original]
        let history = SyncEngine(client: MiAPIClient(items: [historyItem]), writer: HealthWriter(store: store))
        _ = try await history.sync(type: .sleep, highWater: nil, backfillDays: 7, forceBackfill: true)
        check("backfill includes the whole first query day", store.samples.count == 1 && store.samples[0].uuid != original.uuid)

        let recentItem = try sleepItem(today.addingTimeInterval(-3600 * 5))
        let recent = TypeMapper.sleepSamples(MiParser.sleepSessions([recentItem])[0])[0]
        let foreign = HKSample(id: "official-mi-sleep", type: .init(.sleepAnalysis), start: recent.startDate, end: recent.endDate, owned: false)
        let outside = HKSample(id: "old-history", type: .init(.sleepAnalysis), start: today.addingTimeInterval(-30 * 86400))
        store.samples = [recent, foreign, outside]
        store.events = []
        let replacement = SyncEngine(client: MiAPIClient(items: [recentItem]), writer: HealthWriter(store: store))
        store.failSave = true
        do { _ = try await replacement.sync(type: .sleep, highWater: nil, backfillDays: 7, forceBackfill: true) } catch {}
        check("failed replacement save preserves old samples", store.samples.contains { $0.uuid == recent.uuid } && !store.events.contains("delete"))
        store.failSave = false
        store.samples = [recent, foreign, outside]
        store.events = []
        store.failDelete = true
        var deleteError = false
        do { _ = try await replacement.sync(type: .sleep, highWater: nil, backfillDays: 7, forceBackfill: true) }
        catch { deleteError = true }
        check("failed cleanup reports failure and preserves originals", deleteError && store.samples.contains { $0.uuid == recent.uuid })
        store.failDelete = false
        _ = try await replacement.sync(type: .sleep, highWater: nil, backfillDays: 7, forceBackfill: true)
        check("retry resolves interrupted replacement without deleting other sources", store.samples.count == 3 && store.samples.contains { $0.uuid == foreign.uuid } && store.samples.contains { $0.uuid == outside.uuid })
        check("successful replacement saves before deleting the captured old objects", store.events.suffix(2) == ["save", "delete"])

        store.events = []
        let brokenCloud = SyncEngine(client: MiAPIClient(failure: true), writer: HealthWriter(store: store))
        do { _ = try await brokenCloud.sync(type: .sleep, highWater: nil, backfillDays: 7, forceBackfill: true) } catch {}
        check("cloud fetch failure never mutates local samples", store.events.isEmpty)
        let emptyCloud = SyncEngine(client: MiAPIClient(), writer: HealthWriter(store: store))
        _ = try await emptyCloud.sync(type: .sleep, highWater: nil, backfillDays: 7, forceBackfill: true)
        check("empty response conservatively retains existing history", store.events.isEmpty)
        let selectedDay = today.addingTimeInterval(-2 * 86400)
        let range = try SyncDateRange(start: selectedDay, end: selectedDay, timeZone: MiRegion.cn.timeZone)
        let selectedItem = try sleepItem(selectedDay.addingTimeInterval(3600))
        let selectedSample = TypeMapper.sleepSamples(MiParser.sleepSessions([selectedItem])[0])[0]
        let beforeRange = HKSample(id: "before-selection", type: .init(.sleepAnalysis), start: range.start.addingTimeInterval(-60))
        let afterRange = HKSample(id: "after-selection", type: .init(.sleepAnalysis), start: range.end.addingTimeInterval(1))
        store.samples = [beforeRange, selectedSample, afterRange]
        let singleDay = SyncEngine(client: MiAPIClient(items: [selectedItem]), writer: HealthWriter(store: store))
        _ = try await singleDay.sync(type: .sleep, highWater: noon, backfillDays: 3650, forceBackfill: true, range: range)
        _ = try await singleDay.sync(type: .sleep, highWater: noon, backfillDays: 3650, forceBackfill: true, range: range)
        check("single-day repeated backfill retains both outside dates and remains idempotent", store.samples.count == 3 && store.samples.contains { $0.uuid == beforeRange.uuid } && store.samples.contains { $0.uuid == afterRange.uuid })

        let overnightItem = try sleepItem(range.start.addingTimeInterval(-1800))
        let overnight = TypeMapper.sleepSamples(MiParser.sleepSessions([overnightItem])[0])[0]
        // This unrelated prior-day sample lies inside the expanded dedup window.
        let neighbour = HKSample(id: "unrelated-previous-day", type: .init(.sleepAnalysis), start: range.start.addingTimeInterval(-900), end: range.start.addingTimeInterval(-600))
        store.samples = [overnight, neighbour, afterRange]
        let overnightEngine = SyncEngine(client: MiAPIClient(items: [overnightItem]), writer: HealthWriter(store: store))
        _ = try await overnightEngine.sync(type: .sleep, highWater: nil, backfillDays: 1, forceBackfill: true, range: range)
        check("cross-day replacement keeps the whole selected sleep and preserves unrelated prior-day data", store.samples.count == 3 && store.samples.contains { $0.uuid == neighbour.uuid } && store.samples.contains { $0.startDate == overnight.startDate && $0.endDate == overnight.endDate && $0.uuid != overnight.uuid })

        // Both sides of a month boundary are queried independently. The sleep
        // returned on its wake-up day must keep stages on the previous month.
        let formatter = ISO8601DateFormatter()
        let febStart = formatter.date(from: "2026-01-31T16:00:00Z")!
        let janRange = try SyncDateRange(start: formatter.date(from: "2026-01-01T12:00:00Z")!,
                                        end: febStart.addingTimeInterval(-1), timeZone: MiRegion.cn.timeZone)
        let febRange = try SyncDateRange(start: febStart, end: formatter.date(from: "2026-02-28T12:00:00Z")!, timeZone: MiRegion.cn.timeZone)
        let monthCrossing = try sleepItem(febStart.addingTimeInterval(-1800))
        let priorItem = try sleepItem(febStart.addingTimeInterval(-86400))
        let monthStore = VirtualStore()
        monthStore.samples = [foreign, outside]
        let monthClient = MiAPIClient(items: [priorItem, monthCrossing])
        let monthEngine = SyncEngine(client: monthClient, writer: HealthWriter(store: monthStore))
        for _ in 0..<2 {
            for part in [janRange, febRange] {
                for type in [SyncDataType.sleep, .respiratoryRate, .hrv] {
                    _ = try await monthEngine.sync(type: type, highWater: nil, backfillDays: 3650,
                                                  forceBackfill: true, range: part)
                }
            }
        }
        check("repeated month batches keep cross-month sleep complete and preserve other sources",
              monthStore.samples.count == 4
                && monthStore.samples.contains { $0.startDate == febStart.addingTimeInterval(-1800) && $0.endDate == febStart.addingTimeInterval(1800) }
                && monthStore.samples.contains { $0.uuid == foreign.uuid }
                && monthStore.samples.contains { $0.uuid == outside.uuid })
        check("sleep breathing and HRV reuse one query per month", await monthClient.requestCounts().requests == 4)

        store.events = []
        let cancelledTask = Task {
            try Task.checkCancellation()
            _ = try await singleDay.sync(type: .sleep, highWater: nil, backfillDays: 1, forceBackfill: true, range: range)
        }
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value } catch {}
        check("cancelled backfill does not start local replacement", store.events.isEmpty)
        let reusedClient = MiAPIClient(items: [selectedItem])
        let reusedEngine = SyncEngine(client: reusedClient, writer: HealthWriter(store: VirtualStore()))
        for type in [SyncDataType.sleep, .respiratoryRate, .hrv] {
            _ = try await reusedEngine.sync(type: type, highWater: nil, backfillDays: 1, forceBackfill: true, range: range)
        }
        let reusedCounts = await reusedClient.requestCounts()
        check("sleep, respiratory rate and HRV reuse one successful query", reusedCounts.requests == 1)
        let failedClient = MiAPIClient(failure: true)
        let failedEngine = SyncEngine(client: failedClient, writer: HealthWriter(store: VirtualStore()))
        for type in [SyncDataType.sleep, .respiratoryRate, .hrv] {
            do { _ = try await failedEngine.sync(type: type, highWater: nil, backfillDays: 1, forceBackfill: true, range: range) } catch {}
        }
        let failedCounts = await failedClient.requestCounts()
        check("shared sleep query failure is not downloaded again for HRV and respiratory rate", failedCounts.requests == 1)
        print("\(count - failed)/\(count) engine scenarios passed")
        if failed > 0 { exit(1) }
    }
}
