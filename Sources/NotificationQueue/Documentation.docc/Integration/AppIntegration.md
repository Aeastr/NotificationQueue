# App Integration

Supply permission, fresh reminder data, and execution opportunities from your app.

## Overview

Call `update()` after domain edits and when generating fresh occurrences. Call `refresh()` on launch or other execution opportunities when the persisted batches remain current. A host may use `BGAppRefreshTask`, but submitting that request is not proof a refill happened. Cancellation of the caller propagates into the scheduling pass.

Local delivery does not wake your coordinator. NotificationQueue works within the system’s pending-request limit. Continued delivery of distinct reminders depends on future execution opportunities to refill the queue. The warning itself is scheduled in advance and does not depend on a future background task. If other features consume every available slot, no warning slot can be created.

The Apple adapter supports dated, nonrepeating notifications, with presentation adapted to the platform as described in <doc:PlatformSupport>. Custom transports and journals can implement `ReminderNotificationStore` and `ReminderJournalStore`; those protocols also allow deterministic tests without notification permission or a running app.
