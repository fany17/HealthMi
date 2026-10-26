import Foundation

struct MiPage: Sendable {
    let items: [MiItem]
    let hasMore: Bool
    let nextKey: String?
}

/// 数据和运动接口共用同一保护；200 是每次查询的页数上限，不是天数。
enum MiPagination {
    static let maxPages = 200
    static func fetch(
        delayNanoseconds: UInt64 = 200_000_000,
        load: @Sendable (String?) async throws -> MiPage
    ) async throws -> [MiItem] {
        var items: [MiItem] = []
        var cursor: String?
        var seen = Set<String>()
        for pageNumber in 1...maxPages {
            try Task.checkCancellation()
            let page = try await load(cursor)
            try Task.checkCancellation()
            items.append(contentsOf: page.items)
            guard page.hasMore else { return items }
            guard let next = page.nextKey, !next.isEmpty else {
                throw MiAPIError.invalidResponse("分页仍有后续数据但缺少游标，未提交本次进度")
            }
            guard seen.insert(next).inserted else { throw MiAPIError.cursorLoop }
            guard pageNumber < maxPages else { throw MiAPIError.paginationLimit }
            cursor = next
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        throw MiAPIError.paginationLimit
    }
}
