# ``NotificationQueue``

Schedule more local reminders than the system can hold at once.

@Options {
    @TopicsVisualStyle(detailedGrid)
}

## Overview

NotificationQueue stores reminder batches, keeps the nearest reminders scheduled, and replenishes available slots whenever your app gets time to run. Your app supplies dated reminders and lifecycle opportunities; ``NotificationCoordinator`` manages the queue and persists overflow.

Start with <doc:Scheduling>, then connect your app through <doc:Integration>. Explore <doc:Coverage> for queue replenishment and warnings, or <doc:Customization> to supply your own stores.

## Topics

### Explore NotificationQueue

- <doc:Scheduling>
- <doc:Coverage>
- <doc:Integration>
- <doc:Customization>
