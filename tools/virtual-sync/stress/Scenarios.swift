import Foundation

@main @MainActor enum Scenarios {
    static func main() throws {
        var count = 0
        var failed = 0
        func check(_ name: String, _ valid: Bool) {
            count += 1
            if !valid { failed += 1 }
            print("\(valid ? "PASS" : "FAIL") \(name)")
        }
        func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        func record(_ seconds: Double, _ value: Int) -> StressRecord {
            StressRecord(externalID: "stress_\(seconds)", timestamp: date(seconds), stressScore: value)
        }
        let container = ModelContainer()
        container.records = [record(99, 1), record(100, 2), record(150, 3), record(200, 4), record(201, 5)]
        let context = ModelContext(container)
        let added = try StressStore.replace(samples: [
            MiStressSample(timestamp: date(100), stressScore: 20),
            MiStressSample(timestamp: date(100), stressScore: 20),
            MiStressSample(timestamp: date(200), stressScore: 40),
            MiStressSample(timestamp: date(201), stressScore: 99),
        ], range: date(100)...date(200), in: context)
        check("replace exactly includes both boundaries and preserves outside history", container.records.map(\.timestamp).sorted() == [date(99),date(100),date(200),date(201)])
        check("duplicate input is inserted once; out-of-range input cannot overwrite history", added == 2 && container.records.first { $0.timestamp == date(201) }?.stressScore == 5)
        check("replacement is committed once using a separate context", container.commits == 1 && context.records.count == 5)
        let before = container.records.map(\.externalID)
        container.failSave = true
        var threw = false
        do { _ = try StressStore.replace(samples: [], range: date(100)...date(200), in: context) }
        catch { threw = true }
        check("save error escapes and committed records remain intact", threw && container.records.map(\.externalID) == before && container.commits == 1)
        container.failSave = false
        container.failFetch = true
        threw = false
        do { _ = try StressStore.replace(samples: [], range: date(100)...date(200), in: context) }
        catch { threw = true }
        check("fetch error cannot turn into destructive empty replacement", threw && container.records.map(\.externalID) == before && container.commits == 1)
        container.failFetch = false
        _ = try StressStore.replace(samples: [], range: date(100)...date(200), in: context)
        check("valid empty replacement clears only its selected range", container.records.map(\.timestamp).sorted() == [date(99),date(201)])
        print("\(count-failed)/\(count) stress scenarios passed")
        if failed > 0 { exit(1) }
    }
}
