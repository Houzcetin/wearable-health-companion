# Workout prompts away from the app

Live detection still needs the Flutter engine and sensor streams to be running.
The feature's `AppLifecycleListener` routes unresolved prompts to local
notifications whenever the app is not resumed, and to the existing sheets when
it resumes. Actions open the main isolate and call the same `WorkoutNotifier`
methods as the sheets. Prompt identifiers reject stale actions. Nothing requests
notification permission at launch: initialization disables all permission flags;
the first background prompt or the settings button requests permission.
Notification body taps select Today without changing the router configuration;
native refresh taps persist an open request until Dart can consume it.

`flutter_local_notifications` is pinned to **21.0.0**, resolved with Flutter
3.50.0 / Dart 3.14.0. Android includes its required desugaring setup, notification
icon, action receiver and `POST_NOTIFICATIONS` permission. No foreground service
or extra preferences dependency is added.

On iPhone, `MotionHistorySource` queries CoreMotion over a method channel
registered through the implicit engine's plugin registrar. History checks run on
cold start and resume, capped at 24 hours. Only high CoreMotion confidence maps to
100; medium maps to 50 and low to 0. Uncertain/unknown/automotive intervals break
continuity. Gaps over the detector's 60-second tolerance and exercise changes
split bouts. Each bout replays ordered motion and interval step totals through a
fresh `AutoWorkoutDetector` using a fake clock and the normal duration thresholds.
Completed bouts become reviews, never automatic saves. Distance continues to use
the app's stride estimate; the native channel also exposes recorded distance.

The channel uses UserDefaults for per-account checkpoints and pending reviews,
so `shared_preferences` is unnecessary. The checkpoint is the last safely
processed boundary: unfinished motion is queried again from its onset rather
than lost on the next resume. Discarded reviews stay discarded across restarts.
Auto-start off clears reviews and skips that period. Detection toggles retain
their existing app-session lifetime. A stale, unconfirmed live candidate is
reset after a suspension gap; history supplies the missing period.

History loads repository workouts before excluding overlaps. Because the
repository's range API filters *start* times, the overlap check loads all earlier
starts, including overnight workouts crossing the query boundary. This may need
a dedicated overlap query if workout history becomes large. Accepted reviews use
`WorkoutRepository.save` with a stable candidate ID and `source: auto`; existing
cache, change stream and retry behavior are unchanged. A repository load failure
or motion error does not advance the history checkpoint.

The native `BGAppRefreshTask` independently checks up to 24 hours of motion and
may post “Looks like you walked 35 min — tap to log it”. Its cursor is separate
from the Dart review cursor, so a reminder never consumes a review. It checks
existing authorization and never requests permission or saves a workout. Native
reminders use the default minimums: walk 10, run 3, bike 5 minutes. They are hints
and can refer to an already saved workout; Dart checks overlaps when opened.
iOS decides when, or whether, to run a refresh. The earliest requested time is an
hour away, and Background App Refresh settings and force quitting affect delivery.
See [Apple's background task guidance](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app).

When iOS suspends Dart it also suspends live timers. Notification cancellation
runs when the prompt resolves/times out while Dart runs, and again on resume;
iOS has no delivered-notification TTL, so an expired live banner may remain in
Notification Center until then. Android also has an OS notification timeout.
Expired/terminated-session actions cannot start a stale workout; after process
termination, iPhone history supplies review suggestions instead.

Android has live notifications only, and desktop/web return empty history. True
Android background detection would need a native activity-recognition delivery
path (such as PendingIntent transitions), a durable detector/session, and an
appropriately declared foreground service for continuous tracking, with the
corresponding runtime permissions and battery/background restrictions handled.

## Real iPhone verification (requires Xcode; not verified in this workspace)

Workspace validation: `flutter test` passed all 210 tests;
`flutter analyze --no-fatal-infos` passed with zero errors/warnings (SDK
deprecation infos remain). The analyzer used
`ANALYZER_STATE_LOCATION_OVERRIDE=/root/.cache/workout-analyzer` because this
workspace cannot write its default cache under `/root/.dartServer`.

1. Build/install the Runner target. Verify the new Swift source is compiled,
   the method channel registers with the implicit engine, `fetch` appears in
   Background Modes, and the permitted refresh identifier matches the code.
2. Fresh install: verify no notification permission prompt at launch. Test the
   settings permission button, allow/deny, and enabling notifications later in
   iOS Settings. Also allow/deny Motion & Fitness and verify retry on resume.
3. With permission granted and a live/simulated candidate, leave the app before
   the start/stop prompt. Verify both notification titles and all four actions,
   body taps opening the existing sheet, movement cancellation, timeouts and
   both detection toggles. Repeat on the lock screen. Check stale actions after
   a timeout and after process termination.
4. Carry the phone for a walk (>=10 min), run (>=3 min), and bike ride (>=5 min),
   finish each, and wait over a minute. Repeat with the app suspended and with
   its process terminated. Reopen and verify onset/end, step totals, type,
   Save/Discard, saved-workout overlap exclusion and the 24-hour cap. Verify an
   ongoing bout isn't offered until completed, including across multiple resumes.
5. Leave a review pending, terminate/reopen, then Save or Discard. Reopen again
   and verify no duplicate. Verify account switching isolates pending reviews,
   and saving signed in with health consent uses source `auto` in Supabase.
6. Using Xcode's BGTaskScheduler debugging support, simulate launch and expiration
   of `com.wearablecompanion.workouts.refresh`. Verify one-time completion,
   rescheduling, no permission dialog, the reminder for a completed bout, and
   tapping it showing the Dart review. Observe best-effort delivery on hardware
   without the debugger, including Background App Refresh disabled.

Android also needs a device build and API 33+ permission/action/body-tap checks;
native platform builds and OS notification delivery were not run here.
