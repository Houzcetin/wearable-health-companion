import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/data/simulated_sources.dart';
import 'package:wearable_companion/features/workouts/data/workout_repository.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/workout_session.dart';
import 'package:wearable_companion/features/workouts/ui/workout_settings_section.dart';
import 'package:wearable_companion/features/workouts/ui/workout_today_card.dart';
import 'package:wearable_companion/features/workouts/workout_provider.dart';

void main() {
  late DateTime now;
  late SimulatedActivitySource activity;
  late SimulatedStepSource steps;
  late ProviderContainer container;
  late WorkoutNotifier notifier;

  Future<void> show(
    WidgetTester tester, {
    bool settings = false,
    WorkoutRepository? repository,
  }) async {
    now = DateTime(2026, 11, 16, 12);
    activity = SimulatedActivitySource(clock: () => now);
    steps = SimulatedStepSource(clock: () => now);
    container = ProviderContainer(
      overrides: [
        workoutClockProvider.overrideWithValue(() => now),
        activitySourceProvider.overrideWithValue(activity),
        stepSourceProvider.overrideWithValue(steps),
        workoutTickIntervalProvider.overrideWithValue(null),
        if (repository != null)
          workoutRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await activity.dispose();
      await steps.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: settings
                  ? const WorkoutSettingsSection()
                  : const WorkoutTodayCard(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    notifier = container.read(workoutProvider.notifier);
    if (settings) {
      await tester.tap(find.text('Workout detection'));
      await tester.pumpAndSettle();
    }
  }

  void advance(Duration duration) {
    now = now.add(duration);
    notifier.tick();
  }

  testWidgets('Today watches fake sources and renders a six minute candidate', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Watching'), findsOneWidget);
    activity.emit(ActivityType.walking);
    advance(const Duration(minutes: 6));
    await tester.pumpAndSettle();
    expect(find.text("Looks like you're walking (6 min)"), findsOneWidget);
    expect(find.text('Start walk?'), findsNothing);
  });

  testWidgets(
    'start alternatives, live metrics, stop, summary and today history',
    (tester) async {
      await show(tester);
      steps.emit(1000);
      activity.emit(ActivityType.walking);
      advance(const Duration(minutes: 10));
      steps.emit(2000);
      await tester.pumpAndSettle();
      expect(find.text('Start walk?'), findsOneWidget);
      expect(find.text('Start Run instead'), findsOneWidget);
      expect(find.text('Prompt closes in 2:00'), findsOneWidget);
      await tester.tap(find.text('Start Run instead'));
      await tester.pumpAndSettle();
      expect(find.text('Run · 10:00'), findsOneWidget);
      expect(find.text('1000 steps · 0.75 km'), findsOneWidget);
      advance(const Duration(minutes: 1));
      steps.emit(2160);
      await tester.pumpAndSettle();
      expect(find.text('Run · 11:00'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Run summary'), findsOneWidget);
      expect(find.text('Auto-detected'), findsOneWidget);
      expect(find.text('Steps: 1160'), findsOneWidget);
      expect(find.text('Distance: 0.87 km'), findsOneWidget);
      expect(find.textContaining('Calories:'), findsOneWidget);
      expect(find.textContaining('Pace:'), findsOneWidget);
      expect(find.text("Today's workouts"), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Run summary'), findsNothing);
      expect(container.read(workoutProvider).summary, isNull);
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.text('Run summary'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('start countdown updates and timeout closes only its sheet', (
    tester,
  ) async {
    await show(tester);
    activity.emit(ActivityType.running);
    advance(const Duration(minutes: 3));
    await tester.pumpAndSettle();
    advance(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('Prompt closes in 1:00'), findsOneWidget);
    advance(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('Start run?'), findsNothing);
    expect(find.text('Watching'), findsOneWidget);
  });

  testWidgets(
    'movement closes stop prompt and timeout displays trimmed summary',
    (tester) async {
      await show(tester);
      activity.emit(ActivityType.running);
      advance(const Duration(minutes: 3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start Run'));
      await tester.pumpAndSettle();
      activity.emit(ActivityType.still);
      advance(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(find.text('Stop workout?'), findsOneWidget);
      activity.emit(ActivityType.running);
      await tester.pumpAndSettle();
      expect(find.text('Stop workout?'), findsNothing);
      advance(const Duration(minutes: 1));
      activity.emit(ActivityType.still);
      final lastMovement = now;
      advance(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      advance(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(find.text('Run summary'), findsOneWidget);
      expect(
        container.read(workoutProvider).todaySessions.single.endedAt,
        lastMovement,
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('settings toggles, weight validation and simulator controls', (
    tester,
  ) async {
    await show(tester, settings: true);
    await tester.tap(find.text('Auto-start prompts'));
    await tester.pumpAndSettle();
    expect(container.read(workoutProvider).autoStart, isFalse);
    await tester.tap(find.text('Auto-stop prompts'));
    await tester.pumpAndSettle();
    expect(container.read(workoutProvider).autoStop, isFalse);
    await tester.enterText(find.byKey(const Key('workout-weight')), 'NaN');
    await tester.pump();
    expect(find.text('Enter a weight from 20 to 400 kg'), findsOneWidget);
    expect(container.read(workoutProvider).weightKg, 70);
    await tester.enterText(find.byKey(const Key('workout-weight')), '82.5');
    await tester.pump();
    expect(container.read(workoutProvider).weightKg, 82.5);
    await tester.ensureVisible(find.text('Workout simulator'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Workout simulator'));
    });
    await tester.pumpAndSettle();
    expect(container.read(workoutProvider).simulator, isTrue);
    expect(find.text('Simulate walk'), findsOneWidget);
    expect(find.text('Simulate run'), findsOneWidget);
    expect(find.text('Stop moving'), findsOneWidget);
    notifier.setAutoStart(true);
    await tester.ensureVisible(find.text('Simulate walk'));
    await tester.tap(find.text('Simulate walk'));
    notifier.tick();
    notifier.tick();
    await tester.pumpAndSettle();
    expect(find.text('Start walk?'), findsOneWidget);
    await tester.tap(find.text('Start Walk'));
    await tester.pumpAndSettle();
    expect(container.read(workoutProvider).session!.steps, 1000);
    final toggle = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Workout simulator'),
    );
    expect(toggle.onChanged, isNull);
    notifier.acceptStop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'today sessions filter by local date and survive source changes',
    (tester) async {
      final repository = InMemoryWorkoutRepository();
      for (final date in [
        DateTime(2026, 11, 15, 12),
        DateTime(2026, 11, 16, 11),
      ]) {
        repository.save(
          WorkoutSession(
            type: ExerciseType.bike,
            startedAt: date,
            measuredAt: date.add(const Duration(minutes: 30)),
            endedAt: date.add(const Duration(minutes: 30)),
            steps: 0,
            source: WorkoutSource.manual,
          ),
        );
      }
      await show(tester, repository: repository);
      notifier.tick();
      expect(container.read(workoutProvider).todaySessions, hasLength(1));
      await tester.runAsync(() => notifier.setSimulator(true));
      expect(container.read(workoutProvider).todaySessions, hasLength(1));
      await tester.runAsync(() => notifier.setSimulator(false));
      expect(container.read(workoutProvider).todaySessions, hasLength(1));
      advance(const Duration(days: 1));
      expect(container.read(workoutProvider).todaySessions, isEmpty);
    },
  );

  testWidgets(
    'default missing plugins leave Today safe and show a simulator hint',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: WorkoutTodayCard())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Watching'), findsOneWidget);
      expect(find.textContaining('simulator in Settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the notifier ticks after 15 seconds and disposes its timer', (
    tester,
  ) async {
    now = DateTime(2026, 11, 16, 12);
    activity = SimulatedActivitySource(clock: () => now);
    steps = SimulatedStepSource(clock: () => now);
    container = ProviderContainer(
      overrides: [
        workoutClockProvider.overrideWithValue(() => now),
        activitySourceProvider.overrideWithValue(activity),
        stepSourceProvider.overrideWithValue(steps),
      ],
    );
    container.read(workoutProvider);
    await tester.pump();
    activity.emit(ActivityType.walking);
    now = now.add(const Duration(minutes: 6));
    await tester.pump(const Duration(seconds: 15));
    expect(container.read(workoutProvider).now, now);
    container.dispose();
    await activity.dispose();
    await steps.dispose();
    await tester.pump(const Duration(seconds: 15));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained inactive tabs do not open duplicate workout prompts', (
    tester,
  ) async {
    await show(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: const [
                  TickerMode(enabled: false, child: WorkoutTodayCard()),
                  TickerMode(enabled: true, child: WorkoutSettingsSection()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    activity.emit(ActivityType.running);
    advance(const Duration(minutes: 3));
    await tester.pumpAndSettle();
    expect(find.text('Start run?', skipOffstage: false), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'settings and card adapt to narrow dark layouts with larger text',
    (tester) async {
      await show(tester, settings: true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
                child: const SizedBox(
                  width: 320,
                  child: SingleChildScrollView(
                    child: Column(
                      children: [WorkoutTodayCard(), WorkoutSettingsSection()],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
