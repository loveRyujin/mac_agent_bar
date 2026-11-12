import AgentBarCore
import AppKit
import UserNotifications

/// 发送系统通知，并处理点击。第一次有通知要发时才向系统申请权限。
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// 点击通知时调用，参数是 agent id。
    var onOpen: ((String) -> Void)?

    /// 只有打包成 .app（有 bundle id）时才能使用通知中心；`swift run` 时为 nil。
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    override init() {
        super.init()
        center?.delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func send(_ events: [NotificationEvent]) async {
        guard let center, !events.isEmpty else { return }
        await refreshAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus()
        }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            content.userInfo = ["providerID": event.providerID]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    func refreshAuthorizationStatus() async {
        guard let center else { return }
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 应用处于前台时也显示横幅。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo["providerID"] as? String else { return }
        await MainActor.run { onOpen?(id) }
    }
}
