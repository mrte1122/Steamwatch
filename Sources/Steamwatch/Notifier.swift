import AppKit
import Foundation
import SteamwatchCore
import UserNotifications

/// Posts deal alerts, opens the store page when one is clicked, and handles the banner's buttons.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String { case open, hide, mute }

    /// Set by the Store: what to do when a banner's Hide or Mute button is pressed.
    var onAction: ((Action, AppID) -> Void)?

    private static let dealCategory = "deal"
    /// UNUserNotificationCenter traps outside a real .app bundle (e.g. `swift run`).
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    override init() {
        super.init()
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.dealCategory, actions: [
                UNNotificationAction(identifier: Action.open.rawValue, title: SteamLink.opensInApp ? "Open in Steam" : "Open Store Page", options: [.foreground]),
                UNNotificationAction(identifier: Action.hide.rawValue, title: "Hide (Bought It)"),
                UNNotificationAction(identifier: Action.mute.rawValue, title: "Mute This Game"),
            ], intentIdentifiers: []),
        ])
    }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ alert: DealAlert) {
        post(title: alert.title, body: alert.body, url: alert.deal.item.storeURL, id: alert.key, appID: alert.deal.item.appID)
    }

    /// `url` opens when the notification is clicked. With an `appID` the banner gets the deal buttons.
    func post(title: String, body: String, url: URL? = nil, id: String = UUID().uuidString, appID: AppID? = nil) {
        guard available, !Demo.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var info: [String: Any] = [:]
        if let url { info["url"] = url.absoluteString }
        if let appID { info["appID"] = appID; content.categoryIdentifier = Self.dealCategory }
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        let appID = info["appID"] as? Int
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch action {
                case Action.hide.rawValue: if let appID { self.onAction?(.hide, appID) }
                case Action.mute.rawValue: if let appID { self.onAction?(.mute, appID) }
                default: if let url { SteamLink.open(url) }   // the banner itself, or Open
                }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
