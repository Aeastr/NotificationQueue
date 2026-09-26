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
            return LocalReminder(id: String(request.identifier.dropFirst(prefix.count)), date: date,
                                 title: request.content.title, body: request.content.body)
        }
    }
    public func otherPendingCount() async -> Int {
        await center.pendingNotificationRequests().filter { !$0.identifier.hasPrefix(prefix) }.count
    }
    public func add(_ reminder: LocalReminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
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
