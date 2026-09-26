# Coverage Warnings

Configure a reminder to reopen your app before scheduled coverage runs out.

## Automatic Setup

Use the app-name initializer to enable the built-in reopen-app warning:

```swift
let notifications = NotificationCoordinator(
    appName: "My App",
    namespace: "com.example.reminders"
)
```

NotificationQueue automatically creates, moves, and suppresses the warning during scheduling passes. Do not submit a separate reminder for it. The warning uses a reserved identifier and counts toward the queue budget. It is absent when all known reminders fit and there is no ungenerated schedule boundary. On tvOS, warning alerts remain disabled by default.

For different wording, timing, or capacity, initialize with a custom ``NotificationQueue/ReminderPolicy`` and journal URL instead. See <doc:SwiftUIQuickStart> for the app-level setup and <doc:GeneratedSchedules> for finite generation windows.

## Timing and Recovery

The boundary is the earliest omitted reminder or generation boundary, whichever comes first. A warning defaults to 24 hours before it, or halfway through the remaining coverage when less than 48 hours remains. Both the maximum lead and recovery interval are configurable through `ReminderPolicy`.

Successful refills move the warning later. An unchanged boundary does not keep postponing it. Once the warning's scheduled time passes, NotificationQueue suppresses another warning during that low-coverage episode; it rearms after coverage meaningfully extends beyond the recovery interval, or after all work becomes covered and a new shortfall appears. Pending state verifies scheduling, not actual presentation—permissions, Focus and OS behaviour still apply.
