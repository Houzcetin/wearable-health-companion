import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/core/demo/demo_overrides.dart';
import 'package:wearable_companion/features/workouts/data/simulated_sources.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/workout_provider.dart';
import 'package:wearable_companion/main.dart';

/// Tapping the selected tab must not re-open a workout summary, and the
/// summary of a workout that was finished and closed must never come back.
void main() {
  late DateTime now;
  late SimulatedActivitySource activity;
  late SimulatedStepSource steps;

  Future<ProviderContainer> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    now = DateTime(2026, 11, 19, 12);
    activity = SimulatedActivitySource(clock: () => now);
    steps = SimulatedStepSource(clock: () => now);
    addTearDown(() async {
      await activity.dispose();
      await steps.dispose();
    });
    final container = ProviderContainer(overrides: [
      ...demoOverrides(),
      workoutClockProvider.overrideWithValue(() => now),
      activitySourceProvider.overrideWithValue(activity),
      stepSourceProvider.overrideWithValue(steps),
      workoutTickIntervalProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const HealthCompanionApp(),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(NavigationBar), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  void advance(WorkoutNotifier notifier, Duration duration) {
    now = now.add(duration);
    notifier.tick();
  }

  testWidgets('demo: re-tapping Today twice shows no summary sheet', (tester) async {
    await openApp(tester);
    for (var i = 0; i < 2; i++) {
      await tapTab(tester, 'Today');
    }
    expect(find.textContaining(' summary'), findsNothing);
    expect(find.text('Done'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a finished workout is summarised once, then never again', (
    tester,
  ) async {
    final container = await openApp(tester);
    final notifier = container.read(workoutProvider.notifier);
    // Walk for 10 minutes: a start prompt, accepted.
    activity.emit(ActivityType.walking);
    advance(notifier, const Duration(minutes: 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Walk'));
    await tester.pumpAndSettle();
    // Stop for 5 minutes: a stop prompt, then finish.
    activity.emit(ActivityType.still);
    advance(notifier, const Duration(minutes: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish workout'));
    await tester.pumpAndSettle();
    expect(find.text('Walk summary'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Walk summary'), findsNothing);
    expect(container.read(workoutProvider).summary, isNull);

    // Re-tapping the selected tab, and leaving and returning, show nothing.
    await tapTab(tester, 'Today');
    await tapTab(tester, 'Today');
    await tapTab(tester, 'Trends');
    await tapTab(tester, 'Today');
    expect(find.text('Walk summary'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('re-tapping Today while the summary is open does not reset it', (
    tester,
  ) async {
    final container = await openApp(tester);
    final notifier = container.read(workoutProvider.notifier);
    activity.emit(ActivityType.walking);
    advance(notifier, const Duration(minutes: 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Walk'));
    await tester.pumpAndSettle();
    activity.emit(ActivityType.still);
    advance(notifier, const Duration(minutes: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish workout'));
    await tester.pumpAndSettle();
    expect(find.text('Walk summary'), findsOneWidget);
    final done = tester.element(find.text('Done'));

    // The navigation bar is not covered by the sheet, so this tap reaches it.
    await tapTab(tester, 'Today');
    expect(done.mounted, isTrue, reason: 'the open sheet must not be rebuilt');
    expect(find.text('Walk summary'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tapTab(tester, 'Today');
    expect(find.text('Walk summary'), findsNothing);
    expect(container.read(workoutProvider).summary, isNull);
    expect(tester.takeException(), isNull);
  });
}
