import Foundation

/// A dated local reminder with a stable identifier and optional badge value.
///
/// Dates use whole-second precision. On tvOS, supply a nonnegative badge;
/// see <doc:PlatformSupport>.
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

/// The selected reminders, generation boundary, and optional safety warning for a scheduling pass.
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

/// Persisted batches and reconciliation state, including the last verified refill.
public struct ReminderJournal: Codable, Sendable {
    public init() {}
    public var batches: [String: ReminderBatch] = [:]
    /// Whether saved intent still requires a verified scheduling pass.
    public var needsReconciliation = true
    public var planned: ReminderPlan?
    /// Time of the last verified queue update, not a background-task request or delivery receipt.
    public var lastSuccessfulRefill: Date?
    /// Earliest omitted reminder or generation boundary from the last successful pass.
    public var coverageEnd: Date?
    /// Outcome of the last completed pass; absent before the first successful pass.
    public var lastOutcome: ReminderOutcome?
    /// Latest evidence per reminder ID, including elapsed occurrences across refreshes.
    /// Absent in older journals. Rescheduling an ID starts a new occurrence's evidence.
    public var reminderDiagnostics: [String: ReminderDiagnostic]?
    public var warningDate: Date?
    /// Persisted before handing a warning to the OS. If interrupted afterward,
    /// conservatively avoid repeating a warning that may already have fired.
    public var warningAttempt: LocalReminder?
}

extension ReminderJournal {
    mutating func record(_ reminder: LocalReminder, at date: Date, state: ReminderSchedulingState,
                         reason: ReminderDiagnosticReason? = nil, detail: String? = nil) {
        if reminderDiagnostics == nil { reminderDiagnostics = [:] }
        reminderDiagnostics?[reminder.id] = ReminderDiagnostic(reminderID: reminder.id,
            requestedDate: reminder.date, observedAt: date, state: state, reason: reason, detail: detail)
    }

    mutating func recordUnselected(_ reminder: LocalReminder, at date: Date) {
        let previous = reminderDiagnostics?[reminder.id]
        // Until removals are verified, an older request may still be pending.
        guard previous?.state != .scheduled,
              previous?.reason != .schedulingUnconfirmed,
              previous?.reason != .submissionFailed else { return }
        record(reminder, at: date, state: .deferred, reason: .capacity)
    }

    mutating func recordElapsed(_ reminder: LocalReminder, at date: Date) {
        let previous = reminderDiagnostics?[reminder.id]
        guard previous?.state != .elapsed else { return }
        let reason: ReminderDiagnosticReason
        switch previous?.state {
        case .scheduled: reason = .deliveryUnknown
        case .deferred: reason = .noVerifiedRefillBeforeDeadline
        default: reason = previous?.reason == .submissionFailed ? .submissionFailed : .schedulingUnconfirmed
        }
        record(reminder, at: date, state: .elapsed, reason: reason, detail: previous?.detail)
    }
}

/// Provides pending-request access and mutations for the coordinator.
///
/// Implement this protocol to supply another transport or a test double.
@MainActor
public protocol ReminderNotificationStore {
    /// Rejects unsupported requests before the coordinator persists batch changes.
    func validate(_ reminders: [LocalReminder]) throws
    /// Throws when system authorization does not allow scheduling. Does not prompt.
    func checkSchedulingAuthorization() async throws
    /// Returns requests owned by this store, using the original reminder identifiers and content.
    func pending() async throws -> [LocalReminder]
    /// Counts system requests outside this store so they can be included in the shared budget.
    func otherPendingCount() async throws -> Int
    /// Adds or replaces a request by stable identifier; reports scheduling failures by throwing.
    func add(_ reminder: LocalReminder) async throws
    /// Removes the specified owned requests without clearing another feature’s notifications.
    func remove(_ identifiers: [String]) async throws
}

public extension ReminderNotificationStore {
    func validate(_ reminders: [LocalReminder]) throws {}
    func checkSchedulingAuthorization() async throws {}
}

/// Loads and durably saves scheduling intent before queue mutations.
@MainActor
public protocol ReminderJournalStore {
    /// Loads saved intent, or returns a fresh journal when no saved state exists.
    /// Throw for unreadable or corrupted existing state.
    func load() throws -> ReminderJournal
    /// Atomically replaces saved intent and throws if it cannot be durably stored.
    func save(_ journal: ReminderJournal) throws
}

public enum ReminderSchedulingError: LocalizedError {
    case diagnosticPersistenceFailed(operation: any Error, persistence: any Error)
    case verificationFailed
    case dataUnavailable
    case reminderNotFound(identifier: String)
    case invalidBatch
    case invalidPolicy(reason: String)
    case expiredReminders(identifiers: [String])
    case noCapacity
    case invalidStoreSnapshot
    case verificationMismatch(missing: [String], unexpected: [String], changed: [String])
    public var errorDescription: String? {
        switch self {
        case .diagnosticPersistenceFailed(let operation, let persistence):
            "Scheduling failed: \(operation.localizedDescription) Diagnostic persistence also failed: \(persistence.localizedDescription)"
        case .verificationFailed: "Some reminders could not be scheduled. Please try again."
        case .dataUnavailable: "Reminder data is not ready yet. Please try again."
        case .reminderNotFound(let id): "No saved reminder has the identifier: \(id)."
        case .invalidBatch: "Reminder batches must contain unique, nonempty identifiers, valid dates, and nonnegative badges."
        case .invalidPolicy(let reason): "Invalid notification policy: \(reason)"
        case .expiredReminders(let identifiers): "These reminders are no longer in the future: \(identifiers.joined(separator: ", "))."
        case .noCapacity: "No notification slots are available. Saved reminders still need scheduling."
        case .invalidStoreSnapshot: "The notification store returned an invalid pending-request snapshot."
        case .verificationMismatch(let missing, let unexpected, let changed):
            "Queue verification failed. Missing: \(missing.joined(separator: ", ")); unexpected: \(unexpected.joined(separator: ", ")); changed: \(changed.joined(separator: ", "))."

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

    func reconcile(candidates: [LocalReminder], horizon: Date?, elapsedReminderIDs: [String] = []) async throws -> ReminderJournal {
        var journal = try journalStore.load()
        let otherCount = try await notifications.otherPendingCount()
        guard otherCount >= 0 else { throw ReminderSchedulingError.invalidStoreSnapshot }
        if otherCount >= 63 && (!candidates.isEmpty || horizon != nil) {
            for reminder in candidates {
                journal.recordUnselected(reminder, at: now())
            }
            try journalStore.save(journal)
            throw ReminderSchedulingError.noCapacity
        }
        let plan = ReminderPlan.make(candidates: candidates, horizon: horizon, now: now(),
            otherPendingCount: otherCount, previous: journal, policy: policy)
        if !plan.reminders.isEmpty || plan.warning != nil {
            try await notifications.checkSchedulingAuthorization()
        }
        journal.needsReconciliation = true
        journal.planned = plan
        let selectedIDs = Set(plan.reminders.map(\.id))
        for reminder in candidates where !selectedIDs.contains(reminder.id) && reminder.date > now() {
            journal.recordUnselected(reminder, at: now())
        }
        // Persist intent before changing the operating system's queue.
        try journalStore.save(journal)
        try Task.checkCancellation()
        let pending = try await notifications.pending()
        let desiredIDs = Set(plan.reminders.map(\.id))
        let obsolete = pending.filter {
            $0.id != policy.warningID && !desiredIDs.contains($0.id)
        }.map(\.id)
        try await notifications.remove(obsolete)
        for reminder in plan.reminders {
            try Task.checkCancellation()
            if reminder.date > now(), !pending.contains(reminder) {
                // Persist uncertainty before handing the request to the system.
                journal.record(reminder, at: now(), state: .awaitingScheduling, reason: .schedulingUnconfirmed)
                try journalStore.save(journal)
                do {
                    try await notifications.add(reminder)
                } catch {
                    journal.record(reminder, at: now(), state: .awaitingScheduling,
                                   reason: error is CancellationError ? .schedulingUnconfirmed : .submissionFailed,
                                   detail: error.localizedDescription)
                    do { try journalStore.save(journal) }
                    catch let persistenceError {
                        throw ReminderSchedulingError.diagnosticPersistenceFailed(
                            operation: error, persistence: persistenceError)
                    }
                    throw error
                }
            }
        }
        try await verify(plan.reminders)
        let ordinaryVerifiedAt = now()
        for reminder in plan.reminders where reminder.date > ordinaryVerifiedAt {
            journal.record(reminder, at: ordinaryVerifiedAt, state: .scheduled)
        }
        try journalStore.save(journal)
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
            try await notifications.remove([policy.warningID])
        }
        try Task.checkCancellation()
        let expected = plan.reminders + (plan.warning.map { [$0] } ?? [])
        let finalPending = try await notifications.pending()
        let verifiedAt = now()
        let futureExpected = expected.filter { $0.date > verifiedAt }
        let futureActual = finalPending.filter { $0.date > verifiedAt }
        try verifySnapshot(expected: futureExpected, actual: futureActual, allowExtra: false)
        if !futureExpected.isEmpty { try await notifications.checkSchedulingAuthorization() }
        let scheduled = plan.reminders.filter { $0.date > verifiedAt }.map(\.id).sorted()
        let scheduledSet = Set(scheduled)
        let deferred = candidates.filter { $0.date > verifiedAt && !scheduledSet.contains($0.id) }.map(\.id).sorted()
        let elapsed = Set(elapsedReminderIDs + candidates.filter { $0.date <= verifiedAt }.map(\.id)).sorted()
        for reminder in candidates where reminder.date > verifiedAt && !scheduledSet.contains(reminder.id) {
            journal.record(reminder, at: verifiedAt, state: .deferred, reason: .capacity)
        }
        for reminder in candidates where reminder.date <= verifiedAt {
            journal.recordElapsed(reminder, at: verifiedAt)
        }
        let warningState: ReminderWarningStatus
        if let warning = plan.warning { warningState = warning.date > verifiedAt ? .scheduled : .elapsed }
        else if plan.coverageEnd == nil { warningState = .notNeeded }
        else if !policy.coverageWarningsEnabled { warningState = .disabled }
        else { warningState = .alreadyAttempted }
        journal.lastOutcome = ReminderOutcome(scheduledReminderIDs: scheduled, deferredReminderIDs: deferred,
            elapsedReminderIDs: elapsed, warningStatus: warningState, coverageEnd: plan.coverageEnd,
            generationBoundaryReached: horizon.map { $0 <= verifiedAt } ?? false)
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
        let actual = try await notifications.pending()
        try Task.checkCancellation()
        let instant = now()
        try verifySnapshot(expected: expected.filter { $0.date > instant },
                           actual: actual.filter { $0.date > instant }, allowExtra: true)
    }

    private func verifySnapshot(expected: [LocalReminder], actual: [LocalReminder], allowExtra: Bool) throws {
        guard Set(actual.map(\.id)).count == actual.count else {
            throw ReminderSchedulingError.invalidStoreSnapshot
        }
        let desired = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        let observed = Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) })
        let missing = desired.keys.filter { observed[$0] == nil }.sorted()
        let unexpected = allowExtra ? [] : observed.keys.filter { desired[$0] == nil }.sorted()
        let changed = desired.keys.filter { observed[$0] != nil && observed[$0] != desired[$0] }.sorted()
        if !missing.isEmpty || !unexpected.isEmpty || !changed.isEmpty {
            throw ReminderSchedulingError.verificationMismatch(missing: missing, unexpected: unexpected, changed: changed)
        }
    }
}
