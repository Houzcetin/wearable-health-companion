# Workout prompts away from the app

Signed-in workouts awaiting sync are stored in a separate pending queue for each
account. The queue is capped at 200 rows and 30 days, measured from each workout's
start time. Rows older than 30 days and the oldest rows above the 200-row cap are
silently dropped on queue reads and writes, even if they have never synced. No
warning is shown, and dropped rows will no longer retry.

Live detection still needs the Flutter engine and sensor streams to be running.
The feature's `AppLifecycleListener` routes unresolved prompts to local
notifications whenever the app is not resumed, and to the existing sheets when
it resumes. Actions open the main isolate and call the same `WorkoutNotifier`
methods as the sheets. Prompt identifiers reject stale actions. Nothing requests
notification permission implicitly: initialization disables all permission flags;
only the “Enable workout notifications” settings button requests permission.
The bridge checks current iOS/Android authorization without prompting, retains no
denial cache, and silently skips a notification without affecting the resume sheet.
Notification body taps select Today without changing the router configuration;
native refresh taps persist an open request until Dart can consume it.

`flutter_local_notifications` is pinned to **21.0.0**, resolved with Flutter
3.50.0 / Dart 3.14.0. Android includes its required desugaring setup, notification
icon, action receiver and `POST_NOTIFICATIONS` permission. No foreground service
or extra preferences dependency is added.

On iPhone, `MotionHistorySource` queries CoreMotion over a method channel
registered through the implicit engine's plugin registrar. History checks run on
cold start and resume, capped at 24 hours. Only high CoreMotion confidence maps to
100; medium maps to 50 and low to 0. One medium/low confidence record lasting at
most two minutes is tolerated inside a bout only if the immediately following
record is high confidence and the same exercise type. Both Dart and Swift apply
this rule, retaining an uncertain tail for up to two minutes across checks.
Other gaps over the detector's 60-second tolerance and exercise changes split
bouts. Each bout replays ordered motion through a fresh `AutoWorkoutDetector`
using a fake clock and the normal duration thresholds.
Step totals are queried sequentially only for eligible completed bout boundaries,
up to 48 per check; excess bouts retain their cursor for a later check. Idle,
uncertain, short, unfinished, and already saved/active overlapping bouts need no
pedometer queries.
Completed bouts become reviews, never automatic saves. Distance continues to use
the app's stride estimate; the native channel also exposes recorded distance.
When a walk/run review has zero steps (including an unavailable pedometer), its card says
“Steps unavailable” and shows no step, distance or calorie totals. Save/Discard
remain available. Bike reviews omit steps entirely. Bike live cards and summaries
also omit steps, distance and pace, with “Distance isn't measured for bike rides”.

The channel uses UserDefaults for per-account checkpoints and pending reviews,
so `shared_preferences` is unnecessary. The checkpoint is the last safely
processed boundary: unfinished motion is queried again from its onset rather
than lost on the next resume. Discarded reviews stay discarded across restarts.
Auto-start off clears reviews and skips that period. Detection toggles retain
their existing app-session lifetime. A stale, unconfirmed live candidate is
reset after a suspension gap; history supplies the missing period.

History loads repository workouts before excluding overlaps. Because the
repository's range API filters *start* times and workouts last at most 24 hours,
the overlap check loads from 24 hours before the review window through its end.
Accepted reviews use `WorkoutRepository.save` with a stable candidate ID and
`source: auto`; existing cache, change stream and retry behavior are unchanged.
A repository load failure
or motion error does not advance the history checkpoint. A separate `loadError`
allows review checks to proceed while a cached save awaits a sync retry.

The native `BGAppRefreshTask` independently checks up to 24 hours of motion and
may post “Looks like you walked 35 min — tap to log it”. Its cursor is separate
from the Dart review cursor, so a reminder never consumes a review. It checks
existing authorization and never requests permission or saves a workout. Native
reminders use the default minimums: walk 10, run 3, bike 5 minutes. Multiple
completed bouts produce “2 activities to review” (with the actual count).
Dart saves and live workout snapshots advance `workouts.refresh.checked` to the
maximum of its existing value and the workout end/measurement time. An active
workout marker stores both `from` and `through` and excludes overlapping bouts
even while Dart is suspended. Both Swift and Dart ignore it after the earlier of
`through + 15 minutes` and `from + 24 hours` (the exact boundary is still valid).
Future/malformed snapshots and legacy onset-only native markers are invalid.
The marker clears on finish or a new Dart process. UI clock refreshes retain the
last detector snapshot; they do not renew its expiry or write to the channel.
Detector updates send only changed start/measurement values; `setActiveWorkout`
already advances the native cursor, avoiding a second call for that measurement.
Unchanged/older cursor values and unchanged markers do not write UserDefaults
or invalidate reminders. In-flight reminders are suppressed only when a marker
changes or the cursor advances; refresh never moves the cursor backward.
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

## Simulator and web regression checks

Enable “Workout simulator” in Workout detection, choose “Simulate walk”, “Simulate
run” or “Simulate bike”, accept Start, then choose “Stop moving”. The simulator
uses 20× time with a four-second tick (80 simulated seconds); real sensor mode
keeps its 15-second tick. Walk prompts appear after about 32 real seconds. Both
“Finish workout” on the stop prompt and its timeout end at last movement,
excluding the idle wait. A manual Stop while moving ends at the current time.

The summary uses `WorkoutSession.duration` (`endedAt ?? measuredAt` minus
`startedAt`), cumulative steps since onset, steps × stride for distance and MET ×
weight × duration for calories. Simulator steps are delivered before acceptance
and included in the backdated session; no historical step fetch is needed.
JavaScript's 32-bit integer shifts made the former `1 << 53` step clamp and
`1 << 32` duration-formatting clamp zero, independently wiping steps/distance
and the displayed duration while calories still used the actual duration.
Both now use `math.max(0, value)`. The repository's bounded rows and `recorded*`
values were not involved in the immediate summary, which receives the finished
detector session directly.

Run from `app/`:

```sh
flutter test
CHROME_EXECUTABLE=/opt/pw-browsers/chromium flutter test --platform chrome test/workout_widgets_test.dart test/auto_workout_detector_test.dart
ANALYZER_STATE_LOCATION_OVERRIDE=/root/.cache/workout-analyzer flutter analyze --no-fatal-infos
```

The Chrome command failed six tests before the fix: countdown formatting,
simulator controls and detector step totals. After the fix, all 57 tests in that
command pass. The widget suite now follows the
complete simulator flow through both finish paths for all three exercise types,
checks rendered metrics against the time range, cadence, stride and MET, and
reopens saved summaries. `web_int_safety_test.dart` scans all Dart sources in
`lib/` to prevent shifts of 32 or more and shifted zero-based clamp bounds.
The notification timeout's `1 << 31` remains unchanged.

## Shared motion history golden

[`test/fixtures/workout_motion_history.json`](../../../test/fixtures/workout_motion_history.json)
is read by `workout_motion_history_golden_test.dart` and RunnerTests'
`testMotionHistoryGolden`. Xcode copies this same file into the RunnerTests
bundle; there is no separate Swift fixture. Both tests check exact bout types,
onsets, ends and the retained cursor. Swift tests call the pure replay helper
used by the background refresh itself.

Fixture times and the table's intervals are seconds from the window origin.
Confidence uses CoreMotion's raw values: high 2, medium 1, low 0. `to` is 3600
unless the case names a tail boundary. The retained cursor is `to` for completed
cases; open tails retain their onset.

| Fixture case | Input/rule | Expected completed bouts; cursor |
| --- | --- | --- |
| `completed_walk` | Walk then still | Walk 0–2100; `to` |
| `walk_below_minimum` | 599 s walk | None; `to` |
| `walk_at_minimum` | 600 s walk | Walk 0–600; `to` |
| `run_below_minimum` | 179 s run | None; `to` |
| `run_at_minimum` | 180 s run | Run 0–180; `to` |
| `bike_below_minimum` | 299 s bike | None; `to` |
| `bike_at_minimum` | 300 s bike | Bike 0–300; `to` |
| `still_gap_60` | Still 720–780 | Walk 0–2100; `to` |
| `still_gap_61` | Still 720–781 | Walks 0–720, 781–2100; `to` |
| `medium_gap_90` | One medium record 300–390 | Walk 0–2100; `to` |
| `medium_gap_120` | One medium record 300–420 | Walk 0–2100; `to` |
| `low_gap_120` | One low record 300–420 | Walk 0–2100; `to` |
| `uncertain_gap_121` | Medium record 720–841 | Walks 0–720, 841–2100; `to` |
| `repeated_uncertain_gaps` | Two 90 s uncertain gaps | Walks 0–1200, 1290–2400; `to` |
| `consecutive_uncertain_records` | Medium then low, spanning 720–840 | Walks 0–720, 840–2100; `to` |
| `uncertain_then_different_type` | Walk, medium, then run at 810 | Walk 0–720, run 810–1200; `to` |
| `exercise_change` | Walk then run at 900 | Walk 0–900, run 900–1200; `to` |
| `uncertain_tail_120` | Uncertainty at 720; `to` 840 | None; 0 |
| `uncertain_tail_121` | Uncertainty at 720; `to` 841 | Walk 0–720; 841 |
| `still_tail_60` | Still at 720; `to` 780 | None; 0 |
| `still_tail_61` | Still at 720; `to` 781 | Walk 0–720; 781 |
| `ongoing_tail` | Walk from 300 without an end | None; 300 |
| `medium_only` | No high-confidence walk | None; `to` |
| `low_only` | No high-confidence run | None; `to` |
| `unsorted_pre_window` | Unsorted records; onset before window | Walk 0–2100; `to` |
| `future_record_ignored` | Walk ends after query window | None; 0 |
| `automotive_is_not_exercise` | High-confidence automotive | None; `to` |

## Real iPhone verification (requires Xcode; not verified in this workspace)

Workspace validation: `flutter test` passed 338 tests (12 screenshot tests skipped);
`flutter analyze --no-fatal-infos` passed with zero errors/warnings (SDK
deprecation infos remain: 30). The analyzer used
`ANALYZER_STATE_LOCATION_OVERRIDE=/root/.cache/workout-analyzer` because this
workspace cannot write its default cache under `/root/.dartServer`.

1. Build/install the Runner target. Verify the new Swift source is compiled,
   the method channel registers with the implicit engine, `fetch` appears in
   Background Modes, and the permitted refresh identifier matches the code.
2. Fresh install: verify no notification permission prompt at launch or from a
   background start/stop prompt. A denied prompt must still show its sheet on
   resume. Test the settings permission button, allow/deny, and enabling
   notifications later in iOS Settings. Also allow/deny Motion & Fitness and
   verify retry on resume.
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
7. Inspect `workouts.refresh.checked` after saving a review and finishing a live
   workout. Saving an older workout or completing an in-flight refresh must not
   move it backward. During an active workout, simulate refresh and verify no
   overlapping reminder. Start a refresh, then save/finish before it returns;
   verify no stale reminder. Two completed, unsaved bouts must use the plural
   reminder. Compare Dart and native results for one 90/120-second medium/low
   record inside a walk, a 121-second gap, repeated uncertain records and a change
   of exercise type.
8. Run the RunnerTests target, including the shared golden, active-marker expiry
   and revision tests. Confirm its JSON resource resolves from the test bundle.
   Start a live workout, suspend/terminate without finishing, then simulate a
   refresh after `through + 15 minutes`: a later completed bout must produce a
   reminder. Repeat at the exact expiry boundary and at the 24-hour onset cap;
   a legacy Date-only marker must not suppress reminders.
9. Observe the method channel and UserDefaults while the live card clock ticks:
   only detector snapshots should update the marker/cursor. Repeated identical
   payloads or an older cursor must leave `workoutRevision` unchanged and keep an
   existing review reminder visible; a real update must cancel a stale reminder.
   With no pedometer data, confirm the candidate says “Steps unavailable” without
   zero steps, distance or calories, and Save/Discard still work.

Android also needs a device build and API 33+ permission/action/body-tap checks;
native platform builds and OS notification delivery were not run here.
