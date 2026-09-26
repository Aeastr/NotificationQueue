# Platform Support

Integrate NotificationQueue with the notification capabilities of each Apple platform.

## Overview

The queue and persistence layer supports iOS/iPadOS 16+, Mac Catalyst 16+, macOS 13+, watchOS 9+, tvOS 16+, and visionOS 1+. Each app supplies execution opportunities appropriate to its platform.

On **tvOS**, Apple supports notification badges but not alert titles, bodies, or sounds. Supply a nonnegative `badge` value on each `LocalReminder` (`0` clears the badge). Text is retained as metadata and is not displayed. The Apple adapter rejects reminders without a badge before replacing batches. Coverage warning alerts are disabled by default on tvOS; the queue still reports `coverageEnd` for the host to handle. Keep that default when using the Apple adapter.

On the other platforms, the Apple adapter schedules alert content with the default sound and an optional badge; presentation remains subject to the platform's notification settings. NotificationQueue does not assume identical background execution or presentation across devices.
