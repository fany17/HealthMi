import Foundation

// These doubles intentionally implement only the API used by AppModel.
// They have no network, Keychain, HealthKit or database access.
enum Authorization { case notDetermined, sharingDenied, sharingAuthorized }
struct HKQuantityType: Hashable {
    enum Identifier { case stepCount, sleepAnalysis }
    let identifier: Identifier
    init(_ identifier: Identifier) { self.identifier = identifier }
}
let HKErrorDomain = "VirtualHealthKit"
enum HKError {
    enum Code: Int { case errorAuthorizationDenied = 1, errorAuthorizationNotDetermined = 2, errorDatabaseInaccessible = 3 }
}
enum MiLoginError: Error { case loginRejected }
struct HealthSummary {}
struct DailyTrend {}
struct MiStressSample: Equatable {
    let timestamp: Date
    let stressScore: Int
    var id: String { "stress_\(timestamp.timeIntervalSince1970)" }
}
struct SyncOutcome {
    let type: SyncDataType
    let fetched: Int
    let added: Int
    let highWater: Date
}
struct SyncState { var lastSyncedEnd: Date? }

@MainActor final class ModelContext {
    var states: [SyncDataType: SyncState] = [:]
    var successes: [SyncDataType] = []
    var failures: [SyncDataType] = []
    var stressRecords: [MiStressSample] = []
}

// Deterministically pause the first connection, exposing MainActor reentrancy.
@MainActor final class ConnectionGate {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            blocked = continuation
            entered = true
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        blocked?.resume()
        blocked = nil
    }
}

@MainActor enum Fixture {
    static var available = true
    static var stepPermission: Authorization = .sharingAuthorized
    static var sleepPermission: Authorization = .sharingAuthorized
    static var credentialsExist = true
    static var failConnection = false
    static var connectionCount = 0
    static var gate: ConnectionGate?
    struct Call {
        let type: SyncDataType
        let highWater: Date?
        let backfillDays: Int
        let forceBackfill: Bool
        let range: SyncDateRange?
        let now: Date
    }
    static var calls: [Call] = []
    static var writes: [SyncDataType] = []
    static var notifications: [String] = []
    static var stressSamples: [MiStressSample] = []
    static var failStressSave = false
    static var protectedDataAvailable = true
    static var summaryReads = 0
    static var authorizationRequests = 0
    static var syncError: Error?
    static var syncGate: ConnectionGate?
    static var userID = "synthetic-user"
    static var errorForCall: ((Call) -> Error?)?
    static var emptyResponse = false
    static var failCredentialSave = false
    static var stressRange: ClosedRange<Date> { clock.addingTimeInterval(-7 * 86400)...clock }
    static let clock = Date()

    static func reset() {
        try! BackfillProgressStore.removeAll(url: BackfillProgressStore.defaultURL)
        MiRegion.current = .cn
        userID = "synthetic-user"
        errorForCall = nil
        emptyResponse = false
        failCredentialSave = false
        UserDefaults.standard.set(true, forKey: "automatic_sync_enabled")
        UserDefaults.standard.removeObject(forKey: "last_successful_sync_at")
        UserDefaults.standard.removeObject(forKey: "last_sync_failure")
        protectedDataAvailable = true
        summaryReads = 0
        authorizationRequests = 0
        syncError = nil
        syncGate = nil
        available = true
        stepPermission = .sharingAuthorized
        sleepPermission = .sharingAuthorized
        credentialsExist = true
        failConnection = false
        connectionCount = 0
        gate = nil
        calls = []
        writes = []
        notifications = []
        stressSamples = []
        failStressSave = false
    }
}

@MainActor enum CredentialStore {
    static func migrateIfNeeded() {}
    static func save(userId: String, passToken: String) throws {
        if Fixture.failCredentialSave { throw MiLoginError.loginRejected }
    }
    static func load() -> (userId: String, passToken: String)? {
        Fixture.credentialsExist ? (Fixture.userID, "synthetic-token") : nil
    }
    static func delete() {}
}
// CryptoKit hashing is checked in native XCTest; no real identities enter this harness.
enum BackfillScope {
    static func key(userID: String, region: MiRegion) -> String { "fixture-\(userID)-\(region.rawValue)" }
}
@MainActor struct VirtualHealthStore {
    func authorizationStatus(for type: HKQuantityType) -> Authorization {
        type.identifier == .stepCount ? Fixture.stepPermission : Fixture.sleepPermission
    }
}
@MainActor enum HealthKitManager {
    static var isAvailable: Bool { Fixture.available }
    static var protectedDataAvailable: Bool { Fixture.protectedDataAvailable }
    static let healthStore = VirtualHealthStore()
    static let typesToShare: Set<HKQuantityType> = [.init(.stepCount), .init(.sleepAnalysis)]
    static func requestAuthorization() async throws { Fixture.authorizationRequests += 1 }
}
@MainActor enum HealthKitReader {
    static func summary(days: Int) async -> HealthSummary { Fixture.summaryReads += 1; return HealthSummary() }
    static func trendSeries(days: Int) async -> [DailyTrend] { Fixture.summaryReads += 1; return [] }
}
@MainActor enum NotificationManager {
    static func notifySyncFailure(_ message: String) async { Fixture.notifications.append(message) }
}
@MainActor enum SyncStateStore {
    static func state(for type: SyncDataType, in context: ModelContext) -> SyncState? {
        context.states[type]
    }
    static func record(type: SyncDataType, highWater: Date?, added: Int, in context: ModelContext) throws {
        try Task.checkCancellation()
        context.states[type] = SyncState(lastSyncedEnd: highWater)
    }
    static func clearAll(in context: ModelContext) { context.states = [:] }
}
@MainActor enum StressStore {
    static func clearAll(in context: ModelContext) { context.stressRecords = [] }
    static func save(samples: [MiStressSample], in context: ModelContext) throws -> Int {
        if Fixture.failStressSave { throw MiLoginError.loginRejected }
        context.stressRecords += samples
        return samples.count
    }
    static func replace(samples: [MiStressSample], range: ClosedRange<Date>, in context: ModelContext) throws -> Int {
        if Fixture.failStressSave { throw MiLoginError.loginRejected }
        context.stressRecords.removeAll { range.contains($0.timestamp) }
        context.stressRecords += samples.filter { range.contains($0.timestamp) }
        return samples.count
    }
}
@MainActor enum SyncLogStore {
    static func clearAll(in context: ModelContext) {}
    static func append(type: SyncDataType, fetched: Int, added: Int, success: Bool,
                       errorMessage: String? = nil, in context: ModelContext) {
        if success { context.successes.append(type) } else { context.failures.append(type) }
    }
}
@MainActor enum BackgroundSync { static func schedule() {} }
@MainActor final class SyncEngine {
    let timeZone = MiRegion.current.timeZone
    let overlapDays = 1
    func beginRun(background: Bool) async {}
    func requestCounts() async -> RequestCounts { RequestCounts(requests: Fixture.calls.count, retries: 0, pages: Fixture.calls.count) }
    func connect(userId: String, passToken: String) async throws {
        Fixture.connectionCount += 1
        if Fixture.connectionCount == 1, let gate = Fixture.gate { await gate.pause() }
        if Fixture.failConnection { throw MiLoginError.loginRejected }
    }
    func clearCache() async {}
    func sync(type: SyncDataType, highWater: Date?, backfillDays: Int,
              forceBackfill: Bool = false, range: SyncDateRange? = nil, now: Date = Date()) async throws -> SyncOutcome {
        Fixture.calls.append(.init(type: type, highWater: highWater,
                                   backfillDays: backfillDays, forceBackfill: forceBackfill, range: range, now: now))
        if let error = Fixture.errorForCall?(Fixture.calls.last!) { throw error }
        if let gate = Fixture.syncGate { await gate.pause() }
        if let error = Fixture.syncError { throw error }
        let permission = type == .dailyActivity ? Fixture.stepPermission : Fixture.sleepPermission
        guard permission == .sharingAuthorized else {
            throw NSError(domain: HKErrorDomain, code: HKError.Code.errorAuthorizationDenied.rawValue)
        }
        Fixture.writes.append(type)
        return SyncOutcome(type: type, fetched: Fixture.emptyResponse ? 0 : 1,
                           added: Fixture.emptyResponse ? 0 : 1, highWater: Fixture.clock)
    }
    func syncStress(highWater: Date?, backfillDays: Int,
                    forceBackfill: Bool = false, range: SyncDateRange? = nil, now: Date = Date()) async throws -> (samples: [MiStressSample], outcome: SyncOutcome, range: ClosedRange<Date>) {
        let actualRange = range?.closedRange ?? Fixture.stressRange
        let samples = Fixture.stressSamples.filter { actualRange.contains($0.timestamp) }
        return (samples, SyncOutcome(type: .stress, fetched: samples.count, added: 0, highWater: Fixture.clock), actualRange)
    }
}
