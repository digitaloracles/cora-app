import CoraKit
import SwiftUI
import UIKit
import UserNotifications

/// The APNs side of the app: asks once for permission, keeps this phone's token and hands it to every connected space,
/// shows notices while the app is in front and opens what a tapped one is about, also when the tap launches the app.
@MainActor
final class Notices: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notices()

    @Published private(set) var token: String?
    @Published var notice: Notice?
    /// Development builds are signed for the APNs sandbox.
    let environment = "sandbox"

    func ask() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func received(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let notice = Notice(payload: response.notification.request.content.userInfo) else { return }
        await MainActor.run { self.notice = notice }
    }

    /// `CORA_DEMO_NOTICE`: the sample space posts itself a notification with that payload (JSON) a few seconds in, so a UI test can tap it from the lock screen or the home screen.
    func scheduleDemoNotice() {
        guard Spaces.demo, let json = ProcessInfo.processInfo.environment["CORA_DEMO_NOTICE"], let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["CORA_DEMO_NOTICE_DELAY"] ?? "") ?? 4
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = payload["title"] as? String ?? "Cora"
            content.body = payload["body"] as? String ?? ""
            content.userInfo = payload
            center.add(UNNotificationRequest(identifier: "demo-notice", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = Notices.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Notices.shared.received(deviceToken) }
    }
}
