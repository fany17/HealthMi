import Foundation

struct MiStressSample {
    let timestamp: Date
    let stressScore: Int
    var id: String { "stress_\(timestamp.timeIntervalSince1970)" }
}
final class StressRecord {
    var externalID: String
    var timestamp: Date
    var stressScore: Int
    init(externalID: String, timestamp: Date, stressScore: Int) {
        self.externalID = externalID; self.timestamp = timestamp; self.stressScore = stressScore
    }
}
struct FetchDescriptor<T> { let predicate: (T) -> Bool }
enum StorageError: Error { case save, fetch }
@MainActor final class ModelContainer {
    var records: [StressRecord] = []
    var failSave = false
    var failFetch = false
    var commits = 0
}
// Emulates a context's pending changes and an all-or-nothing save. Actual
// SwiftData transaction and UI merge behavior still require Apple-platform tests.
@MainActor final class ModelContext {
    let container: ModelContainer
    var autosaveEnabled = true
    var records: [StressRecord]
    init(_ container: ModelContainer) { self.container = container; records = container.records }
    func fetch(_ descriptor: FetchDescriptor<StressRecord>) throws -> [StressRecord] {
        if container.failFetch { throw StorageError.fetch }
        return records.filter(descriptor.predicate)
    }
    func insert(_ record: StressRecord) { records.append(record) }
    func delete(_ record: StressRecord) { records.removeAll { $0 === record } }
    func save() throws {
        if container.failSave { throw StorageError.save }
        container.records = records
        container.commits += 1
    }
}
