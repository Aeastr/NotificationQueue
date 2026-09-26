# Individual Reminders

Schedule, edit, and cancel one reminder using its stable identifier.

## Schedule a Reminder

Call `try await notifications.schedule(reminder)` on your app's long-lived ``NotificationQueue/NotificationCoordinator``. The first call saves a new reminder. Reusing its ID replaces its date and content. The returned journal's `lastOutcome` distinguishes reminders currently pending from those saved in overflow.

The <doc:SwiftUIQuickStart> shows where the coordinator lives and where to call it in a SwiftUI app. Request permission before scheduling, and handle thrown errors at the call site.

## Edit or Cancel

Use `try await notifications.update(editedReminder)` with the original ID to edit a saved reminder. Use `try await notifications.removeReminder(id)` to cancel it. Both throw `ReminderSchedulingError.reminderNotFound` when the ID is not saved. An elapsed reminder may have been pruned by a refresh; use `schedule` to create a new future occurrence.

Individual operations also work on reminders inside named batches. They preserve other reminders and the batch's generation boundary. Replacing that entire batch later supplies its new authoritative contents, so it can overwrite individual edits.

## Persistence and Ordering

Individual edits share the same serialized journal updates, verification, error observation, and recovery as batch operations. Newly scheduled standalone reminders use an internal batch; `__notificationqueue.individual` is reserved and cannot be passed to public batch operations. Reminder IDs remain unique across standalone reminders and named batches. Scheduling an existing ID edits it in place rather than moving it between batches.

See <doc:ManagingBatches> for groups and <doc:HandlingFailures> for results and recovery.
