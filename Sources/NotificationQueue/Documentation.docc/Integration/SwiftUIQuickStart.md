# SwiftUI Quick Start

Own the coordinator in app state, schedule reminders from user actions, and refresh when the app runs.

## Create the Coordinator at the App Level

The following iOS example replaces an app's `@main` entry point. `@State` keeps one coordinator for the app's lifetime; avoid constructing another coordinator for the same namespace in each view or each scheduling call.

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

## Choose the Operation

- Use `schedule(reminder)` to create or reschedule one reminder and `update(reminder)` to edit an existing one.
- Use `scheduleBatch(_:reminders:evaluatedThrough:)` to submit a group for the first time.
- Use ``NotificationQueue/NotificationCoordinator/replaceBatch(_:with:evaluatedThrough:)`` to replace one named batch, including its overflow.
- Use ``NotificationQueue/NotificationCoordinator/removeBatch(_:)`` to cancel one batch.
- Use ``NotificationQueue/NotificationCoordinator/update(batches:removing:)`` when several batch replacements and removals should be handled together.
- Use ``NotificationQueue/NotificationCoordinator/refresh()`` to replenish from persisted batches without changing their source data.

Pass the same coordinator to views or your app's reminder service. It does not need to be recreated after the user grants permission. ``NotificationQueue/ReminderPolicy`` provides custom warning text and timing when the built-in app-name setup is insufficient.

## Automatic Reopen-App Warning

The app-name initializer creates the default warning policy and a journal in Application Support. NotificationQueue decides when to schedule, move, or suppress the warning. No extra warning function is needed. A finite batch that fits completely, such as the example above, has no coverage warning. See <doc:CoverageWarnings> for overflow and generated schedule boundaries.

## Add Background Execution in the Host App

The example's scene-phase task refreshes on activation and is cancelled when the scene leaves that phase. Background execution is a separate integration: register and submit the appropriate platform task from your app, invoke `refresh()` on the same coordinator when that task actually runs, propagate expiration cancellation, and report completion after the operation finishes.

If the source data changed or your recurring schedule needs a new window, regenerate and replace the batches before reporting completion. `refresh()` only uses persisted occurrences. See <doc:AppIntegration> and <doc:GeneratedSchedules>.

## Presentation and Other Platforms

The example requests permission from an explicit button action. It does not install a notification delegate; your app decides whether notifications should show banners while it is in the foreground. On tvOS, request badge permission and supply a badge value instead of using this alert example. See <doc:PlatformSupport>.
