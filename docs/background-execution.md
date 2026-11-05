# Running LocaLM in the background on iPhone (researched Oct 28, 2026)

## Short version

There is no setting that lets a third-party iPhone app keep an LLM running in the background. iOS
suspends apps shortly after they leave the screen and refuses GPU work from background apps
(`IOGPUMetalError: Insufficient Permission (to submit GPU work from background)`). What *does* work in
the background is deterministic code, system-delivered alarms/notifications, and Siri/Shortcuts intents.
LocaLM now uses all of those.

## The options, and what LocaLM does with each

| Mechanism | What iOS gives you | Used in LocaLM for |
|---|---|---|
| `UIBackgroundModes: fetch` + `BGAppRefreshTask` | Short, opportunistic runs (≈30 s), scheduled by iOS based on how often the app is used. Not guaranteed. | Refreshing the morning-briefing notifications (`com.nikilthalapaneni.localm.briefing-refresh`). |
| `UIBackgroundModes: processing` + `BGProcessingTask` | Longer runs, usually overnight; can require charging. Not guaranteed. | Database maintenance while charging (`…maintenance`): WAL checkpoint + FTS optimize. |
| `BGContinuedProcessingTask` (iOS 26) | Lets a task the user just started keep running after they leave the app, with a system progress UI. **Background GPU** needs the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement *and* device support (`BGTaskScheduler.supportedResources.contains(.gpu)`). | Not used for the LLM: developer reports and Apple forum replies say background GPU is iPad-only so far; the self-test records the real value for each device. |
| `beginBackgroundTask` | A few extra seconds to finish in-flight work. | Stopping a reply cleanly when the user leaves mid-answer (saved, marked "Stopped", nothing executed). |
| AlarmKit (iOS 26) | System alarms and timers that ring through Silent mode and Focus, with the app closed. | `set_timer`, `set_alarm` tools. Falls back to a local notification if alarm permission is denied. |
| EventKit reminders / `UNUserNotificationCenter` | Delivered by the system at the scheduled time; app can be closed. | Reminders, morning briefing. |
| App Intents (`supportedModes: .background`) | Siri / Shortcuts / Spotlight can run app code without opening the app (no GPU). | "LocaLM briefing" (reads today's events and reminders aloud), "Save a memory in LocaLM". |
| App Intents (`supportedModes: .foreground`) | Opens the app to handle the request. | "Ask LocaLM …" opens the app and sends the request to the model. |
| `UIBackgroundModes: audio` / `location` / `voip` | Keep-alive modes for real audio playback, navigation, and calls. | Not used. Using them to keep an LLM alive is an App Store rejection reason (Guideline 2.5.4). |

## Reliable vs best effort

- **Reliable with the app closed:** alarms/timers, reminders, pre-scheduled briefing notifications
  (the next 3 days are scheduled every time the app opens), Siri briefing and memory intents.
- **Best effort:** the briefing refresh task and overnight maintenance; iOS decides if and when they run,
  and the user can disable Background App Refresh.
- **Not possible on iPhone today:** generating LLM replies while the app is in the background,
  monitoring email or anything else continuously.

## Sources

- Apple, WWDC25 "Finish tasks in the background" (BGAppRefreshTask, BGProcessingTask,
  BGContinuedProcessingTask, background GPU "on supported devices"):
  https://developer.apple.com/videos/play/wwdc2025/227/
- Apple Developer Forums, background GPU via continued processing reported as iPad-only on iOS 26:
  https://developer.apple.com/forums/thread/797538 and https://developer.apple.com/forums/thread/802789
- Apple Developer Forums, `supportedResources` lacks `.gpu` on iPhone 16 Pro Max (iOS 26):
  https://developer.apple.com/forums/tags/backgroundtasks?page=8
- Apple, WWDC25 "Wake up to the AlarmKit API": https://developer.apple.com/videos/play/wwdc2025/230/
- App Intents `supportedModes` replaces `openAppWhenRun` in iOS 26 (from the iOS 26.1 SDK interface).
