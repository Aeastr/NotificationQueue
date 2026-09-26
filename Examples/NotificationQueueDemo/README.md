# NotificationQueue Demo

Explore real local reminders, overflow, generated IDs, batch replacement, and retained diagnostics.

## Run

1. Clone or download the whole NotificationQueue repository.
2. Open `NotificationQueueDemo.xcodeproj` in this folder using Xcode 26 or later (for the Icon Composer app icon).
3. Select the **NotificationQueueDemo** scheme and an iPhone or iPad simulator, then Run.
4. Tap **Allow notifications**, then schedule a reminder.

The project supports iOS / iPadOS 16+ and Mac Catalyst. For a physical device, select your development team under Signing & Capabilities and use a unique bundle identifier if required. The project references the package at `../..`; keep the repository's folder structure intact.

## Explore

- **Pending** reads the demo's actual requests from UserNotifications, including its automatic coverage warning.
- **Waiting** shows saved future reminders absent from that snapshot. Diagnostics explain capacity deferrals and known failures.
- **Batches** shows group IDs and contents, with individual editing, batch replacement, and cancellation.
- **Diagnostics** retains per-reminder evidence, including expired overflow and unknown delivery.

The editor generates an ID once and keeps it through retries, or accepts your own ID. Edits preserve identity. Scheduling 80 reminders demonstrates overflow: the default pending budget is 60 including a coverage warning. Batch reminders start five minutes later and are five minutes apart. These are real notifications; use **Cancel all demo reminders** when finished. Cancellation clears pending demo reminders, not notifications already delivered to Notification Center.

Returning to the app automatically refreshes its queue. **Refresh and refill** does the same manually; **Inspect without refilling** only reads saved state and pending requests. Errors remain visible, including stale-snapshot warnings when reads fail. The foreground delegate allows banners while the demo is open.

This example supplies foreground execution only. It deliberately does not register platform background tasks, so it can demonstrate what happens to overflow when no refill runs before a deadline. The system still handles requests already scheduled. A pending request is not proof of eventual delivery, and no UI callback runs while the app is suspended.

## Packaging

This app is an independent Xcode target, outside the package's `Sources` and `Tests`. It references the local NotificationQueue library. The package manifest does not reference the demo, and the library does not copy its source or resources into consuming apps. The demo ships in the repository for people to run themselves.
