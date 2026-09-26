<div>
  <h1>NotificationQueue <img src="resources/icon.png" alt="NotificationQueue icon" width="96" height="96" align="right"></h1>
  <p>Schedule more local reminders than the system can hold at once. NotificationQueue stores overflow and schedules the next reminders as slots become available and your app gets time to run.</p>
  <p><img src="https://img.shields.io/badge/iOS%20%2F%20iPadOS-16%2B-000000?logo=apple" alt="iOS / iPadOS 16+"> <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple" alt="macOS 13+"> <img src="https://img.shields.io/badge/Mac%20Catalyst-16%2B-000000?logo=apple" alt="Mac Catalyst 16+"> <img src="https://img.shields.io/badge/watchOS-9%2B-000000?logo=apple" alt="watchOS 9+"> <img src="https://img.shields.io/badge/tvOS-16%2B-000000?logo=apple" alt="tvOS 16+"> <img src="https://img.shields.io/badge/visionOS-1%2B-000000?logo=apple" alt="visionOS 1+"> <img src="https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&amp;logoColor=white" alt="Swift 5.10+"></p>
</div>


## How it works

- **Persistent overflow.** Save reminders individually or in named batches. The nearest reminders enter the system queue; the rest stay in the JSON journal for later refills.
- **Bounded scheduling.** The default budget is 60 pending requests, including any coverage warning. NotificationQueue uses a conservative 64-slot ceiling, accounts for other pending notifications, and keeps a spare slot for updates. It does not remove the system limit.
- **Automatic coverage warnings.** When saved overflow or a finite schedule window could leave a gap, the coordinator schedules a reminder to reopen your app. Refills update the warning, with repeat suppression during the same low-coverage period. Warnings are off by default on badge-only tvOS.
- **Execution opportunities.** Refresh on app activation and during background time your app receives. Background time is not guaranteed, and a delivered notification does not itself run the coordinator.
- **Explicit outcomes and errors.** Operations throw validation, permission, storage, scheduling, verification, and cancellation errors. Their scheduling receipts contain a `journal` with `lastOutcome`, identifying pending, deferred, and elapsed reminders plus warning status. An optional `onEvent` callback observes completion and failure; failures still throw.

Per-reminder diagnostics persist across launches. They distinguish capacity deferral, a rejected submission, incomplete verification, and a deadline reached without a verified refill. Previously scheduled reminders whose dates passed have **unknown delivery**, not an assumed failure. Inspect `try notifications.diagnostics()` after a refresh; failures can also be inspected after catching an operation error. Detection resumes when the app next runs—NotificationQueue cannot identify why background time was unavailable.

Pending requests are verified before a refill is recorded as successful. That verifies scheduling, not delivery: system settings and notification presentation remain under Apple's control. If an operation fails after intent was saved, `refresh()` retries it; if saving failed, resubmit the update. See [handling failures](Sources/NotificationQueue/Documentation.docc/Coverage/HandlingFailures.md).

## Quick start

Add NotificationQueue as a local Swift package and link the `NotificationQueue` product. This iOS SwiftUI example replaces the app's `@main` entry point: the coordinator lives in app state, the button requests permission and schedules a reminder, and returning to the app refreshes saved reminders.

```swift
import SwiftUI
import UserNotifications
import NotificationQueue

@main
@MainActor
struct ReminderDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var notifications = NotificationCoordinator(
        appName: "Reminder Demo",
        namespace: "com.example.reminders"
    )
    @State private var status = ""

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Button("Remind me in an hour") {
                    Task { await scheduleReminder() }
                }
                Text(status)
            }
            .padding()
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                do {
                    try await notifications.refresh()
                } catch is CancellationError {
                    status = "Refresh interrupted; it will retry when the app is active."
                } catch {
                    status = error.localizedDescription
                }
            }
        }
    }

    private func scheduleReminder() async {
        do {
            let allowed = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            guard allowed else {
                status = "Allow notifications in Settings to receive reminders."
                return
            }

            let reminder = LocalReminder(
                id: "demo.reminder", // Repeated button taps update this same reminder.
                date: Date().addingTimeInterval(3600),
                title: "Your reminder",
                body: "It's time to take a break."
            )
            let result = try await notifications.schedule(reminder)
            if result.journal.lastOutcome?.scheduledReminderIDs.contains(reminder.id) == true {
                status = "Reminder scheduled."
            } else if result.journal.lastOutcome?.deferredReminderIDs.contains(reminder.id) == true {
                status = "Reminder saved; waiting for a scheduling slot."
            } else {
                status = "The reminder time passed; delivery is unknown."
            }
        } catch {
            status = error.localizedDescription
        }
    }
}
```

`schedule(reminder)` works on the first call. Calling it again with the same ID updates that reminder; it does not create a duplicate. Use `refresh()` to refill saved reminders when your app gets time to run.

### Schedule, edit, and group reminders

Inside an async action using the same `notifications` coordinator, wrap these calls in `do` / `catch` as above:

```swift
// Omit the ID to generate one. The reminder also exposes it before scheduling.
let reminder = LocalReminder(
    date: Date().addingTimeInterval(3600),
    title: "Take a break", body: "Time to stretch."
)
let saved = try await notifications.schedule(reminder)

// Keep the returned ID to edit the same reminder later.
let edited = LocalReminder(
    id: saved.id, date: Date().addingTimeInterval(7200),
    title: "Take a break", body: "Your break moved to later."
)
try await notifications.update(edited)

let morning = LocalReminder(
    date: Date().addingTimeInterval(86400),
    title: "Morning reminder", body: "Plan your day."
)
let evening = LocalReminder(
    date: Date().addingTimeInterval(129600),
    title: "Evening reminder", body: "Review your day."
)

// Generate a batch ID and retain it for replacement or cancellation.
let group = try await notifications.scheduleBatch(reminders: [morning, evening])
try await notifications.replaceBatch(group.id, with: [morning])

// Or supply your own stable identifiers when scheduling.
let named = LocalReminder(
    id: "daily-break", date: Date().addingTimeInterval(3600),
    title: "Take a break", body: "Time to stretch."
)
try await notifications.schedule(named)
// For a named batch, supply the first argument to scheduleBatch, e.g. "tomorrow".
```

`LocalReminder` and `ReminderBatch` generate IDs when omitted or `nil`. Store `saved.id` or `group.id` in your app's model if you need them after relaunch. Creating another value without an ID creates a new identity; editing must reuse the original ID. `update(edited)` throws if that ID is unknown.

Scheduling returns a receipt containing the ID and a `journal` with scheduling outcomes and diagnostics. If batch scheduling throws, `BatchSchedulingError.batchID` preserves even a generated ID and `underlyingError` retains the cause. For individual failures, `reminder.id` is available before the call. Reuse those IDs for retries.

Both batch methods create a missing batch or replace an existing one. Use `removeReminder(saved.id)` or `removeBatch(group.id)` to cancel. See [individual reminders](Sources/NotificationQueue/Documentation.docc/Scheduling/IndividualReminders.md) and [batches](Sources/NotificationQueue/Documentation.docc/Scheduling/ManagingBatches.md) for details.

The **“Open Reminder Demo to keep reminders going” warning is built in**. NotificationQueue schedules it when coverage is running low, moves it after refills, and avoids repeating it during the same low-coverage period. This single-reminder example needs no warning because everything fits. You do not schedule the warning yourself.

This example refreshes when the app becomes active. To also refill during background execution, connect your app's platform-specific background task to the same coordinator; see the [SwiftUI integration guide](Sources/NotificationQueue/Documentation.docc/Integration/SwiftUIQuickStart.md). System notification presentation still follows app permissions; foreground banners require a notification delegate.

## Demo app

Open [NotificationQueueDemo.xcodeproj](Examples/NotificationQueueDemo/NotificationQueueDemo.xcodeproj) from a clone or download of this repository, choose the **NotificationQueueDemo** scheme and an iPhone or iPad simulator, and run it. The app shows pending reminders, overflow, batch contents, and retained diagnostics, with scheduling, editing, and cancellation controls. See the [demo guide](Examples/NotificationQueueDemo/README.md) for device signing and behaviour.

The demo references this package locally. It has its own app target under `Examples` and is not built or bundled into apps that depend on the NotificationQueue library.

## Documentation

The [DocC catalog](Sources/NotificationQueue/Documentation.docc/NotificationQueue.md) combines usage guides with the inline API documentation.

- [Scheduling](Sources/NotificationQueue/Documentation.docc/Scheduling/Scheduling.md) — batches, recurring sources, and the coordinator API.
- [Coverage](Sources/NotificationQueue/Documentation.docc/Coverage/Coverage.md) — queue replenishment, recovery, and warning policy.
- [Integration](Sources/NotificationQueue/Documentation.docc/Integration/Integration.md) — app lifecycle, persistence, and Apple platforms.
- [Customization](Sources/NotificationQueue/Documentation.docc/Customization/Customization.md) — store protocols and testing.
