import Foundation

let HKMetadataKeyExternalUUID = "externalUUID"
let HKObjectQueryNoLimit = Int.max
struct HKObjectType: Hashable, Sendable {
    enum Identifier: String { case heartRate, sleepAnalysis, workout }
    let name: String
    init(_ id: Identifier) { name = id.rawValue }
    static func workoutType() -> Self { .init(.workout) }
}
typealias HKSampleType = HKObjectType
typealias HKQuantityType = HKObjectType
struct HKSource: Equatable { static func `default`() -> Self { Self() } }
class HKObject: @unchecked Sendable {
    let uuid = UUID()
    var metadata: [String: Any]?
    init(id: String) { metadata = [HKMetadataKeyExternalUUID: id] }
}
final class HKSample: HKObject, @unchecked Sendable {
    let sampleType: HKSampleType
    let startDate: Date
    let endDate: Date
    let owned: Bool
    init(id: String, type: HKSampleType, start: Date, end: Date? = nil, owned: Bool = true) {
        sampleType = type; startDate = start; endDate = end ?? start; self.owned = owned
        super.init(id: id)
    }
}
enum HKQuery {
    static func predicateForSamples(withStart start: Date, end: Date?) -> NSPredicate {
        NSPredicate { object, _ in
            guard let sample = object as? HKSample else { return false }
            return sample.endDate >= start && sample.startDate <= (end ?? .distantFuture)
        }
    }
    static func predicateForObjects(withMetadataKey key: String) -> NSPredicate {
        NSPredicate { object, _ in (object as? HKObject)?.metadata?[key] != nil }
    }
    static func predicateForObjects(from source: HKSource) -> NSPredicate {
        NSPredicate { object, _ in (object as? HKSample)?.owned == true }
    }
}

actor MiAPIClient {
    let items: [MiItem]
    let failure: Bool
    init(items: [MiItem] = [], failure: Bool = false) { self.items = items; self.failure = failure }
    func connect(userId: String, passToken: String) async throws {}
    func fetchData(key: String, startTime: Int, endTime: Int) async throws -> [MiItem] {
        if failure { throw VirtualError.fetch }
        return items.filter { ($0.time ?? 0) >= startTime && ($0.time ?? 0) <= endTime }
    }
    func fetchSportRecords(startTime: Int, endTime: Int) async throws -> [MiItem] { [] }
    static func dayStartEpoch(of day: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return Int(calendar.startOfDay(for: day).timeIntervalSince1970)
    }
    static func dayEndEpoch(of day: Date) -> Int { dayStartEpoch(of: day) + 86399 }
}
enum VirtualError: Error { case fetch, save, delete }

// Only HealthWriter touches this store during each awaited test operation.
// The test harness reads it after that operation completes; no parallel access.
final class VirtualStore: @unchecked Sendable {
    var samples: [HKSample] = []
    var failSave = false
    var failDelete = false
    var events: [String] = []
    func save(_ objects: [HKObject]) async throws {
        events.append("save")
        if failSave { throw VirtualError.save }
        samples += objects.compactMap { $0 as? HKSample }
    }
    func delete(_ objects: [HKObject]) async throws {
        events.append("delete")
        if failDelete { throw VirtualError.delete }
        let ids = Set(objects.map(\.uuid))
        samples.removeAll { ids.contains($0.uuid) }
    }
}
actor HealthWriter {
    static let pageSize = 1000
    let store: VirtualStore
    init(store: VirtualStore = VirtualStore()) { self.store = store }
    func save(_ objects: [HKObject]) async throws {
        if !objects.isEmpty { try await store.save(objects) }
    }
    @discardableResult func delete(ofType type: HKObjectType, externalIDs: Set<String>) async throws -> Int {
        let old = store.samples.filter { $0.sampleType == type && $0.owned && externalIDs.contains($0.metadata?[HKMetadataKeyExternalUUID] as? String ?? "") }
        try await store.delete(old)
        return old.count
    }
    func saveWorkout(_ draft: TypeMapper.WorkoutDraft) async throws -> HKObject { HKObject(id: draft.externalUUID) }
    func queryPage(type: HKSampleType, predicate: NSPredicate, anchor: Date?, limit: Int = 1000) async throws -> [HKSample] {
        Array(store.samples.filter { $0.sampleType == type && predicate.evaluate(with: $0) && $0.endDate >= (anchor ?? .distantPast) }.sorted { $0.startDate < $1.startDate }.prefix(limit))
    }
}
enum TypeMapper {
    struct WorkoutDraft { let externalUUID: String }
    static func sleepSamples(_ session: MiSleepSession) -> [HKSample] {
        session.segments.map { HKSample(id: "sleep_\(Int($0.startAt.timeIntervalSince1970))", type: .init(.sleepAnalysis), start: $0.startAt, end: $0.endAt) }
    }
    static func heartRateSample(_ sample: MiHeartRateSample) -> HKSample? {
        HKSample(id: "hr_\(Int(sample.timestamp.timeIntervalSince1970))", type: .init(.heartRate), start: sample.timestamp)
    }
    static func dailyActivitySamples(_ sample: MiDailyActivity) -> [HKSample] { [] }
    static func spo2Sample(_ sample: MiSpO2Sample) -> HKSample? { nil }
    static func respiratoryRateSample(_ sample: MiRespiratoryRateSample) -> HKSample? { nil }
    static func hrvSample(_ sample: MiHRVSample) -> HKSample? { nil }
    static func bodyMeasurementSamples(_ sample: MiBodyMeasurement) -> [HKSample] { [] }
    static func workoutDraft(_ sample: MiWorkout) -> WorkoutDraft? { nil }
}
