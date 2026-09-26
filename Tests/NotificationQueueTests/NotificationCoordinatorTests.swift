import Foundation
import XCTest
@testable import NotificationQueue

@MainActor
final class NotificationCoordinatorTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_900_000_000)
    private var policy: ReminderPolicy {
        ReminderPolicy(namespace: "test", warningTitle: "Open app", warningBody: "Refresh reminders", coverageWarningsEnabled: true)
    }

    private func reminder(_ index: Int, after seconds: TimeInterval? = nil, title: String = "Reminder") -> LocalReminder {
        LocalReminder(id: "r\(index)", date: epoch.addingTimeInterval(seconds ?? Double(index + 1) * 3600),
                      title: title, body: "Details")
    }

    private func fixture() -> (NotificationCoordinator, FakeNotifications, MemoryJournal, TestClock) {
        let clock = TestClock(epoch)
        let notifications = FakeNotifications(clock: clock)
        let journal = MemoryJournal()
        let scheduler = NotificationCoordinator(notifications: notifications, journal: journal,
                                               policy: policy, now: { clock.date })
        return (scheduler, notifications, journal, clock)
    }

    func testOverflowPersistsAndNearestRequestsFitIncludingWarning() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        let values = (0..<100).reversed().map { reminder($0) }
        let result = try await scheduler.update(batches: [ReminderBatch(id: "week", reminders: values)])
        XCTAssertEqual(journal.value.batches["week"]?.reminders.count, 100)
        XCTAssertEqual(notifications.values.count, 60)
        XCTAssertEqual(result.planned?.reminders.map(\.id), (0..<59).map { "r\($0)" })
        XCTAssertEqual(result.coverageEnd, reminder(59).date)
        XCTAssertEqual(result.warningDate, reminder(59).date.addingTimeInterval(-24 * 3600))
        XCTAssertFalse(result.needsReconciliation)
    }

    func testIndependentBatchesCanBeReplacedAndRemoved() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        try await scheduler.update(batches: [ReminderBatch(id: "classes", reminders: [reminder(1)]),
                                             ReminderBatch(id: "tasks", reminders: [reminder(2)])])
        try await scheduler.update(batches: [ReminderBatch(id: "classes", reminders: [reminder(3)])])
        XCTAssertEqual(Set(notifications.values.keys), ["r2", "r3"])
        try await scheduler.update(removing: ["classes"])
        XCTAssertEqual(Set(notifications.values.keys), ["r2"])
        XCTAssertNil(journal.value.batches["classes"])
    }

    func testRefillUsesPersistedOverflowAfterRestart() async throws {
        let (scheduler, notifications, journal, clock) = fixture()
        try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: (0..<100).map { reminder($0) })])
        clock.date = epoch.addingTimeInterval(10 * 3600 + 1)
        let restarted = NotificationCoordinator(notifications: notifications, journal: journal,
                                               policy: policy, now: { clock.date })
        let result = try await restarted.refresh()
        XCTAssertEqual(result.planned?.reminders.first?.id, "r10")
        XCTAssertEqual(result.planned?.reminders.last?.id, "r68")
        XCTAssertEqual(notifications.values.count, 60)
        XCTAssertEqual(journal.value.batches["all"]?.reminders.count, 90)
    }

    func testUnchangedReconciliationDoesNotRescheduleRequests() async throws {
        let (scheduler, notifications, _, _) = fixture()
        try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: [reminder(0)])])
        let count = notifications.addCount
        try await scheduler.refresh()
        XCTAssertEqual(notifications.addCount, count)
    }

    func testEditsReplaceContentUnderStableIdentifier() async throws {
        let (scheduler, notifications, _, _) = fixture()
        try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: [reminder(0)])])
        let changed = reminder(0, title: "Updated location")
        try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: [changed])])
        XCTAssertEqual(notifications.values["r0"], changed)
        XCTAssertEqual(notifications.values.count, 1)
    }

    func testFailureRetainsDirtyIntentAndPreviousSuccess() async throws {
        let (scheduler, notifications, journal, clock) = fixture()
        try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: [reminder(0)])])
        let lastSuccess = journal.value.lastSuccessfulRefill
        clock.date = epoch.addingTimeInterval(1)
        notifications.rejectID = "r1"
        do {
            try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: [reminder(0), reminder(1)])])
            XCTFail("Expected scheduling failure")
        } catch {}
        XCTAssertTrue(journal.value.needsReconciliation)
        XCTAssertEqual(journal.value.lastSuccessfulRefill, lastSuccess)
        XCTAssertNotNil(notifications.values["r0"])
        notifications.rejectID = nil
        try await scheduler.refresh()
        XCTAssertFalse(journal.value.needsReconciliation)
        XCTAssertNotNil(notifications.values["r1"])
    }

    func testSilentDropsCannotBeReportedAsSuccess() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        notifications.silentlyDropAdds = true
        do {
            try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: [reminder(0)])])
            XCTFail("Expected verification failure")
        } catch ReminderSchedulingError.verificationFailed {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(journal.value.needsReconciliation)
        XCTAssertNil(journal.value.lastSuccessfulRefill)
    }

    func testFailedRemovalCannotBeReportedAsSuccess() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: [reminder(0)])])
        notifications.ignoreRemovals = true
        do {
            try await scheduler.update(removing: ["all"])
            XCTFail("Expected verification failure")
        } catch {}
        XCTAssertTrue(journal.value.needsReconciliation)
    }

    func testQueueBudgetAccountsForOtherFeatures() async throws {
        let (scheduler, notifications, _, _) = fixture()
        notifications.externalCount = 12
        try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: (0..<100).map { reminder($0) })])
        XCTAssertEqual(notifications.values.count, 51)
        XCTAssertEqual(notifications.externalCount + notifications.values.count, 63)
    }

    func testNoWarningWhenEveryKnownReminderFits() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: (0..<60).map { reminder($0) })])
        XCTAssertEqual(notifications.values.count, 60)
        XCTAssertNil(journal.value.coverageEnd)
        XCTAssertNil(journal.value.warningDate)
    }

    func testFiniteGenerationWindowGetsSafetyWarningEvenWithoutOverflow() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        let horizon = epoch.addingTimeInterval(7 * 86400)
        try await scheduler.update(batches: [ReminderBatch(id: "week", reminders: [reminder(0)], evaluatedThrough: horizon)])
        XCTAssertEqual(journal.value.warningDate, horizon.addingTimeInterval(-86400))
        XCTAssertNotNil(notifications.values[policy.warningID])
    }

    func testWarningDoesNotSlideWhenCoverageUnchangedOrRepeatWhenLow() async throws {
        let (scheduler, notifications, journal, clock) = fixture()
        let horizon = epoch.addingTimeInterval(8 * 3600)
        try await scheduler.update(batches: [ReminderBatch(id: "window", reminders: [], evaluatedThrough: horizon)])
        let warning = try XCTUnwrap(journal.value.warningDate)
        clock.date = epoch.addingTimeInterval(3600)
        try await scheduler.refresh()
        XCTAssertEqual(journal.value.warningDate, warning)
        clock.date = warning.addingTimeInterval(1)
        try await scheduler.refresh()
        XCTAssertNil(notifications.values[policy.warningID])
        try await scheduler.refresh()
        XCTAssertNil(notifications.values[policy.warningID])
        XCTAssertEqual(journal.value.warningDate, warning)
    }

    func testSuccessfulRefillMovesWarningAndRecoveryRearmsIt() async throws {
        let (scheduler, notifications, journal, clock) = fixture()
        try await scheduler.update(batches: [ReminderBatch(id: "window", reminders: [], evaluatedThrough: epoch.addingTimeInterval(8 * 3600))])
        clock.date = try XCTUnwrap(journal.value.warningDate).addingTimeInterval(1)
        let newHorizon = clock.date.addingTimeInterval(7 * 86400)
        try await scheduler.update(batches: [ReminderBatch(id: "window", reminders: [], evaluatedThrough: newHorizon)])
        XCTAssertEqual(notifications.values[policy.warningID]?.date, newHorizon.addingTimeInterval(-86400))
    }

    func testFailedRefillDoesNotMoveExistingWarning() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        try await scheduler.update(batches: [ReminderBatch(id: "window", reminders: [], evaluatedThrough: epoch.addingTimeInterval(8 * 3600))])
        let warning = notifications.values[policy.warningID]
        notifications.rejectID = "r0"
        do {
            try await scheduler.update(batches: [ReminderBatch(id: "window", reminders: [reminder(0)],
                evaluatedThrough: epoch.addingTimeInterval(7 * 86400))])
            XCTFail("Expected failure")
        } catch {}
        XCTAssertEqual(notifications.values[policy.warningID], warning)
        XCTAssertTrue(journal.value.needsReconciliation)
    }

    func testConcurrentBatchUpdatesDoNotLoseEachOthersChanges() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        let gate = Gate()
        notifications.gate = gate
        let first = Task { try await scheduler.update(batches: [ReminderBatch(id: "one", reminders: [reminder(0)])]) }
        await gate.waitUntilEntered()
        let second = Task { try await scheduler.update(batches: [ReminderBatch(id: "two", reminders: [reminder(1)])]) }
        gate.release()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(Set(journal.value.batches.keys), ["one", "two"])
        XCTAssertEqual(Set(notifications.values.keys), ["r0", "r1"])
    }

    func testCancellationAndRestartRecoverPersistedWork() async throws {
        let (scheduler, notifications, journal, clock) = fixture()
        let gate = Gate()
        notifications.gate = gate
        let run = Task { try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: [reminder(0), reminder(1)])]) }
        await gate.waitUntilEntered()
        run.cancel()
        gate.release()
        do { _ = try await run.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertTrue(journal.value.needsReconciliation)
        XCTAssertNil(journal.value.lastSuccessfulRefill)
        let restarted = NotificationCoordinator(notifications: notifications, journal: journal, policy: policy, now: { clock.date })
        try await restarted.refresh()
        XCTAssertFalse(journal.value.needsReconciliation)
        XCTAssertEqual(Set(notifications.values.keys), ["r0", "r1"])
    }

    func testDuplicateOrReservedIDsAreRejectedBeforeMutation() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        do {
            try await scheduler.update(batches: [ReminderBatch(id: "a", reminders: [reminder(0)]),
                                                 ReminderBatch(id: "b", reminders: [reminder(0)])])
            XCTFail("Expected invalid batch")
        } catch ReminderSchedulingError.invalidBatch {} catch { XCTFail("\(error)") }
        XCTAssertTrue(notifications.values.isEmpty)
        XCTAssertTrue(journal.value.batches.isEmpty)
        do {
            try await scheduler.update(batches: [ReminderBatch(id: "a", reminders: [LocalReminder(id: policy.warningID,
                date: epoch.addingTimeInterval(3600), title: "Reserved", body: "")])])
            XCTFail("Expected reserved ID rejection")
        } catch ReminderSchedulingError.invalidBatch {} catch { XCTFail("\(error)") }
    }

    func testJournalWriteFailureLeavesOSQueueUntouched() async throws {
        let (scheduler, notifications, journal, _) = fixture()
        journal.failWrites = true
        do {
            try await scheduler.update(batches: [ReminderBatch(id: "all", reminders: [reminder(0)])])
            XCTFail("Expected disk error")
        } catch {}
        XCTAssertEqual(notifications.addCount, 0)
        XCTAssertTrue(notifications.values.isEmpty)
    }

    func testFileJournalRoundTripAndCorruptionIsNotSilentlyDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let journal = FileReminderJournal(url: url)
        var value = ReminderJournal()
        value.batches["day"] = ReminderBatch(id: "day", reminders: [reminder(0)])
        try journal.save(value)
        XCTAssertEqual(try FileReminderJournal(url: url).load().batches["day"]?.reminders, [reminder(0)])
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try journal.load())
    }

    func testInterruptedWarningSubmissionDoesNotNagAgainAfterRestart() async throws {
        let (scheduler, notifications, journal, clock) = fixture()
        let boundary = epoch.addingTimeInterval(8 * 3600)
        journal.value.batches["window"] = ReminderBatch(id: "window", reminders: [], evaluatedThrough: boundary)
        journal.value.warningAttempt = LocalReminder(id: policy.warningID,
            date: epoch.addingTimeInterval(4 * 3600), title: "Open app", body: "Refresh reminders")
        clock.date = epoch.addingTimeInterval(5 * 3600)
        try await scheduler.refresh()
        XCTAssertNil(notifications.values[policy.warningID])
    }

    func testBadgeOnlyQueueDoesNotReserveOrScheduleAlertWarnings() async throws {
        let clock = TestClock(epoch)
        let store = FakeNotifications(clock: clock)
        let journal = MemoryJournal()
        let policy = ReminderPolicy(namespace: "badges", warningTitle: "", warningBody: "",
                                    coverageWarningsEnabled: false)
        let scheduler = NotificationCoordinator(notifications: store, journal: journal, policy: policy, now: { clock.date })
        let reminders = (0..<80).map {
            LocalReminder(id: "badge.\($0)", date: epoch.addingTimeInterval(Double($0 + 1) * 3600),
                          title: "", body: "", badge: $0)
        }
        let result = try await scheduler.update(batches: [ReminderBatch(id: "badges", reminders: reminders)])
        XCTAssertEqual(store.values.count, 60)
        XCTAssertNil(result.warningDate)
        XCTAssertEqual(result.coverageEnd, reminders[60].date)
        XCTAssertEqual(store.values["badge.0"]?.badge, 0)
    }

    func testBadgePersistsAndParticipatesInVerification() async throws {
        let (scheduler, store, journal, _) = fixture()
        let reminder = LocalReminder(id: "badge", date: epoch.addingTimeInterval(3600), title: "", body: "", badge: 4)
        try await scheduler.update(batches: [ReminderBatch(id: "badges", reminders: [reminder])])
        XCTAssertEqual(store.values["badge"]?.badge, 4)
        let decoded = try JSONDecoder().decode(ReminderJournal.self, from: JSONEncoder().encode(journal.value))
        XCTAssertEqual(decoded.batches["badges"]?.reminders.first?.badge, 4)
    }

    func testDatesAreNormalizedToAppleTriggerPrecision() async {
        let value = LocalReminder(id: "fractional", date: epoch.addingTimeInterval(0.875), title: "", body: "")
        XCTAssertEqual(value.date, epoch)
    }
}

@MainActor private final class TestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor private final class MemoryJournal: ReminderJournalStore {
    var value = ReminderJournal()
    var failWrites = false
    func load() throws -> ReminderJournal { value }
    func save(_ journal: ReminderJournal) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        value = journal
    }
}

@MainActor private final class FakeNotifications: ReminderNotificationStore {
    let clock: TestClock
    var values: [String: LocalReminder] = [:]
    var externalCount = 0
    var rejectID: String?
    var silentlyDropAdds = false
    var ignoreRemovals = false
    var addCount = 0
    var gate: Gate?
    init(clock: TestClock) { self.clock = clock }
    func pending() async -> [LocalReminder] {
        values = values.filter { $0.value.date > clock.date }
        return Array(values.values)
    }
    func otherPendingCount() async -> Int { externalCount }
    func add(_ reminder: LocalReminder) async throws {
        if let gate { self.gate = nil; await gate.enter() }
        try Task.checkCancellation()
        if reminder.id == rejectID { throw CocoaError(.fileWriteUnknown) }
        addCount += 1
        if !silentlyDropAdds { values[reminder.id] = reminder }
    }
    func remove(_ identifiers: [String]) async {
        if !ignoreRemovals { identifiers.forEach { values.removeValue(forKey: $0) } }
    }
}

@MainActor private final class Gate {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observer = $0 } }
    }
    func release() { blocked?.resume(); blocked = nil }
}
