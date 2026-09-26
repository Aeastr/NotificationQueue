# Managing Batches

Replace and remove groups of reminders without disturbing other scheduled work.

## Overview

Create one long-lived ``NotificationCoordinator`` for each journal and namespace. Request notification permission through your app's UI before submitting reminders. The coordinator handles queue management; your app retains control of permission prompts, notification delegates, and background execution.

Use ``ReminderBatch`` to group reminders by a useful unit such as a day, a project, or a collection of assignments. `scheduleBatch(_:reminders:evaluatedThrough:)` creates the first batch. Reusing a batch identifier with either `scheduleBatch` or `replaceBatch` replaces its entire contents; `replaceBatch` also creates a batch if it does not exist. Passing an empty batch or removing its identifier cancels its reminders.

```swift
import Foundation
import NotificationQueue

@MainActor
func replaceMeetingBatch(
    using coordinator: NotificationCoordinator,
    meetingStart: Date
) async throws {
    let reminder = LocalReminder(
        id: "meeting.42",
        date: meetingStart.addingTimeInterval(-600),
        title: "Design review",
        body: "Starts in 10 minutes"
    )
    try await coordinator.replaceBatch("meetings", with: [reminder])
}
```

The batch identifier `__notificationqueue.individual` is reserved for standalone reminders.

Identifiers must be stable, nonempty, and unique across all batches. `__coverage` is reserved for the coverage warning. Overlapping date-range batches must not contain duplicate reminder identifiers; replace a shared batch or remove overlapping batches in the same update.

## Remove a Batch

```swift
try await coordinator.removeBatch("meetings")
```

Removal affects only the named batch. Other batches retain their reminders and compete for available slots in chronological order.

## Refresh Saved Work

```swift
let state = try await coordinator.refresh()
```

Refresh replenishes the queue from persisted batches. Read the returned ``ReminderJournal`` for verified refill time and coverage. When your app's data changes, replace the affected batches instead of replaying stale data. See <doc:GeneratedSchedules> for recurring sources with a finite generation window.

## Generated Batch IDs

```swift
let saved = try await coordinator.scheduleBatch(reminders: reminders)
// Persist saved.id in your app's model for later use.
try await coordinator.replaceBatch(saved.id, with: revisedReminders)
```

Here `reminders` and `revisedReminders` are arrays supplied by your app. Omit the first argument or pass `nil` to generate an ID; pass a string to choose one. The returned ``NotificationQueue/BatchReceipt`` contains `id`, the submitted `batch`, and its verified `journal`.

You can also create `let batch = ReminderBatch(reminders: reminders)` and call `scheduleBatch(batch)`. Its ID is available before scheduling. Reuse the batch or ID on retries: creating a fresh generated ID creates a separate batch.

Both `scheduleBatch` overloads throw ``NotificationQueue/BatchSchedulingError``. Its `batchID` preserves generated identity even on failure, while `underlyingError` preserves the original error, including cancellation. Existing `replaceBatch`, `update(batches:)`, and individual operations continue to throw their original errors directly. The coordinator's `onEvent` failure observer receives that original operation error.

```swift
do {
    let saved = try await coordinator.scheduleBatch(reminders: reminders)
    // Store saved.id and inspect saved.journal.lastOutcome.
    print(saved.id)
} catch let failure as BatchSchedulingError {
    // Retain failure.batchID for recovery; do not generate another ID on retry.
    print(failure.batchID, failure.underlyingError.localizedDescription)
}
```
