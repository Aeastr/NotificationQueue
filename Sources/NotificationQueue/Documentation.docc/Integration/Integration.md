# Integration

Connect NotificationQueue to your app's lifecycle, storage, and platform capabilities.

@Options {
    @TopicsVisualStyle(detailedGrid)
}

## Overview

Your app supplies notification permission, current reminder data, and time to execute. ``NotificationQueue/AppleReminderStore`` translates reminders into system notification requests, while ``NotificationQueue/FileReminderJournal`` saves scheduling intent to protected app storage.

## Topics

### App Lifecycle and Persistence

- <doc:SwiftUIQuickStart>
- <doc:AppIntegration>
- ``NotificationQueue/FileReminderJournal``

### Apple Platforms

- <doc:PlatformSupport>
- ``NotificationQueue/AppleReminderStore``
- ``NotificationQueue/AppleReminderStoreError``
