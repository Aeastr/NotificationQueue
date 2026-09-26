import Foundation

/// Explicit results of a verified scheduling pass, not confirmation of notification delivery.
public struct ReminderOutcome: Codable, Sendable {
    /// Ordinary reminders verified as pending, excluding the coverage warning.
    public let scheduledReminderIDs: [String]
    /// Future reminders saved to disk but waiting for available notification slots.
    public let deferredReminderIDs: [String]
    /// Saved requests whose time elapsed. This does not establish whether they were delivered.
    public let elapsedReminderIDs: [String]
    public let warningStatus: ReminderWarningStatus
    public let coverageEnd: Date?
    /// The host must generate a new source window instead of only replaying persisted batches.
    public let generationBoundaryReached: Bool
}

/// Why the current pass has, or does not have, a coverage warning.
public enum ReminderWarningStatus: String, Codable, Sendable {
    case scheduled
    /// The warning time passed during this operation; delivery is unknown.
    case elapsed
    case notNeeded
    case disabled
    /// A warning may already have fired; another is suppressed during the same low-coverage episode.
    case alreadyAttempted
}

/// Optional observation of each operation. Failures are also thrown to its caller.
public enum ReminderEvent {
    case completed(ReminderJournal)
    case failed(any Error)
}

/// Persisted evidence about one reminder occurrence. This is not a delivery receipt.
public struct ReminderDiagnostic: Codable, Sendable {
    public let reminderID: String
    public let requestedDate: Date
    public let observedAt: Date
    public let state: ReminderSchedulingState
    public let reason: ReminderDiagnosticReason?
    /// Original system error text, when a submission failed.
    public let detail: String?
}

/// The last state the coordinator could establish for an occurrence.
public enum ReminderSchedulingState: String, Codable, Sendable {
    case awaitingScheduling
    case deferred
    case scheduled
    case elapsed
}

/// Evidence explaining a deferred or elapsed reminder, without inferring delivery.
public enum ReminderDiagnosticReason: String, Codable, Sendable {
    /// Other pending requests or the configured budget left this reminder in overflow.
    case capacity
    /// The notification store explicitly rejected submission; inspect `detail`.
    case submissionFailed
    /// Submission may have happened, but verification did not complete.
    case schedulingUnconfirmed
    /// A deferred occurrence reached its deadline without a verified refill scheduling it.
    /// This does not prove that the operating system denied background execution.
    case noVerifiedRefillBeforeDeadline
    /// The request was verified as pending earlier; its eventual delivery is unknown.
    case deliveryUnknown
}
