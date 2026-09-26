import Combine
import Foundation
import NotificationQueue
import UserNotifications

/// The app owns the coordinator and gives it execution opportunities.
@MainActor
final class DemoModel: ObservableObject {
    @Published private(set) var journal = ReminderJournal()
    @Published private(set) var pending: [LocalReminder] = []
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var message = "Add a reminder to explore the queue."
    @Published private(set) var snapshotDate: Date?
    @Published private(set) var failedBatch: ReminderBatch?

    let coordinator: NotificationCoordinator
    private let storage: FileReminderJournal
    private let notificationStore: AppleReminderStore
    private let delegate = ForegroundNotifications()
    let warningID = "__coverage"

    init() {
        let namespace = "notificationqueue.demo"
        let url = URL.applicationSupportDirectory
            .appendingPathComponent("NotificationQueueDemo", isDirectory: true)
            .appendingPathComponent("journal.json")
        storage = FileReminderJournal(url: url)
        notificationStore = AppleReminderStore(namespace: namespace)
        coordinator = NotificationCoordinator(notifications: notificationStore, journal: storage,
            policy: ReminderPolicy(appName: "NotificationQueue Demo", namespace: namespace))
        UNUserNotificationCenter.current().delegate = delegate
    }

    var reminders: [LocalReminder] {
        journal.batches.values.flatMap(\.reminders).sorted { $0.date < $1.date }
    }
    var batches: [ReminderBatch] {
        journal.batches.values.filter { $0.id != "__notificationqueue.individual" }.sorted { $0.id < $1.id }
    }
    var diagnostics: [ReminderDiagnostic] {
        (journal.reminderDiagnostics ?? [:]).values.sorted { $0.observedAt > $1.observedAt }
    }
    var waiting: [LocalReminder] {
        let pendingIDs = Set(pending.map(\.id))
        return reminders.filter { $0.date > Date() && !pendingIDs.contains($0.id) }
    }
    var permissionLabel: String {
        switch authorization {
        case .authorized: return "Allowed"
        case .provisional: return "Quiet delivery"
        case .ephemeral: return "Temporary permission"
        case .denied: return "Denied — change in system Settings"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown authorization status"
        }
    }

    func requestPermission() async {
        await perform {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            self.message = granted ? "Notifications allowed." : "Permission denied. Enable notifications in system Settings."
        }
    }

    func refresh() async {
        await perform {
            self.journal = try await self.coordinator.refresh()
            self.message = "Queue refreshed. Pending requests are verified; delivery is not guaranteed."
        }
    }

    /// Reads both sources without changing scheduling intent.
    func inspect() async { await perform {} }

    func save(id: String?, title: String, body: String, date: Date, editing: Bool) async -> Bool {
        await perform {
            let reminder = LocalReminder(id: id, date: date, title: title, body: body)
            if editing {
                self.journal = try await self.coordinator.update(reminder)
                self.message = "Updated reminder \(reminder.id)."
            } else {
                let receipt = try await self.coordinator.schedule(reminder)
                self.journal = receipt.journal
                self.message = "Saved reminder \(receipt.id). Check Pending or Waiting for its current state."
            }
        }
    }

    func cancel(_ reminder: LocalReminder) async {
        await perform {
            self.journal = try await self.coordinator.removeReminder(reminder.id)
            self.message = "Reminder cancelled."
        }
    }

    func createBatch(count: Int) async {
        await perform {
            // IDs are created once, before the scheduling attempt.
            let start = Date().addingTimeInterval(300)
            let reminders = (0..<count).map { index in
                LocalReminder(date: start.addingTimeInterval(Double(index) * 300),
                              title: "Demo reminder \(index + 1)", body: "From a group of \(count) reminders.")
            }
            let batch = ReminderBatch(reminders: reminders)
            self.failedBatch = batch
            let receipt = try await self.coordinator.scheduleBatch(batch)
            self.failedBatch = nil
            self.journal = receipt.journal
            self.message = "Saved batch \(receipt.id). \(count) reminders, five minutes apart."
        }
    }

    func retryBatch() async {
        guard let batch = failedBatch else { return }
        await perform {
            let receipt = try await self.coordinator.scheduleBatch(batch)
            self.journal = receipt.journal
            self.failedBatch = nil
            self.message = "Retried the same batch ID: \(receipt.id)."
        }
    }

    func replaceBatch(_ batch: ReminderBatch) async {
        await perform {
            // Keep identity, change content, and retain only the first three future reminders.
            let reminders = batch.reminders.filter { $0.date > Date() }.sorted { $0.date < $1.date }
                .prefix(3).map {
                    LocalReminder(id: $0.id, date: $0.date, title: "Updated: \($0.title)", body: $0.body)
                }
            self.journal = try await self.coordinator.replaceBatch(batch.id, with: reminders)
            self.message = "Batch replaced with \(reminders.count) future reminders; omitted reminders cancelled."
        }
    }

    func removeBatch(_ batch: ReminderBatch) async {
        await perform {
            self.journal = try await self.coordinator.removeBatch(batch.id)
            self.message = "Batch cancelled."
        }
    }

    func cancelAll() async {
        await perform {
            // Only remove this demo's saved reminders, never another namespace's requests.
            let saved = try self.storage.load()
            for reminder in saved.batches["__notificationqueue.individual"]?.reminders ?? [] {
                // Earlier cancellations can prune elapsed siblings; do not try to remove them twice.
                let current = try self.storage.load()
                if current.batches["__notificationqueue.individual"]?.reminders.contains(where: { $0.id == reminder.id }) == true {
                    self.journal = try await self.coordinator.removeReminder(reminder.id)
                }
            }
            let batchIDs = saved.batches.keys.filter { $0 != "__notificationqueue.individual" }
            self.journal = try await self.coordinator.update(removing: batchIDs)
            self.failedBatch = nil
            self.message = "All demo reminders cancelled. Retained diagnostics remain visible."
        }
    }

    @discardableResult
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        errorMessage = nil
        var errors: [String] = []
        do { try await operation() }
        catch { errors.append(error.localizedDescription) }
        // Keep reading after an operation error so partially saved work is visible.
        do { journal = try storage.load() }
        catch { errors.append("Saved queue could not be read: \(error.localizedDescription)") }
        do {
            pending = try await notificationStore.pending().sorted { $0.date < $1.date }
            snapshotDate = Date()
        } catch {
            errors.append("Pending requests could not be read; the displayed snapshot may be stale: \(error.localizedDescription)")
        }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if !errors.isEmpty { errorMessage = errors.joined(separator: "\n\n") }
        return errors.isEmpty
    }
}

/// Present demo reminders while the app is open as well as while it is in the background.
private final class ForegroundNotifications: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
