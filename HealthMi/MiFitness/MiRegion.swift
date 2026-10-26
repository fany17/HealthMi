import Foundation

/// 小米健康云区域配置。不同区域使用不同的 API 域名和时区。
enum MiRegion: String, CaseIterable, Identifiable, Sendable {
    case cn, ru, de, i2, sg, us

    var id: String { rawValue }

    /// API 基础域名。中国区直接用 hlth.io.mi.com，其他区域加前缀。
    var baseURL: String {
        switch self {
        case .cn: return "https://hlth.io.mi.com"
        default: return "https://\(rawValue).hlth.io.mi.com"
        }
    }

    /// 该区域的本地时区（用于计算日边界）。
    var timeZone: TimeZone {
        switch self {
        case .cn: return TimeZone(identifier: "Asia/Shanghai")!
        case .i2, .sg: return TimeZone(identifier: "Asia/Singapore")!
        case .ru: return TimeZone(identifier: "Europe/Moscow")!
        case .de: return TimeZone(identifier: "Europe/Berlin")!
        case .us: return TimeZone(identifier: "America/Los_Angeles")!
        }
    }

    var displayName: String {
        switch self {
        case .cn: return "中国大陆"
        case .ru: return "俄罗斯"
        case .de: return "欧洲"
        case .i2: return "国际"
        case .sg: return "新加坡"
        case .us: return "美国"
        }
    }

    /// 当前选中的区域（持久化到 UserDefaults，默认中国大陆）。
    static var current: MiRegion {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? "cn"
            return MiRegion(rawValue: raw) ?? .cn
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.storageKey)
        }
    }

    private static let storageKey = "mi_region"
}
