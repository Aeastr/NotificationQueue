import Foundation

/// A replaceable group of dated reminders.
///
/// Replacing a batch leaves other batches intact. Reminder IDs must be unique
/// across all batches. See <doc:ManagingBatches>.
public struct ReminderBatch: Codable, Sendable {
    /// Stable identifier used to replace or remove this batch as a unit.
    public let id: String
    /// Complete desired contents of this batch, including reminders that may overflow the system queue.
    public let reminders: [LocalReminder]
    /// Supply this when the batch describes only a finite window of a recurring source.
    public let evaluatedThrough: Date?
    public init(id: String, reminders: [LocalReminder], evaluatedThrough: Date? = nil) {
        self.id = id; self.reminders = reminders; self.evaluatedThrough = evaluatedThrough
    }
}

/// Configures pending capacity and the warning shown when coverage is running low.
///
/// See <doc:CoverageWarnings> for timing and <doc:PlatformSupport> for tvOS defaults.
public struct ReminderPolicy: Sendable {
    /// Nonempty ownership prefix used by the Apple notification store.
    public let namespace: String
    /// Maximum owned pending requests, including a warning when enabled; must be between 2 and 63.
    public let pendingBudget: Int
    /// Title displayed by a coverage warning on platforms that support alerts.
    public let warningTitle: String
    /// Message asking the user to reopen the app before coverage runs out.
    public let warningBody: String
    /// Maximum warning lead time; shorter coverage uses half the remaining interval.
    public let warningLeadTime: TimeInterval
    /// Remaining coverage required, alongside an extended boundary, to rearm an elapsed warning.
    public let recoveryInterval: TimeInterval
    /// Whether the coordinator reserves space for and schedules coverage warning alerts.
    public let coverageWarningsEnabled: Bool
    /// False on tvOS, where notification alerts are unavailable; true on other supported platforms.
    public static var defaultCoverageWarningsEnabled: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }
    /// Reserved reminder identifier; do not use this identifier in submitted batches.
    public var warningID: String { "__coverage" }
    /// Uses built-in reopen-app warning text and the default queue policy.
    ///
    /// Warnings are scheduled automatically when reminder coverage is finite, moved
    /// after successful refills, and suppressed when every known reminder fits.
    /// tvOS retains its default of badge-only scheduling without warning alerts.
    /// - Parameters:
    ///   - appName: The user-facing app name included in the warning title.
    ///   - namespace: A nonempty ownership prefix unique to this queue.
    public init(appName: String, namespace: String) {
        self.init(namespace: namespace,
                  warningTitle: "Open \(appName) to keep reminders going",
                  warningBody: "Your scheduled reminders are running low. Open the app to refresh upcoming reminders.")
    }

    public init(namespace: String, pendingBudget: Int = 60, warningTitle: String, warningBody: String,
                warningLeadTime: TimeInterval = 24 * 3600, recoveryInterval: TimeInterval = 48 * 3600,
                coverageWarningsEnabled: Bool = ReminderPolicy.defaultCoverageWarningsEnabled) {
        self.namespace = namespace
        self.pendingBudget = pendingBudget
        self.warningTitle = warningTitle; self.warningBody = warningBody
        self.warningLeadTime = warningLeadTime
        self.recoveryInterval = recoveryInterval
        self.coverageWarningsEnabled = coverageWarningsEnabled
    }

    /// Validates configuration without silently clamping it or terminating the process.
    /// Scheduling operations call this before changing saved state.
    public func validate() throws {
        guard !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReminderSchedulingError.invalidPolicy(reason: "A namespace is required.")
        }
        guard (2...63).contains(pendingBudget) else {
            throw ReminderSchedulingError.invalidPolicy(reason: "The pending budget must be between 2 and 63.")
        }
        guard warningLeadTime.isFinite, warningLeadTime >= 0,
              recoveryInterval.isFinite, recoveryInterval >= 0 else {
            throw ReminderSchedulingError.invalidPolicy(reason: "Warning intervals must be finite and nonnegative.")
        }
    }
}

/// Persists reminder batches and keeps the nearest reminders scheduled within the queue budget.
///
/// Keep one instance per journal and namespace. Updates are serialized across
/// suspension points. Your app supplies notification permission and execution
/// opportunities; see <doc:AppIntegration> and <doc:SchedulingAndRecovery>.
@MainActor
public final class NotificationCoordinator {
    private let reconciler: ReminderReconciler
    private var tail: Task<ReminderJournal, Error>?
    private var generation = 0
    /// Observes operation outcomes on the main actor. Errors still propagate through async throws.
    /// Capture the coordinator weakly if the handler needs to refer back to it.
    public var onEvent: ((ReminderEvent) -> Void)?

    /// Creates a coordinator with custom stores and an injectable clock.
    ///
    /// Use a single writer per journal and namespace. Custom store contracts are
    /// described in <doc:Customization>.
    public init(notifications: any ReminderNotificationStore, journal: any ReminderJournalStore,
                policy: ReminderPolicy, now: @escaping () -> Date = Date.init) {
        reconciler = ReminderReconciler(notifications: notifications, journalStore: journal,
                                       policy: policy, now: now)
    }

    /// Creates an Apple-backed queue with automatic coverage warnings and persistent storage.
    ///
    /// Keep this coordinator in your app's state. NotificationQueue manages the
    /// reopen-app warning without a separate scheduling call. Your app supplies
    /// permission and invokes refresh when it gets execution time.
    ///
    /// - Parameters:
    ///   - appName: The display name used in the built-in warning text.
    ///   - namespace: A stable, nonempty ownership prefix for this queue.
    ///   - journalURL: An optional custom storage file. By default, each namespace
    ///     gets its own JSON journal in the app's Application Support directory.
    ///
    /// See <doc:SwiftUIQuickStart> for app ownership and lifecycle integration.
    public convenience init(appName: String, namespace: String, journalURL: URL? = nil) {
        let policy = ReminderPolicy(appName: appName, namespace: namespace)
        let filename = namespace.utf8.map { String(format: "%02x", $0) }.joined()
        let storage = journalURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("NotificationQueue", isDirectory: true)
            .appendingPathComponent(filename + ".json")
        self.init(policy: policy, journalURL: storage)
    }

    /// Creates a coordinator using Apple notifications and an atomic JSON journal.
    ///
    /// - Parameters:
    ///   - policy: Queue capacity, namespace, and coverage-warning configuration.
    ///   - journalURL: A writable file URL in your app's protected storage.
    public convenience init(policy: ReminderPolicy, journalURL: URL) {
        self.init(notifications: AppleReminderStore(namespace: policy.namespace),
                  journal: FileReminderJournal(url: journalURL), policy: policy)
    }

    private static let individualBatchID = "__notificationqueue.individual"
    private enum IndividualChange {
        case schedule(LocalReminder)
        case edit(LocalReminder)
        case remove(String)
    }

    /// Saves one reminder and schedules it when capacity permits.
    /// Reusing an ID updates that reminder, preserving its existing batch membership.
    /// - Returns: Verified state, including pending and deferred IDs in `lastOutcome`.
    /// - Throws: Validation, authorization, persistence, scheduling, or cancellation errors.
    @discardableResult
    public func schedule(_ reminder: LocalReminder) async throws -> ReminderJournal {
        try await perform(individual: .schedule(reminder))
    }

    /// Replaces an existing reminder's date and content without changing other reminders.
    /// - Throws: `reminderNotFound` if the ID is not saved, or an operation error.
    /// - Returns: Verified scheduling state after the edit.
    @discardableResult
    public func update(_ reminder: LocalReminder) async throws -> ReminderJournal {
        try await perform(individual: .edit(reminder))
    }

    /// Cancels one saved reminder, preserving the rest of its batch and its generation boundary.
    /// - Throws: `reminderNotFound` if the ID is not saved, or an operation error.
    /// - Returns: Verified scheduling state after cancellation.
    @discardableResult
    public func removeReminder(_ id: String) async throws -> ReminderJournal {
        try await perform(individual: .remove(id))
    }

    /// Saves a named batch for the first time, or replaces its complete contents when the ID exists.
    /// Reminders omitted from a replacement are cancelled; other batches remain intact.
    /// - Returns: Verified scheduling state, including deferred reminders.
    /// - Throws: Validation, authorization, persistence, scheduling, or cancellation errors.
    @discardableResult
    public func scheduleBatch(_ id: String, reminders: [LocalReminder],
                              evaluatedThrough: Date? = nil) async throws -> ReminderJournal {
        try await replaceBatch(id, with: reminders, evaluatedThrough: evaluatedThrough)
    }

    /// Schedules the complete desired contents of one named batch.
    ///
    /// A new batch identifier creates a batch. Reusing it replaces its previous reminders; other batches
    /// are preserved. An empty array cancels this batch's reminders.
    /// - Parameters:
    ///   - id: The stable identifier of the batch to replace.
    ///   - reminders: All reminders that should belong to this batch after the update.
    ///   - evaluatedThrough: The earliest possible ungenerated reminder time, when
    ///     this batch covers only a finite window of a recurring source.
    /// - Returns: Verified scheduling state, including remaining coverage.
    /// - Throws: The same persistence, validation and scheduling errors as a batch update.
    @discardableResult
    public func replaceBatch(_ id: String, with reminders: [LocalReminder],
                             evaluatedThrough: Date? = nil) async throws -> ReminderJournal {
        try await update(batches: [ReminderBatch(id: id, reminders: reminders,
                                                evaluatedThrough: evaluatedThrough)])
    }

    /// Cancels and forgets one batch while preserving all other batches.
    /// - Parameter id: The stable identifier of the batch to remove.
    /// - Returns: Verified scheduling state after the removal.
    /// - Throws: Persistence, scheduling, verification or cancellation errors.
    @discardableResult
    public func removeBatch(_ id: String) async throws -> ReminderJournal {
        try await update(removing: [id])
    }

    /// Persists complete batches, including overflow, before touching pending notifications.
    /// Reusing a batch ID replaces that batch; pass an empty batch or remove its ID to cancel it.
    ///
    /// - Parameters:
    ///   - batches: Complete replacements for the supplied batch identifiers.
    ///   - removing: Batch identifiers to remove before applying replacements.
    /// - Returns: The journal after verifying the operating system's pending queue.
    /// - Throws: Validation, persistence, scheduling, verification, or cancellation errors.
    ///
    /// Once intent has been saved, a failure leaves that intent available for a later
    /// retry. See <doc:SchedulingAndRecovery>.
    @discardableResult
    public func update(batches: [ReminderBatch] = [], removing: [String] = []) async throws -> ReminderJournal {
        try await perform(batches: batches, removing: removing)
    }

    private func perform(batches: [ReminderBatch] = [], removing: [String] = [],
                         individual: IndividualChange? = nil) async throws -> ReminderJournal {
        let predecessor = tail
        generation += 1
        let token = generation
        let job = Task { @MainActor [reconciler] in
            _ = await predecessor?.result
            try Task.checkCancellation()
            try reconciler.policy.validate()
            guard Set(batches.map(\.id)).count == batches.count,
                  removing.allSatisfy({ !$0.isEmpty && $0 != Self.individualBatchID }),
                  batches.allSatisfy({ $0.id != Self.individualBatchID }) else { throw ReminderSchedulingError.invalidBatch }
            let operationTime = reconciler.now()
            let individualInput: [LocalReminder]
            switch individual {
            case .schedule(let reminder), .edit(let reminder): individualInput = [reminder]
            default: individualInput = []
            }
            let expiredInput = (batches.flatMap(\.reminders) + individualInput).filter { $0.date <= operationTime }.map(\.id).sorted()
            if !expiredInput.isEmpty { throw ReminderSchedulingError.expiredReminders(identifiers: expiredInput) }
            var journal = try reconciler.journalStore.load()
            let elapsedSaved = journal.batches.values.flatMap(\.reminders).filter { $0.date <= operationTime }
            for reminder in elapsedSaved { journal.recordElapsed(reminder, at: operationTime) }
            for id in removing { journal.batches.removeValue(forKey: id) }
            for batch in batches { journal.batches[batch.id] = batch }
            if let individual {
                let id: String
                let replacement: LocalReminder?
                let requiresExisting: Bool
                switch individual {
                case .schedule(let value):
                    id = value.id; replacement = value; requiresExisting = false
                case .edit(let value):
                    id = value.id; replacement = value; requiresExisting = true
                case .remove(let value):
                    id = value; replacement = nil; requiresExisting = true
                }
                guard !id.isEmpty, id != reconciler.policy.warningID else {
                    throw ReminderSchedulingError.invalidBatch
                }
                let matches = journal.batches.values.filter { $0.reminders.contains { $0.id == id } }
                guard matches.count <= 1 else { throw ReminderSchedulingError.invalidBatch }
                if requiresExisting && matches.isEmpty {
                    throw ReminderSchedulingError.reminderNotFound(identifier: id)
                }
                let batch = matches.first ?? journal.batches[Self.individualBatchID]
                    ?? ReminderBatch(id: Self.individualBatchID, reminders: [])
                var contents = batch.reminders.filter { $0.id != id }
                if let replacement { contents.append(replacement) }
                journal.batches[batch.id] = ReminderBatch(id: batch.id, reminders: contents,
                                                         evaluatedThrough: batch.evaluatedThrough)
            }
            let reminders = journal.batches.values.flatMap(\.reminders)
            guard Set(reminders.map(\.id)).count == reminders.count,
                  journal.batches.values.allSatisfy({ !$0.id.isEmpty
                      && ($0.evaluatedThrough?.timeIntervalSince1970.isFinite ?? true) }),
                  reminders.allSatisfy({ !$0.id.isEmpty && $0.id != reconciler.policy.warningID
                      && $0.date.timeIntervalSince1970.isFinite && ($0.badge.map { $0 >= 0 } ?? true) }) else {
                throw ReminderSchedulingError.invalidBatch
            }
            try reconciler.notifications.validate(reminders)
            for reminder in batches.flatMap(\.reminders) + individualInput {
                journal.record(reminder, at: operationTime, state: .awaitingScheduling)
            }
            let retainedIDs = Set(reminders.map(\.id))
            journal.reminderDiagnostics = journal.reminderDiagnostics?.filter {
                $0.value.state == .elapsed || retainedIDs.contains($0.key)
            }
            let elapsed = elapsedSaved.map(\.id)
            // Report elapsed saved requests instead of silently discarding them.
            journal.batches = journal.batches.mapValues {
                ReminderBatch(id: $0.id, reminders: $0.reminders.filter { $0.date > operationTime },
                              evaluatedThrough: $0.evaluatedThrough)
            }
            journal.needsReconciliation = true
            try reconciler.journalStore.save(journal)
            return try await reconciler.reconcile(
                candidates: journal.batches.values.flatMap(\.reminders),
                horizon: journal.batches.values.compactMap(\.evaluatedThrough).min(),
                elapsedReminderIDs: elapsed)
        }
        tail = job
        defer { if generation == token { tail = nil } }
        do {
            let result = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            onEvent?(.completed(result))
            return result
        } catch {
            onEvent?(.failed(error))
            throw error
        }
    }

    /// Reads retained per-reminder evidence without scheduling or prompting for permission.
    /// Call `refresh()` first to detect deadlines that passed while the app was not running.
    /// Results retain elapsed occurrences until that reminder ID is scheduled again.
    /// - Throws: Journal read or decoding errors.
    public func diagnostics() throws -> [ReminderDiagnostic] {
        let journal = try reconciler.journalStore.load()
        return (journal.reminderDiagnostics ?? [:]).values.sorted { $0.reminderID < $1.reminderID }
    }

    /// Replays persisted intent after interruption; never treats a background request as success.
    @discardableResult
    public func refresh() async throws -> ReminderJournal { try await update() }
}

/// Persists scheduling intent with atomic JSON file replacement.
///
/// Store the journal in protected app storage. Unreadable or corrupt data produces
/// an error rather than resetting the queue; see <doc:SchedulingAndRecovery>.
@MainActor
public final class FileReminderJournal: ReminderJournalStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> ReminderJournal {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ReminderJournal()
        }
        // Permission errors and corrupt state propagate instead of appearing to be an empty queue.
        return try JSONDecoder().decode(ReminderJournal.self, from: data)
    }
    public func save(_ journal: ReminderJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }
}
