# Coverage

Keep upcoming reminders scheduled and recover unfinished work.

@Options {
    @TopicsVisualStyle(detailedGrid)
}

## Overview

``NotificationQueue/ReminderPolicy`` controls the pending-request budget and coverage warning. The coordinator persists its selected ``NotificationQueue/ReminderPlan`` and verified state in a ``NotificationQueue/ReminderJournal`` so later execution opportunities can continue the work.

## Topics

### Queue Replenishment and Recovery

- <doc:SchedulingAndRecovery>
- ``NotificationQueue/ReminderPlan``
- ``NotificationQueue/ReminderJournal``
- ``NotificationQueue/ReminderSchedulingError``

### Outcomes and Failures

- <doc:HandlingFailures>
- ``NotificationQueue/ReminderOutcome``
- ``NotificationQueue/ReminderDiagnostic``
- ``NotificationQueue/ReminderSchedulingState``
- ``NotificationQueue/ReminderDiagnosticReason``
- ``NotificationQueue/ReminderEvent``
- ``NotificationQueue/ReminderWarningStatus``
- ``NotificationQueue/AppleReminderStoreError``

### Coverage Warnings

- <doc:CoverageWarnings>
- ``NotificationQueue/ReminderPolicy``
