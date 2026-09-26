import Foundation
import UserNotifications

@MainActor
public final class AppleReminderStore: ReminderNotificationStore {
    private let center: UNUserNotificationCenter
    private let prefix: String
    public init(namespace: String, center: UNUserNotificationCenter = .current()) {
        prefix = namespace + "."
        self.center = center
    }
    public func pending() async -> [LocalReminder] {
        await center.pendingNotificationRequests().compactMap { request in
            guard request.identifier.hasPrefix(prefix),
                  let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let date = trigger.nextTriggerDate() else { return nil }
            #if os(tvOS)
            let title = request.content.userInfo["NotificationQueue.title"] as? String ?? ""
            let body = request.content.userInfo["NotificationQueue.body"] as? String ?? ""
            #else
            let title = request.content.title
            let body = request.content.body
            #endif
            return LocalReminder(id: String(request.identifier.dropFirst(prefix.count)), date: date,
                                 title: title, body: body, badge: request.content.badge?.intValue)
        }
    }
    public func otherPendingCount() async -> Int {
        await center.pendingNotificationRequests().filter { !$0.identifier.hasPrefix(prefix) }.count
    }
    public func validate(_ reminders: [LocalReminder]) throws {
        #if os(tvOS)
        guard reminders.allSatisfy({ $0.badge != nil }) else {
            throw AppleReminderStoreError.badgeRequiredOnTV
        }
        #endif
    }
    public func add(_ reminder: LocalReminder) async throws {
        try validate([reminder])
        let content = UNMutableNotificationContent()
        content.badge = reminder.badge.map { NSNumber(value: $0) }
        #if os(tvOS)
        // tvOS can schedule badges, but cannot present notification alerts or sounds.
        // Keep text as metadata so pending-request verification still round-trips.
        content.userInfo = ["NotificationQueue.title": reminder.title, "NotificationQueue.body": reminder.body]
        #else
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        #endif
        // UTC components describe an absolute instant and avoid DST ambiguity.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.date)
        components.timeZone = calendar.timeZone
        components.calendar = calendar
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: prefix + reminder.id, content: content, trigger: trigger))
    }
    public func remove(_ identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers.map { prefix + $0 })
    }
}

public enum AppleReminderStoreError: LocalizedError {
    case badgeRequiredOnTV
    public var errorDescription: String? {
        "tvOS notifications require a badge value; alert text and sounds are unavailable."
    }
}
