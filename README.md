<div>
  <h1>NotificationQueue <img src="resources/icon.png" alt="NotificationQueue icon" width="96" height="96" align="right"></h1>
  <p>Schedule more local reminders than the system can hold at once. NotificationQueue stores overflow and schedules the next reminders as slots become available and your app gets time to run.</p>
  <p><img src="https://img.shields.io/badge/iOS%20%2F%20iPadOS-16%2B-000000?logo=apple" alt="iOS / iPadOS 16+"> <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple" alt="macOS 13+"> <img src="https://img.shields.io/badge/Mac%20Catalyst-16%2B-000000?logo=apple" alt="Mac Catalyst 16+"> <img src="https://img.shields.io/badge/watchOS-9%2B-000000?logo=apple" alt="watchOS 9+"> <img src="https://img.shields.io/badge/tvOS-16%2B-000000?logo=apple" alt="tvOS 16+"> <img src="https://img.shields.io/badge/visionOS-1%2B-000000?logo=apple" alt="visionOS 1+"> <img src="https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&amp;logoColor=white" alt="Swift 5.10+"></p>
</div>

## Platform behaviour

The queue and persistence layer supports iOS/iPadOS 16+, Mac Catalyst 16+, macOS 13+, watchOS 9+, tvOS 16+, and visionOS 1+. Each app supplies execution opportunities appropriate to its platform.

On **tvOS**, Apple supports notification badges but not alert titles, bodies, or sounds. Supply a nonnegative `badge` value on each `LocalReminder` (`0` clears the badge). Text is retained as metadata and is not displayed. The Apple adapter rejects reminders without a badge before replacing batches. Coverage warning alerts are disabled by default on tvOS; the queue still reports `coverageEnd` for the host to handle. Keep that default when using the Apple adapter.

On the other platforms, the Apple adapter schedules alert content with the default sound and an optional badge; presentation remains subject to the platform's notification settings. The package does not assume identical background execution or presentation across devices.

## Quick start

Add this directory as a local Swift package and link the `NotificationQueue` product.

```swift
import Foundation
import NotificationQueue

@MainActor
func makeCoordinator() -> NotificationCoordinator {
    NotificationCoordinator(
        policy: ReminderPolicy(
            namespace: "com.example.reminders",
            warningTitle: "Open the app to keep reminders going",
            warningBody: "Refresh your upcoming reminders."
        ),
        journalURL: URL.applicationSupportDirectory
            .appending(path: "Reminders/journal.json")
    )
}
```

Keep one coordinator alive per journal/namespace. Request notification permission in your app's UI before scheduling. The package never prompts, installs a notification delegate, starts a background task, or knows what a class or assignment is.

```swift
let meeting = LocalReminder(
    id: "meeting.42",
    date: meetingStart.addingTimeInterval(-600),
    title: "Design review",
    body: "Starts in 10 minutes"
)

// Same batch ID replaces its contents. Other batches are preserved.
try await coordinator.update(batches: [
    ReminderBatch(id: "meetings", reminders: [meeting]),
    ReminderBatch(id: "tasks", reminders: taskReminders)
])

// Recover saved intent and replenish from persisted overflow.
let state = try await coordinator.refresh()

// Cancel a whole batch without disturbing the others.
try await coordinator.update(removing: ["meetings"])
```

IDs must be stable, nonempty and unique across all batches. `__coverage` is reserved. An empty batch cancels that batch's reminders. Overlapping date-range batches must not duplicate reminder IDs; replace a shared batch instead, or remove overlapping batches in the same update.

## Generated schedules

If your app expands a recurring source only through a certain date, supply `evaluatedThrough`. It is the earliest instant at which the source may need another reminder that has not been generated, accounting for any lead time.

```swift
try await coordinator.update(batches: [
    ReminderBatch(id: "upcoming", reminders: expandedReminders,
                  evaluatedThrough: nextUngeneratedReminderBoundary)
])
```

`refresh()` replenishes from saved batches; it cannot invent future occurrences beyond that boundary. Your host must regenerate and replace the batch when it receives execution time. Finite lists of all known reminders can omit the boundary.

## Scheduling and recovery

- Default budget: 60 pending requests, including one coverage warning when needed. Requests belonging to other namespaces count against Apple's 64-request ceiling and are never deleted by this package. At least one slot stays free for safe replacement while an existing warning remains scheduled.
- Earliest reminders win, with stable ID ordering for ties. Overflow is persisted with the batch, rather than sent to iOS and discarded.
- Updates run sequentially across suspension points. Repeating an update does not duplicate unchanged notifications.
- Intent is atomically saved before changing pending requests. `lastSuccessfulRefill` advances only after verifying the requested notifications and removals.
- Failures and cancellation retain unfinished intent. A later `refresh()` or `update()` retries it. Valid unchanged notifications remain in place; edits are not implemented by clearing the whole queue.
- Warning attempts are journaled before submission, so interruption after delivery does not cause repeated warnings. If the attempt's outcome is unknowable, the package conservatively favours avoiding a duplicate warning.
- Dates are normalized to whole seconds, matching Apple's calendar triggers. The Apple adapter uses absolute UTC instants; the host regenerates local-calendar occurrences after timezone changes.

The journal contains notification text. Keep it in your app's protected storage. Do not use multiple coordinator instances or processes to write the same journal concurrently. A corrupted/unreadable journal produces an error rather than silently replacing the plan with an empty one.

## Coverage warnings

The boundary is the earliest omitted reminder or generation boundary, whichever comes first. A warning defaults to 24 hours before it, or halfway through the remaining coverage when less than 48 hours remains. Both the maximum lead and recovery interval are configurable through `ReminderPolicy`.

Successful refills move the warning later. An unchanged boundary does not keep postponing it. Once the warning's scheduled time passes, the package suppresses another warning during that low-coverage episode; it rearms after coverage meaningfully extends beyond the recovery interval, or after all work becomes covered and a new shortfall appears. Pending state verifies scheduling, not actual presentation—permissions, Focus and OS behaviour still apply.

## Host responsibilities

Call `update()` after domain edits and when generating fresh occurrences. Call `refresh()` on launch or other execution opportunities when the persisted batches remain current. A host may use `BGAppRefreshTask`, but submitting that request is not proof a refill happened. Cancellation of the caller propagates into the scheduling pass.

Local delivery does not wake your coordinator. The package cannot guarantee background execution, exceed the pending-request limit, or deliver an unlimited sequence of unique notifications without future execution time. The warning itself is scheduled in advance and does not depend on a future background task. If other features consume every available slot, no warning slot can be created.

The Apple adapter supports dated, nonrepeating notifications, with presentation adapted to the platform as described above. Custom transports and journals can implement `ReminderNotificationStore` and `ReminderJournalStore`; those protocols also allow deterministic tests without notification permission or a running app.

## Tests

The XCTest suite covers batch replacement/removal, overflow and restart, concurrent updates, cancellation, failed writes/additions/removals, silent OS drops, external queue usage, warning timing and suppression, and journal corruption. The fake-store tests do not require a simulator or notification permission.
