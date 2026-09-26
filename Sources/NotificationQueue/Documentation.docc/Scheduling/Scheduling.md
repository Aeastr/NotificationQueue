# Scheduling

Schedule individual reminders or replaceable groups.

@Options {
    @TopicsVisualStyle(detailedGrid)
}

## Overview

Use ``NotificationQueue/NotificationCoordinator`` to submit and replace groups of ``NotificationQueue/LocalReminder`` values. A ``NotificationQueue/ReminderBatch`` identifies the group and, for generated schedules, records how far your app has expanded its source data.

## Topics

### Individual Reminders

- <doc:IndividualReminders>

### Working with Batches

- <doc:ManagingBatches>
- ``NotificationQueue/NotificationCoordinator``
- ``NotificationQueue/ReminderBatch``
- ``NotificationQueue/LocalReminder``

### Expanding Recurring Events

- <doc:GeneratedSchedules>
