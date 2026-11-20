import CoraKit
import SwiftUI
import UIKit
import UserNotifications

/// What a tapped notification asks to open.
enum NoticeTarget: Equatable {
    case plan(String)
    case thread(String)
}

/// The APNs side of the app: asks once for permission, keeps this phone's token and hands it to every connected space,
/// shows notices while the app is in front and opens the plan or thread a tapped one is about.
@MainActor
final class Notices: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notices()

    @Published private(set) var token: String?
    @Published var target: NoticeTarget?
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
        let info = response.notification.request.content.userInfo
        let plan = info["planId"] as? String, channel = info["channelId"] as? String
        await MainActor.run {
            if let plan, !plan.isEmpty { target = .plan(plan) } else if let channel, !channel.isEmpty { target = .thread(channel) }
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
