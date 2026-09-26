# Customization

Provide your own storage and notification adapters, or substitute deterministic test doubles.

@Options {
    @TopicsVisualStyle(detailedGrid)
}

## Overview

Pass implementations of ``NotificationQueue/ReminderNotificationStore`` and ``NotificationQueue/ReminderJournalStore`` to the coordinator's injected initializer. The scheduling policy stays the same while your implementations control how requests are applied and how intent is persisted.

## Topics

### Store Contracts

- ``NotificationQueue/ReminderNotificationStore``
- ``NotificationQueue/ReminderJournalStore``

### Testing Scheduling Behaviour

- <doc:Testing>
