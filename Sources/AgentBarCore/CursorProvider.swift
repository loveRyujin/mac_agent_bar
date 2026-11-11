import Foundation
import SQLite3

/// 以只读方式读取 Cursor 的 `state.vscdb`（SQLite，表 `ItemTable`）。
/// 只查询订阅相关的三个键，不读取 `accessToken`、`refreshToken`。
public struct CursorProvider: Provider {
    public let id = "cursor"
    public let displayName = "Cursor"
    public let iconName: String? = "cursor"

    private static let membershipKey = "cursorAuth/stripeMembershipType"
    private static let subscriptionStatusKey = "cursorAuth/stripeSubscriptionStatus"
    private static let emailKey = "cursorAuth/cachedEmail"

    private let file: HomeFile

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        file = HomeFile(home: home, relativePath: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    public func isInstalled() -> Bool { file.exists }

    public func fetchStatus() async throws -> SubscriptionStatus {
        guard file.exists else { throw ProviderError.fileNotFound(file.displayPath) }
        let items = try readItems()

        let email = items[Self.emailKey]
        let membership = items[Self.membershipKey]
        let subscriptionStatus = items[Self.subscriptionStatusKey]
        if email == nil, membership == nil, subscriptionStatus == nil {
            return SubscriptionStatus(plan: Plan(rawValue: "", displayName: "未登录"), state: .signedOut)
        }

        let state: SubscriptionStatus.State
        switch (membership, subscriptionStatus) {
        case (nil, _): state = .unknown
        case (_, nil), (_, "active"): state = .active  // 免费套餐没有订阅状态
        case (_, "trialing"): state = .trial
        default: state = .unknown
        }

        return SubscriptionStatus(
            plan: membership.map(Self.plan) ?? Plan(rawValue: "", displayName: "未知套餐"),
            state: state,
            account: email,
            details: subscriptionStatus.map { [Detail("stripeSubscriptionStatus", $0)] } ?? []
        )
    }

    /// `pro` → “Pro”，`pro_plus` → “Pro+”，`free` → “Free”；未知值原样显示。
    static func plan(_ membership: String) -> Plan {
        let names = [
            "free": "Free",
            "free_trial": "Free Trial",
            "pro": "Pro",
            "pro_plus": "Pro+",
            "ultra": "Ultra",
            "business": "Business",
            "enterprise": "Enterprise",
        ]
        return names[membership].map { Plan(rawValue: membership, displayName: $0) } ?? .unrecognized(membership)
    }

    /// 只读打开数据库，读出三个订阅相关的键。Cursor 运行时数据库处于 WAL 模式，被占用时抛出可读的错误。
    private func readItems() throws -> [String: String] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(file.url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw error(db)
        }
        sqlite3_busy_timeout(db, 300)

        let keys = [Self.membershipKey, Self.subscriptionStatusKey, Self.emailKey]
        let sql = "SELECT key, value FROM ItemTable WHERE key IN (\(keys.map { "'\($0)'" }.joined(separator: ", ")))"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(db)
        }

        var items: [String: String] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) {
                    items[String(cString: key)] = String(cString: value)
                }
            case SQLITE_DONE:
                return items
            default:
                throw error(db)
            }
        }
    }

    private func error(_ db: OpaquePointer?) -> ProviderError {
        let code = sqlite3_errcode(db) & 0xFF  // 去掉扩展错误码
        if code == SQLITE_BUSY || code == SQLITE_LOCKED {
            return .unreadable("Cursor 数据库被占用，请稍后刷新")
        }
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "未知错误"
        return .unreadable("无法读取 Cursor 数据库：\(message)")
    }
}
