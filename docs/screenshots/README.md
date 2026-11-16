# Screenshots

Light and dark renders of the main screens, 390×844 logical px at 2× (780×1688).
They come from a widget test with fake repositories, so no device, backend or
network is needed.

| Screen | Files |
| --- | --- |
| Today (steady and changed metrics, a workout logged today) | `today_{light,dark}.png`, `today_{light,dark}_2.png` (scrolled) |
| Today with a "Did you walk…" history review card | `today_candidate_{light,dark}.png` |
| Today while learning (4 of 7 days) | `today_learning_{light,dark}.png` |
| Trends: sleep, month, nights outside the usual range | `trends_{light,dark}.png`, `trends_{light,dark}_2.png` (scrolled) |
| Coach with history and an open "Numbers used" panel | `coach_{light,dark}.png` |
| Settings, top and with Workout detection expanded | `settings_{light,dark}.png`, `settings_{light,dark}_workout.png` |

## Regenerate

From `app/`:

```sh
SCREENSHOTS=1 flutter test --tags screenshots test/screenshots
```

A plain `flutter test` skips these tests. The PNGs are written to this folder.

The test loads Roboto and Material Icons from the Flutter SDK
(`bin/cache/artifacts/material_fonts`) and CupertinoIcons from the pub cache,
so text and icons render with real glyphs instead of boxes. If the SDK is not
found automatically, set `FLUTTER_ROOT`. Fixtures live in
`app/test/screenshots/screenshots_test.dart`; edit them to change what is shown.

## Notes

- Workout durations differ on purpose: a running workout shows a stopwatch
  (`10:00`, mm:ss), a finished one in Today's workouts shows a length
  (`30 min`, or `1 h 05 min` from an hour up).
