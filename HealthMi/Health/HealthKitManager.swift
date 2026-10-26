import HealthKit
import Foundation
import UIKit

/// HealthKit 授权与类型清单。
enum HealthKitManager {
    static let healthStore = HKHealthStore()

    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    @MainActor static var protectedDataAvailable: Bool { UIApplication.shared.isProtectedDataAvailable }

    /// 需要写入（并读取用于去重）的健康数据类型。
    static let typesToShare: Set<HKSampleType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.bodyMass),
        HKQuantityType(.bodyMassIndex),
        HKQuantityType(.leanBodyMass),
        HKQuantityType(.basalEnergyBurned),
        HKQuantityType(.bodyFatPercentage),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType(),
    ]

    static let typesToRead: Set<HKObjectType> = typesToShare

    /// 请求读写授权（系统会展示授权弹窗）。
    static func requestAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
    }
}
