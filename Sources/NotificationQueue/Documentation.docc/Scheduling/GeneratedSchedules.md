# Generated Schedules

Provide a coverage boundary when expanding recurring events into dated reminders.

## Overview

If your app expands a recurring source only through a certain date, supply `evaluatedThrough`. It is the earliest instant at which the source may need another reminder that has not been generated, accounting for any lead time.

In this example, `expandedReminders` is the list your app generated, and `nextUngeneratedReminderBoundary` is the earliest time the next ungenerated reminder could be due.

```swift
try await coordinator.update(batches: [
    ReminderBatch(id: "upcoming", reminders: expandedReminders,
                  evaluatedThrough: nextUngeneratedReminderBoundary)
])
```

`refresh()` replenishes from saved batches; it cannot invent future occurrences beyond that boundary. Your host must regenerate and replace the batch when it receives execution time. Finite lists of all known reminders can omit the boundary.
