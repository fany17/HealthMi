import CryptoKit
import Foundation

enum BackfillScope {
    /// Stable for token refresh, isolated by account AND region. Raw user IDs and
    /// tokens are never written to the progress file or exposed in the UI/logs.
    static func key(userID: String, region: MiRegion) -> String {
        let encoded = try! JSONEncoder().encode(["backfill-v1", userID, region.rawValue, region.timeZone.identifier])
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}
