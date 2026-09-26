import Foundation

/// Value types deliberately independent of Core Data and UserNotifications.
public struct LocalReminder: Codable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let title: String
    public let body: String
    public let badge: Int?
    public init(id: String, date: Date, title: String, body: String, badge: Int? = nil) {
        self.id = id
        // Apple's calendar triggers have second precision. Normalize before persisting
        // so verification compares the same instant that the OS can represent.
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.title = title
        self.body = body
        self.badge = badge
    }
}

public struct ReminderPlan: Codable, Sendable {
    public let reminders: [LocalReminder]
    /// Earliest omitted reminder, or the end of the period we inspected.
    public let coverageEnd: Date?
    public let warning: LocalReminder?

    static func make(candidates: [LocalReminder], horizon: Date?, now: Date,
                     otherPendingCount: Int, previous: ReminderJournal, policy: ReminderPolicy) -> Self {
        // Keep one transaction slot free even when other features use the budget.
        // An old safety warning can then survive until its replacement is verified.
        let capacity = max(0, min(policy.pendingBudget, 63 - otherPendingCount))
        let sorted = candidates.filter { $0.date > now }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
        let needsWarningSlot = policy.coverageWarningsEnabled && (horizon != nil || sorted.count > capacity)
        let selected = Array(sorted.prefix(max(0, capacity - (needsWarningSlot ? 1 : 0))))
        let omitted = sorted.dropFirst(selected.count).first?.date
        let boundary = [omitted, horizon].compactMap { $0 }.min()
        var warning: LocalReminder?
        if let boundary, capacity > 0, policy.coverageWarningsEnabled {
            let remaining = boundary.timeIntervalSince(now)
            // Do not nag again within the same low-coverage episode, even after restart.
            let alreadyWarned = [previous.warningDate, previous.warningAttempt?.date]
                .compactMap { $0 }.contains { $0 <= now }
            let recovered = remaining > policy.recoveryInterval
                && boundary > (previous.coverageEnd ?? .distantPast)
            if !alreadyWarned || recovered {
                let lead = min(policy.warningLeadTime, max(0, remaining / 2))
                var date = max(now.addingTimeInterval(1), boundary.addingTimeInterval(-lead))
                // An unchanged boundary must not slide the warning forward on each pass.
                if previous.coverageEnd == boundary, let existing = previous.warningDate, existing > now {
                    date = existing
                }
                warning = LocalReminder(id: policy.warningID, date: date,
                    title: policy.warningTitle, body: policy.warningBody)
            }
        }
        return Self(reminders: selected, coverageEnd: boundary, warning: warning)
    }
}

public struct ReminderJournal: Codable, Sendable {
    public init() {}
    public var batches: [String: ReminderBatch] = [:]
    public var needsReconciliation = true
    public var planned: ReminderPlan?
    public var lastSuccessfulRefill: Date?
    public var coverageEnd: Date?
    public var warningDate: Date?
    /// Persisted before handing a warning to the OS. If interrupted afterward,
    /// conservatively avoid repeating a warning that may already have fired.
    public var warningAttempt: LocalReminder?
}

@MainActor
public protocol ReminderNotificationStore {
    func validate(_ reminders: [LocalReminder]) throws
    func pending() async -> [LocalReminder]
    func otherPendingCount() async -> Int
    func add(_ reminder: LocalReminder) async throws
    func remove(_ identifiers: [String]) async
}

public extension ReminderNotificationStore {
    func validate(_ reminders: [LocalReminder]) throws {}
}

@MainActor
public protocol ReminderJournalStore {
    func load() throws -> ReminderJournal
    func save(_ journal: ReminderJournal) throws
}

public enum ReminderSchedulingError: LocalizedError {
    case verificationFailed
    case dataUnavailable
    case invalidBatch
    public var errorDescription: String? {
        switch self {
        case .verificationFailed: "Some reminders could not be scheduled. Please try again."
        case .dataUnavailable: "Reminder data is not ready yet. Please try again."
        case .invalidBatch: "Reminder batches must contain unique, nonempty identifiers and valid dates."
        }
    }
}

/// Caller serializes entire passes, including their suspension points.
@MainActor
final class ReminderReconciler {
    let notifications: any ReminderNotificationStore
    let journalStore: any ReminderJournalStore
    let policy: ReminderPolicy
    let now: () -> Date

    init(notifications: any ReminderNotificationStore, journalStore: any ReminderJournalStore,
         policy: ReminderPolicy, now: @escaping () -> Date = Date.init) {
        self.notifications = notifications
        self.journalStore = journalStore
        self.now = now
        self.policy = policy
    }

    func reconcile(candidates: [LocalReminder], horizon: Date?) async throws -> ReminderJournal {
        var journal = try journalStore.load()
        let plan = ReminderPlan.make(candidates: candidates, horizon: horizon, now: now(),
            otherPendingCount: await notifications.otherPendingCount(), previous: journal, policy: policy)
        journal.needsReconciliation = true
        journal.planned = plan
        // Persist intent before changing the operating system's queue.
        try journalStore.save(journal)
        try Task.checkCancellation()
        let pending = await notifications.pending()
        let desiredIDs = Set(plan.reminders.map(\.id))
        let obsolete = pending.filter {
            $0.id != policy.warningID && !desiredIDs.contains($0.id)
        }.map(\.id)
        await notifications.remove(obsolete)
        for reminder in plan.reminders {
            try Task.checkCancellation()
            if reminder.date > now(), !pending.contains(reminder) {
                try await notifications.add(reminder)
            }
        }
        try await verify(plan.reminders)
        // Only move the safety warning after the ordinary reminders are verified.
        if let warning = plan.warning {
            if !pending.contains(warning) {
                journal.warningAttempt = warning
                try journalStore.save(journal)
                try Task.checkCancellation()
                try await notifications.add(warning)
            }
            try await verify([warning])
        } else {
            await notifications.remove([policy.warningID])
        }
        try Task.checkCancellation()
        let expected = plan.reminders + (plan.warning.map { [$0] } ?? [])
        let finalPending = await notifications.pending()
        let futureExpected = expected.filter { $0.date > now() }
        guard Set(finalPending.map(\.id)) == Set(futureExpected.map(\.id)),
              futureExpected.allSatisfy({ finalPending.contains($0) }) else {
            throw ReminderSchedulingError.verificationFailed
        }
        try Task.checkCancellation()
        journal.needsReconciliation = false
        journal.lastSuccessfulRefill = now()
        journal.coverageEnd = plan.coverageEnd
        if let warning = plan.warning {
            journal.warningDate = warning.date
            journal.warningAttempt = nil
        } else if plan.coverageEnd == nil {
            journal.warningDate = nil
            journal.warningAttempt = nil
        }
        try journalStore.save(journal)
        return journal
    }

    private func verify(_ expected: [LocalReminder]) async throws {
        let actual = await notifications.pending()
        try Task.checkCancellation()
        guard expected.filter({ $0.date > now() }).allSatisfy({ actual.contains($0) }) else {
            throw ReminderSchedulingError.verificationFailed
        }
    }
}
