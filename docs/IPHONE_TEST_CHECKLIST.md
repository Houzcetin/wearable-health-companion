# iPhone test checklist

Step-by-step checks on a **real iPhone** for the workout features and the main flow. None of this has been verified in the Linux workspace; the Swift code, background refresh, notifications and CoreMotion only run on a device. Sources: [`app/lib/features/workouts/README.md`](../app/lib/features/workouts/README.md) ("Real iPhone verification") and the open "verify on device" notes in the workout pull requests.

How to use it: tick a box only when the **Expected** result is what you saw. Write what you saw next to any box that fails, with the iOS version and build.

Tester: ____________ Date: ____________ iPhone / iOS: ____________ Build (commit): ____________

## 0. Before you start

- A Mac with a current Xcode, an iPhone cabled to it, and a Google account that is a test user of the Google Cloud project and has set up the Google Health or Fitbit app (see [SETUP.md](SETUP.md)).
- Bundle ID `com.wearablecompanion.wearableCompanion`; background task identifier `com.wearablecompanion.workouts.refresh`.
- Know the pass/fail rule: a step passes only if the app does what **Expected** says without a crash, a stuck spinner or a duplicate entry.

## 1. Build and install

| # | Step | Expected | Done |
|---|---|---|---|
| 1.1 | `cd app && flutter pub get`, then open `ios/Runner.xcworkspace` in Xcode. | The project opens with no missing-package errors. | ☐ |
| 1.2 | Runner target → **Signing & Capabilities**: choose your Team and let Xcode manage signing. | No red signing errors; a provisioning profile is created. | ☐ |
| 1.3 | Same tab → **Background Modes**: **Background fetch** is ticked. | `fetch` is listed (it is also `UIBackgroundModes` in Info.plist). | ☐ |
| 1.4 | Info.plist: `BGTaskSchedulerPermittedIdentifiers` contains `com.wearablecompanion.workouts.refresh`; `NSMotionUsageDescription` is present. | The identifier matches the one in `WorkoutMotionHistory.swift`; the motion text reads "Recognize walks, runs and bike rides and count steps for your workouts." | ☐ |
| 1.4a | `ios/Flutter/Google.xcconfig` exists (copied from `Google.xcconfig.example`; it is git-ignored) and both `GOOGLE_IOS_CLIENT_ID` and `GOOGLE_REVERSED_CLIENT_ID` are filled from the **same** iOS OAuth client. `.env.json` has the same `GOOGLE_IOS_CLIENT_ID`. See [SETUP.md](SETUP.md). | No `YOUR_IOS_CLIENT_ID` placeholder is left. The reversed ID is `com.googleusercontent.apps.<the client ID without .apps.googleusercontent.com>`. | ☐ |
| 1.5 | Select your iPhone and press **Run** (⌘R). | The app builds, installs and launches. `WorkoutMotionHistory.swift` is compiled and the method channel registers (no "missing plugin" log). | ☐ |
| 1.5a | After the build, inspect the built Info.plist: `plutil -p <path to Runner.app>/Info.plist` (for example `app/build/ios/iphoneos/Runner.app/Info.plist` after `flutter build ios`, or the Runner.app under Xcode's DerivedData). | `GIDClientID` shows your iOS client ID and `CFBundleURLSchemes` contains the reversed client ID, both with real values, not `$(GOOGLE_IOS_CLIENT_ID)` or `$(GOOGLE_REVERSED_CLIENT_ID)`. | ☐ |
| 1.6 | Trust the developer profile on the phone if asked (Settings → General → VPN & Device Management). | The app opens. | ☐ |
| 1.7 | Press **⌘U** with the `RunnerTests` scheme. | All RunnerTests pass, including `testMotionHistoryGolden`, the active-marker expiry tests and the revision tests. The JSON resource loads from the test bundle. | ☐ |

## 2. First flow

| # | Step | Expected | Done |
|---|---|---|---|
| 2.1 | Fresh install, launch. | Intro screen, **Continue**. **No notification or motion permission prompt** appears at launch. | ☐ |
| 2.2 | **Continue** → **Sign in** with Google. | The Google sheet opens and returns to the app (nonce check: sign-in succeeds). | ☐ |
| 2.3 | Read "Your health-data consent". Tap **Not now** once, then repeat the flow and tap **I agree**. | **Not now** leaves you in the app without data. **I agree** continues to connect. | ☐ |
| 2.4 | **Connect Google Health**, approve in the browser window. | Returns to the app; connection shows as **Connected** in Settings. | ☐ |
| 2.5 | Today → **Sync now**. | Spinner, then sleep, heart rate and steps cards with a lead sentence. "Last synced" shows the time. | ☐ |
| 2.6 | Compare last night's values with the official Google Health app. | Sleep, resting heart rate and steps match, or the differences are written down. | ☐ |
| 2.7 | Tap a card; in Trends switch **Week**/**Month**; tap **Ask the coach**. | Trends opens on that metric; the coach opens with a pre-filled question that is not sent automatically. | ☐ |

## 3. Permissions

| # | Step | Expected | Done |
|---|---|---|---|
| 3.1 | Settings → Workout detection → **Enable workout notifications** → **Allow**. | The iOS prompt appears **only now**. Afterwards, no further prompt. | ☐ |
| 3.2 | Delete and reinstall; this time tap **Don't Allow**. | The app shows that notifications are unavailable or denied; nothing crashes. | ☐ |
| 3.3 | Later enable notifications in iOS Settings → Notifications. | Prompts start arriving as notifications without reinstalling. | ☐ |
| 3.4 | Motion & Fitness: first **Allow**, then repeat with **Don't Allow**. | Allow: detection works. Deny: the app keeps running and retries on the next resume; no crash. | ☐ |
| 3.5 | With notifications denied, leave the app, trigger a start prompt (see 4.2), return. | The existing **Start walk?** sheet still appears on resume. | ☐ |

## 4. Live prompts

Use the **Workout simulator** (Settings → Workout detection) for 4.1–4.5 and 4.7, then repeat with a real walk. The simulator runs at 20× speed and updates every 4 seconds (real sensors every 15 seconds).

| # | Step | Expected | Done |
|---|---|---|---|
| 4.1 | Switch the simulator on, tap **Simulate walk**, stay in the app. | After about 32 s a **Start walk?** sheet appears (lowercase "walk") with a countdown ("Prompt closes in …") and the note "Countdown uses simulator time (20×)." | ☐ |
| 4.2 | Tap **Start Walk** (the button label is capitalised: **Start Walk**, or **Start Run** for a run). | Today's card shows "Walk · mm:ss" counting up, with steps and distance ("1,000 steps · 0.75 km"). | ☐ |
| 4.3 | Tap **Stop moving**, wait for the stop prompt. | A **Stop workout?** sheet appears with "Ends at your last movement in …". **Keep going** continues; **Finish workout** ends. Both **Finish workout** and letting the prompt time out end the workout at the **last movement**, not after the idle wait. A manual **Stop** on the Today card while still moving ends it at the current time. | ☐ |
| 4.4 | After finishing, check the summary and Today. | A summary (type, Auto-detected, duration, steps, distance, calories, pace) and the workout in **Today's workouts** as "HH:MM · NN min · N,NNN steps". Tap **Done** and reopen it from the list. | ☐ |
| 4.5 | Toggle **Auto-start prompts** and **Auto-stop prompts** off, repeat 4.1. | No prompt for the disabled kind; the card says "Auto-start prompts off". | ☐ |
| 4.6 | Real walk with the app open: 10 minutes. | "Looks like you're walking (n min)" appears, then the start sheet. | ☐ |
| 4.7 | Simulator: repeat with **Simulate run** and **Simulate bike**. | Run behaves like walk (button **Start Run**). A bike ride shows no steps, distance or pace: the card and the summary say "Distance isn't measured for bike rides", the summary adds "Calories are estimated from duration and weight.", and Today's workouts lists it as "HH:MM · NN min". | ☐ |

## 5. Notifications while the app is in the background

Notifications must be allowed (3.1). Use the simulator or a real walk, then press Home before the prompt appears.

| # | Step | Expected | Done |
|---|---|---|---|
| 5.1 | Start prompt arrives as a notification. | Title "Start Walk?" (capitalised activity); actions **Start** and **Not now** are visible (long-press or pull down). | ☐ |
| 5.2 | Tap **Start**. | The app opens in front and the workout starts. | ☐ |
| 5.3 | Repeat; tap **Not now**. | The app opens (the action runs in the main app) and no workout starts. | ☐ |
| 5.4 | Repeat; tap the notification body. | Today opens and the existing sheet is shown. | ☐ |
| 5.5 | Stop prompt arrives as a notification. | Title "Stop workout?"; actions **Stop** and **Keep going** are visible; each does what it says. | ☐ |
| 5.6 | Lock the phone and repeat 5.1–5.5 from the lock screen. | The same actions are offered; they open the app after unlock. | ☐ |
| 5.7 | Start moving again while a prompt notification is showing. | The notification is cancelled when the prompt resolves. (iOS may leave an expired banner until you reopen the app; it is cleared on resume.) | ☐ |
| 5.8 | Wait for the prompt timeout, then tap an old action. | The stale action does nothing; it cannot start a workout. | ☐ |
| 5.9 | Force-quit the app after a prompt, then tap its action. | No stale workout starts. | ☐ |

## 6. Real workouts and history suggestions

Carry the phone. For each activity: finish it, wait over a minute, then check. Repeat each with the app (a) open, (b) suspended in the background and (c) force-quit.

| # | Activity | Expected after reopening | Open | Back | Quit |
|---|---|---|---|---|---|
| 6.1 | Walk, at least 10 min | **"Did you walk HH:MM–HH:MM? N steps"** with correct start, end and type. | ☐ | ☐ | ☐ |
| 6.2 | Run, at least 3 min | Run suggestion. | ☐ | ☐ | ☐ |
| 6.3 | Bike ride, at least 5 min | "Did you cycle HH:MM–HH:MM?" with no step count, plus the note "Distance isn't measured for bike rides". | ☐ | ☐ | ☐ |

| # | Step | Expected | Done |
|---|---|---|---|
| 6.4 | While a bout is still going, resume the app several times. | It is **not** offered until it is complete. | ☐ |
| 6.5 | Tap **Save** on a suggestion. | It moves to Today's workouts once, with the right type and steps. | ☐ |
| 6.6 | Leave a suggestion pending, force-quit, reopen; then **Discard** another. | The pending one is still there. A discarded one stays discarded after a restart. | ☐ |
| 6.7 | Reopen again after saving. | No duplicate suggestion for the saved workout. | ☐ |
| 6.8 | Save a workout while signed in with health consent. | The row appears in Supabase `workouts` with source `auto`. | ☐ |
| 6.9 | Switch to another Google account. | Pending suggestions are not shown to the other account. | ☐ |
| 6.10 | A walk with a pause in the middle. | A pause of up to 60 s of sitting stays one walk; 61 s or more, or a change of exercise type, splits it. One unclear (uncertain) reading of up to 2 minutes inside a walk is bridged once; a second such reading, or one longer than 2 minutes, splits it. | ☐ |
| 6.11 | Do a walk that overlaps a workout you already saved. | The overlapping bout is not offered again. | ☐ |
| 6.12 | Motion history older than 24 hours. | Not offered; only the last 24 hours are checked. | ☐ |
| 6.13 | Block pedometer access or use a bout with no step data. | The card says "Steps unavailable" and shows no zero steps, distance or calories; **Save** and **Discard** still work. | ☐ |

## 7. Background refresh reminders

iOS decides when background refresh runs (the earliest request is an hour away), so test it with the debugger first and with real hardware afterwards.

1. Run the app from Xcode, put it in the background, and pause the debugger (⌃⌘Y or the pause button).
2. In the lldb console, simulate a launch:

   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.wearablecompanion.workouts.refresh"]
   ```

   Resume the debugger. To simulate expiry, pause again and run:

   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.wearablecompanion.workouts.refresh"]
   ```

| # | Step | Expected | Done |
|---|---|---|---|
| 7.1 | Complete a real 35-minute walk beforehand, then simulate launch. | A notification "Looks like you walked 35 min — tap to log it". **No permission dialog** appears. | ☐ |
| 7.2 | Tap that notification. | The app opens on the Today review ("Did you walk…?"). | ☐ |
| 7.3 | Two completed, unsaved bouts, then simulate launch. | The plural reminder "2 activities to review" with the real count. | ☐ |
| 7.4 | During an active workout, simulate launch. | No reminder for the activity you are already recording. | ☐ |
| 7.5 | Start a refresh, then save or finish a workout before it returns. | No stale reminder appears. | ☐ |
| 7.6 | Simulate expiration. | The task completes once and is rescheduled; no crash or double reminder. | ☐ |
| 7.7 | After finishing a live workout, and after saving a review, check `workouts.refresh.checked` (UserDefaults). | It advances to the end of the workout. Saving an *older* workout, or completing an in-flight refresh, never moves it backward. | ☐ |
| 7.8 | Start a live workout, suspend or kill the app without finishing, simulate a refresh *after* `through + 15 minutes`. | A later completed bout **does** produce a reminder. Repeat at the exact expiry boundary and at the 24-hour onset cap; a legacy Date-only marker must not suppress reminders. | ☐ |
| 7.9 | Watch the channel and UserDefaults while the live card clock ticks. | Only detector snapshots update the marker and cursor. An identical payload or an older cursor leaves `workoutRevision` unchanged and keeps an existing reminder visible; a real update cancels a stale reminder. | ☐ |
| 7.10 | Without the debugger, with **Background App Refresh** on, then off, over a day. | Best effort only. When it is off, or after force-quit, no reminder is expected. Record what happened. | ☐ |
| 7.11 | Compare Dart and native results for one 90–120 s uncertain record inside a walk, a 121 s gap, repeated uncertain records and a type change. | Both agree on where a bout starts and ends. | ☐ |

## 8. Sign out, delete and the queue

| # | Step | Expected | Done |
|---|---|---|---|
| 8.1 | Go offline (airplane mode), finish and save a workout while signed in with health consent. | It is kept in the pending queue (`workouts.pending.v1.<user id>`) and shown in Today's workouts. | ☐ |
| 8.2 | Go online. | It syncs and appears in Supabase once, with no duplicate. | ☐ |
| 8.3 | Save a workout offline, then **Sign out** (Settings). Sign back in with the same account, online. | Signing out clears that user's pending queue and its corrupt-data backup. The unsynced workout is **gone** and is not uploaded after sign-in. | ☐ |
| 8.4 | Save a workout offline, then tap **Delete health data** and confirm. | On success the user's pending queue is cleared, **even if consent was already off**, and the workout does not reappear later. | ☐ |
| 8.5 | Save a workout offline, then **Delete account** and confirm. | On success the pending queue is cleared before the sign-out; the account and data are removed and you return to the intro. | ☐ |
| 8.6 | Repeat 8.4 and 8.5 with the network off or the server failing, so the delete **fails**. | The error "Could not delete your health data" (or "…finish deleting your account") is shown and the pending queue is **kept**; nothing is lost. Retry succeeds. | ☐ |
| 8.6a | Only if the local clear itself can be made to fail (debug build) after a **successful** server deletion. | The user still sees the normal success result (snackbar, or sign-out for **Delete account**), never "Could not delete…". The failure is only logged; leftover rows are cleared at the next sign-out or consent withdrawal. | ☐ |
| 8.7 | Start the app with health consent already off and a pending workout from an earlier grant. | The queue is not cleared (rows stay paused) and syncs after consent is granted again. Only an actual withdrawal while the app runs clears it. | ☐ |
| 8.8 | A workout saved while signed out or without consent. | It is kept for this app session only and is gone after a restart. | ☐ |
| 8.9 | Queue limits: more than 200 pending rows, or rows older than 30 days. | The oldest are dropped silently (documented behaviour). | ☐ |

## 9. Look and feel

| # | Step | Expected | Done |
|---|---|---|---|
| 9.1 | iOS Settings → Display → **Dark**. Open Today, Trends, Coach and Settings. | All text is readable; icons are visible; range bars and chart bars are distinguishable; no white flashes. Compare with [screenshots/](screenshots/). | ☐ |
| 9.2 | Dark mode: switches. | An off switch has a visible outline against the card. | ☐ |
| 9.3 | Settings → Display → Text Size: drag to the largest, then enable **Larger Accessibility Sizes** at maximum. | No overflow stripes; titles shorten with "…", long lines wrap; every button is still reachable by scrolling. | ☐ |
| 9.4 | Small iPhone (SE class) or Display Zoom. | Today still shows the three cards; nothing is cut off. | ☐ |
| 9.5 | Rotate to landscape (if enabled). | Content scrolls and stays readable. | ☐ |
| 9.6 | VoiceOver on Today. | Each card reads its metric and comparison; the range bar is silent. | ☐ |

## 10. Sign-off

- All boxes in sections 1–3 ticked: ☐ (blocks everything else)
- Sections 4–7 (workouts) ticked or failures listed: ☐
- Sections 8–9 ticked or failures listed: ☐

Failures to fix (step, what happened, device, iOS version):

1. 
2. 
3. 
