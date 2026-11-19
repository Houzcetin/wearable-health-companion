import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/core/demo/demo_data.dart';
import 'package:wearable_companion/core/demo/demo_mode.dart';
import 'package:wearable_companion/core/demo/demo_overrides.dart';
import 'package:wearable_companion/core/demo/demo_repositories.dart';
import 'package:wearable_companion/features/today/domain/usual.dart';
import 'package:wearable_companion/features/workouts/workout_provider.dart';
import 'dart:io';
import 'package:wearable_companion/data/providers.dart';
import 'package:wearable_companion/main.dart';

/// Demo mode is the same app with sample-data repositories. These tests build
/// the real app with `demoOverrides()` and check that every tab opens full.
void main() {
  Future<void> openDemo(WidgetTester tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: demoOverrides(),
        child: const HealthCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(NavigationBar), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  testWidgets('Today opens full with the demo chip, three cards and workouts', (
    tester,
  ) async {
    await openDemo(tester);
    expect(find.text('Demo data'), findsOneWidget);
    expect(find.textContaining('You slept'), findsOneWidget);
    expect(find.text('Sleep'), findsOneWidget);
    expect(find.text('Heart'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.textContaining('Last synced'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.text("Today's workouts"), findsOneWidget);
    expect(find.textContaining('Did you walk'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Trends shows week and month with days outside the range', (
    tester,
  ) async {
    await openDemo(tester);
    await tab(tester, 'Trends');
    expect(find.text('Demo data'), findsOneWidget);
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(find.textContaining('outside your usual range'), findsOneWidget);
    expect(find.textContaining('This month you averaged'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Coach shows prepared answers and a labelled demo reply', (
    tester,
  ) async {
    await openDemo(tester);
    await tab(tester, 'Coach');
    // The thread opens scrolled to the latest answer.
    expect(find.text('How was my resting heart rate?'), findsOneWidget);
    expect(find.textContaining('This is a demo answer'), findsWidgets);
    expect(find.text('Numbers used'), findsWidgets);
    expect(find.text('Demo data'), findsWidgets);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 1500));
    await tester.pumpAndSettle();
    expect(find.text('Why was my sleep shorter this week?'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('coach-input')), 'Anything new?');
    await tester.pump();
    await tester.tap(find.byKey(const Key('coach-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Demo answer:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings shows the demo account and blocks export and delete', (
    tester,
  ) async {
    await openDemo(tester);
    await tab(tester, 'Settings');
    expect(find.text('Demo user'), findsWidgets);
    expect(find.text('Demo data, not from a device'), findsOneWidget);
    expect(find.text('Demo data'), findsOneWidget);
    await tester.ensureVisible(find.text('Export my data'));
    await tester.pump();
    await tester.tap(find.text('Export my data'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not available in demo mode'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the demo coach answers without any network and is clearly labelled', () async {
    final repository = DemoCoachRepository();
    final reply = await repository.ask('Why?');
    expect(reply.answer, startsWith('Demo answer:'));
    expect(reply.isDemo, isTrue);
    final history = await repository.latestThread('demo-user');
    expect(history.where((m) => !m.isUser).every((m) => m.isDemo), isTrue);
  });

  test('demo rows are relative to today and include days outside the range', () {
    final today = DateTime(2030, 3, 15, 9, 30);
    final rows = demoRows(today);
    expect(rows.length, demoDays + 1);
    expect(rows.last.date, DateTime(2030, 3, 15));
    expect(rows.first.date, DateTime(2030, 3, 15 - demoDays));
    expect(rows.every((r) => r.isDemo && r.sleepMinutes != null), isTrue);
    expect(rows.where((r) => r.sleepMinutes! < 340).length, greaterThan(1));
  });

  testWidgets('demo opens on Today with no workout sheet on top', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(overrides: demoOverrides());
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const HealthCompanionApp(),
    ));
    await tester.pumpAndSettle();
    // Let the workout and history checks finish.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 15));
    }
    await tester.pumpAndSettle();
    final state = container.read(workoutProvider);
    expect(state.summary, isNull);
    expect(state.startPrompt, isNull);
    expect(state.stopPrompt, isNull);
    expect(find.textContaining('summary'), findsNothing);
    expect(find.text('Today'), findsWidgets);
    expect(find.text("Today's workouts"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Sync now in demo says nothing was synced', (tester) async {
    await openDemo(tester);
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    expect(find.text('Demo mode: nothing was synced.'), findsOneWidget);
    expect(find.text('Sync finished.'), findsNothing);
  });

  test('the coach baseline is the same typical the cards use', () async {
    final today = DateTime(2030, 3, 15, 9, 30);
    final typical = calculateUsual(demoRows(today), today).sleep.usual!;
    final history = await DemoCoachRepository().latestThread('demo-user');
    final answer = history.firstWhere((m) => !m.isUser && m.facts.isNotEmpty);
    final compare = (answer.facts['tools'] as List).single as Map;
    final result = compare['result'] as Map;
    final b = result['b'] as Map;
    expect(b['median'], typical);
    expect(result['b'] is Map && b['nights_with_data'] == 28, isTrue);
    final typicalText = '${typical.round() ~/ 60} h '
        '${(typical.round() % 60).toString().padLeft(2, '0')} min';
    expect(answer.content, contains('a typical $typicalText'));
  });

  test('web title and description name the app', () {
    final html = File('web/index.html').readAsStringSync();
    expect(html, contains('<title>Wearable Health Companion</title>'));
    expect(html, isNot(contains('A new Flutter project')));
    final manifest = File('web/manifest.json').readAsStringSync();
    expect(manifest, contains('"name": "Wearable Health Companion"'));
    expect(manifest, isNot(contains('A new Flutter project')));
  });

  test('demo mode is off by default', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(demoModeProvider), isFalse);
    expect(container.read(backendConfiguredProvider), isFalse);
  });
}
