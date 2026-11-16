@Tags(['screenshots'])
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wearable_companion/core/theme.dart';
import 'package:wearable_companion/data/coach_repository.dart';
import 'package:wearable_companion/data/daily_metrics.dart';
import 'package:wearable_companion/data/providers.dart';
import 'package:wearable_companion/features/coach/coach_screen.dart';
import 'package:wearable_companion/features/settings/settings_screen.dart';
import 'package:wearable_companion/features/today/today_screen.dart';
import 'package:wearable_companion/features/trends/trends_screen.dart';
import 'package:wearable_companion/features/workouts/data/simulated_sources.dart';
import 'package:wearable_companion/features/workouts/data/workout_repository.dart';
import 'package:wearable_companion/features/workouts/workout_provider.dart';

import '../support/fake_repositories.dart';
import '../support/workout_fakes.dart';

/// Renders the main screens in light and dark mode at 390×844 @2x with real
/// fonts and writes PNGs to docs/screenshots. See docs/screenshots/README.md.
/// A plain `flutter test` skips it; run with `SCREENSHOTS=1`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
  final outDir = Directory('../docs/screenshots')..createSync(recursive: true);

  Future<void> loadFont(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final bytes = File(path).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  setUpAll(() async {
    final fonts = '$flutterRoot/bin/cache/artifacts/material_fonts';
    await loadFont('Roboto', [
      for (final weight in ['Light', 'Regular', 'Medium', 'Bold', 'Black'])
        '$fonts/Roboto-$weight.ttf',
    ]);
    await loadFont('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
    final cupertino = Directory(
      '${Platform.environment['HOME'] ?? '/root'}/.pub-cache/hosted/pub.dev',
    ).listSync().whereType<Directory>().where(
      (d) => d.path.contains('cupertino_icons-'),
    );
    if (cupertino.isNotEmpty) {
      await loadFont('packages/cupertino_icons/CupertinoIcons', [
        '${cupertino.first.path}/assets/CupertinoIcons.ttf',
      ]);
    }
  });

  final clock = DateTime(2026, 11, 12, 12);
  final boundaryKey = GlobalKey();

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen,
    Brightness brightness, {
    FakeHealthRepository? health,
    FakeCoachRepository? coach,
    List<DateTime> workoutStarts = const [],
  }) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = FakeAuthRepository();
    addTearDown(auth.close);
    final activity = SimulatedActivitySource(clock: () => clock);
    final steps = SimulatedStepSource(clock: () => clock);
    final repository = InMemoryWorkoutRepository();
    for (final start in workoutStarts) {
      await repository.save(finishedWorkout(start: start, steps: 4200));
    }
    final container = ProviderContainer(overrides: [
      backendConfiguredProvider.overrideWithValue(true),
      authRepositoryProvider.overrideWithValue(auth),
      profileRepositoryProvider.overrideWithValue(
        FakeProfileRepository(coachConsented: true)),
      healthRepositoryProvider.overrideWithValue(
        health ?? FakeHealthRepository(rows: history(nights: 28))),
      coachRepositoryProvider.overrideWithValue(coach ?? FakeCoachRepository()),
      todayDateProvider.overrideWithValue(testToday),
      exportShareProvider.overrideWithValue((ShareParams _) async {}),
      workoutClockProvider.overrideWithValue(() => clock),
      activitySourceProvider.overrideWithValue(activity),
      stepSourceProvider.overrideWithValue(steps),
      workoutTickIntervalProvider.overrideWithValue(null),
      workoutRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(() async {
      container.dispose();
      await activity.dispose();
      await steps.dispose();
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(brightness),
          home: screen,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${outDir.path}/$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> scrollDown(WidgetTester tester, [double dy = 600]) async {
    await tester.drag(find.byType(Scrollable).first, Offset(0, -dy));
    await tester.pumpAndSettle();
  }

  // 28 nights of varied data, then a changed day (heart rate high, steps low).
  List<DailyMetrics> richHistory() => [
    for (var i = 1; i <= 60; i++)
      DailyMetrics(
        date: testToday.subtract(Duration(days: i)),
        sleepMinutes: i == 3 ? 300 : i == 9 ? 560 : i == 17 ? 330 :
          i == 24 ? 540 : 420 + (i * 37) % 70,
        restingHr: 58 + (i * 3) % 5,
        steps: 6500 + (i * 911) % 4500,
        hrvMs: 40.0 + i % 9,
        activeZoneMin: 10 + i % 25,
      ),
    DailyMetrics(
      date: testToday,
      sleepMinutes: 445,
      restingHr: 66,
      steps: 9800,
      hrvMs: 38,
      activeZoneMin: 31,
    ),
  ];

  final shots = {
    'today': (WidgetTester tester, Brightness b, String suffix) async {
      await pumpScreen(tester, const TodayScreen(), b,
        health: FakeHealthRepository(rows: richHistory()),
        workoutStarts: [DateTime(2026, 11, 12, 7, 30)]);
      await shoot(tester, 'today_$suffix');
      await scrollDown(tester);
      await shoot(tester, 'today_${suffix}_2');
    },
    'today_learning': (WidgetTester tester, Brightness b, String suffix) async {
      await pumpScreen(tester, const TodayScreen(), b,
        health: FakeHealthRepository(rows: history(nights: 4)));
      await shoot(tester, 'today_learning_$suffix');
    },
    'trends': (WidgetTester tester, Brightness b, String suffix) async {
      await pumpScreen(tester, const TrendsScreen(), b,
        health: FakeHealthRepository(rows: richHistory()));
      await tester.tap(find.text('Month'));
      await tester.pumpAndSettle();
      await shoot(tester, 'trends_$suffix');
      await scrollDown(tester);
      await shoot(tester, 'trends_${suffix}_2');
    },
    'coach': (WidgetTester tester, Brightness b, String suffix) async {
      final coach = FakeCoachRepository()
        ..messages = const [
          CoachMessage(threadId: 't', role: 'user',
            content: 'Why was my sleep shorter this week?'),
          CoachMessage(threadId: 't', role: 'assistant',
            content: 'You averaged 6 h 52 min this week against 7 h 20 min '
              'over the month before. November 9 was the shortest night at '
              '5 h 00 min, and November 5 was close behind.',
            facts: {'tools': [{
              'name': 'compare_periods',
              'input': {
                'metric': 'sleep_minutes',
                'period_a_start': '2026-11-06', 'period_a_end': '2026-11-12',
                'period_b_start': '2026-10-09', 'period_b_end': '2026-11-05',
              },
              'result': {
                'a': {'days_with_data': 7, 'mean': 412, 'median': 415},
                'b': {'days_with_data': 28, 'mean': 440, 'median': 442},
                'contributors': [
                  {'date': '2026-11-09', 'value': 300},
                  {'date': '2026-11-05', 'value': 330},
                ],
              },
            }]}),
        ];
      coach.reply = const CoachReply(
        threadId: 't',
        answer: 'Your resting heart rate was 66 bpm on November 12, which is '
          '6 bpm above your typical 60 bpm. That is the highest of the last '
          'two weeks.',
        facts: {'tools': [{
          'name': 'get_daily_metrics',
          'input': {'start_date': '2026-10-30', 'end_date': '2026-11-12'},
          'result': {'days': [{'date': '2026-11-12', 'resting_hr': 66}]},
        }]},
      );
      await pumpScreen(tester, const CoachScreen(), b, coach: coach);
      await tester.enterText(find.byKey(const Key('coach-input')),
        'How was my resting heart rate?');
      await tester.pump();
      await tester.tap(find.byKey(const Key('coach-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Numbers used').last);
      await tester.pumpAndSettle();
      await shoot(tester, 'coach_$suffix');
    },
    'settings': (WidgetTester tester, Brightness b, String suffix) async {
      await pumpScreen(tester, const SettingsScreen(), b);
      await shoot(tester, 'settings_$suffix');
      await tester.ensureVisible(find.text('Workout detection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workout detection'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Auto-stop prompts'));
      await tester.pumpAndSettle();
      await shoot(tester, 'settings_${suffix}_workout');
    },
  };

  for (final entry in shots.entries) {
    for (final (brightness, suffix) in [
      (Brightness.light, 'light'),
      (Brightness.dark, 'dark'),
    ]) {
      testWidgets(
        '${entry.key} $suffix',
        (tester) async => entry.value(tester, brightness, suffix),
        skip: !Platform.environment.containsKey('SCREENSHOTS'),
      );
    }
  }
}
