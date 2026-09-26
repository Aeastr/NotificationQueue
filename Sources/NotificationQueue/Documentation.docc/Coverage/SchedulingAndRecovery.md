# Scheduling and Recovery

Understand how NotificationQueue selects pending reminders and resumes interrupted work.

## Overview

- Default budget: 60 pending requests, including one coverage warning when needed. Requests belonging to other namespaces count against Apple's 64-request ceiling and are never deleted by NotificationQueue. At least one slot stays free for safe replacement while an existing warning remains scheduled.
- Earliest reminders win, with stable ID ordering for ties. Overflow is persisted with the batch, rather than sent to iOS and discarded.
- Updates run sequentially across suspension points. Repeating an update does not duplicate unchanged notifications.
- Intent is atomically saved before changing pending requests. `lastSuccessfulRefill` advances only after verifying the requested notifications and removals.
- Failures and cancellation retain unfinished intent. A later `refresh()` or `update()` retries it. Valid unchanged notifications remain in place; edits are not implemented by clearing the whole queue.
- Warning attempts are journaled before submission, so interruption after delivery does not cause repeated warnings. If the attempt's outcome is unknowable, NotificationQueue conservatively favours avoiding a duplicate warning.
- Dates are normalized to whole seconds, matching Apple's calendar triggers. The Apple adapter uses absolute UTC instants; the host regenerates local-calendar occurrences after timezone changes.

The journal contains notification text. Keep it in your app's protected storage. Do not use multiple coordinator instances or processes to write the same journal concurrently. A corrupted/unreadable journal produces an error rather than silently replacing the plan with an empty one.
