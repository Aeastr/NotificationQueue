import Foundation

/// Replacing a batch leaves every other batch intact. IDs must be unique across batches.
public struct ReminderBatch: Codable, Sendable {
    public let id: String
    public let reminders: [LocalReminder]
    /// Supply this when the batch describes only a finite window of a recurring source.
    public let evaluatedThrough: Date?
    public init(id: String, reminders: [LocalReminder], evaluatedThrough: Date? = nil) {
        self.id = id; self.reminders = reminders; self.evaluatedThrough = evaluatedThrough
    }
}

public struct ReminderPolicy: Sendable {
    public let namespace: String
    public let pendingBudget: Int
    public let warningTitle: String
    public let warningBody: String
    public let warningLeadTime: TimeInterval
    public let recoveryInterval: TimeInterval
    public var warningID: String { "__coverage" }
    public init(namespace: String, pendingBudget: Int = 60, warningTitle: String, warningBody: String,
                warningLeadTime: TimeInterval = 24 * 3600, recoveryInterval: TimeInterval = 48 * 3600) {
        precondition(!namespace.isEmpty, "A notification namespace is required")
        self.namespace = namespace
        self.pendingBudget = max(2, min(63, pendingBudget))
        self.warningTitle = warningTitle; self.warningBody = warningBody
        self.warningLeadTime = max(0, warningLeadTime)
        self.recoveryInterval = max(0, recoveryInterval)
    }
}

/// No app lifecycle, database, UI or domain dependencies. All mutations are serialized
/// across await points. The host provides execution opportunities and notification permission.
@MainActor
public final class NotificationCoordinator {
    private let reconciler: ReminderReconciler
    private var tail: Task<ReminderJournal, Error>?
    private var generation = 0

    public init(notifications: any ReminderNotificationStore, journal: any ReminderJournalStore,
                policy: ReminderPolicy, now: @escaping () -> Date = Date.init) {
        reconciler = ReminderReconciler(notifications: notifications, journalStore: journal,
                                       policy: policy, now: now)
    }

    public convenience init(policy: ReminderPolicy, journalURL: URL) {
        self.init(notifications: AppleReminderStore(namespace: policy.namespace),
                  journal: FileReminderJournal(url: journalURL), policy: policy)
    }

    /// Persists complete batches, including overflow, before touching pending notifications.
    /// Reusing a batch ID replaces that batch; pass an empty batch or remove its ID to cancel it.
    @discardableResult
    public func update(batches: [ReminderBatch] = [], removing: [String] = []) async throws -> ReminderJournal {
        let predecessor = tail
        generation += 1
        let token = generation
        let job = Task { @MainActor [reconciler] in
            _ = await predecessor?.result
            try Task.checkCancellation()
            var journal = try reconciler.journalStore.load()
            for id in removing { journal.batches.removeValue(forKey: id) }
            for batch in batches { journal.batches[batch.id] = batch }
            let reminders = journal.batches.values.flatMap(\.reminders)
            guard Set(reminders.map(\.id)).count == reminders.count,
                  journal.batches.values.allSatisfy({ !$0.id.isEmpty
                      && ($0.evaluatedThrough?.timeIntervalSince1970.isFinite ?? true) }),
                  reminders.allSatisfy({ !$0.id.isEmpty && $0.id != reconciler.policy.warningID
                      && $0.date.timeIntervalSince1970.isFinite }) else {
                throw ReminderSchedulingError.invalidBatch
            }
            // Discard elapsed one-offs without losing future overflow.
            journal.batches = journal.batches.mapValues {
                ReminderBatch(id: $0.id, reminders: $0.reminders.filter { $0.date > reconciler.now() },
                              evaluatedThrough: $0.evaluatedThrough)
            }
            journal.needsReconciliation = true
            try reconciler.journalStore.save(journal)
            return try await reconciler.reconcile(
                candidates: journal.batches.values.flatMap(\.reminders),
                horizon: journal.batches.values.compactMap(\.evaluatedThrough).min())
        }
        tail = job
        defer { if generation == token { tail = nil } }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Replays persisted intent after interruption; never treats a background request as success.
    @discardableResult
    public func refresh() async throws -> ReminderJournal { try await update() }
}

@MainActor
public final class FileReminderJournal: ReminderJournalStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> ReminderJournal {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReminderJournal() }
        // Never silently replace an unreadable journal with an empty queue.
        return try JSONDecoder().decode(ReminderJournal.self, from: Data(contentsOf: url))
    }
    public func save(_ journal: ReminderJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }
}
