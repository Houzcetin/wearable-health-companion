import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/core/router.dart';
import 'package:wearable_companion/data/daily_metrics.dart';
import 'package:wearable_companion/features/coach/coach_screen.dart';
import 'package:wearable_companion/features/trends/trends_screen.dart';
import 'package:wearable_companion/features/trends/domain/trends.dart';

import 'support/fake_repositories.dart';
import 'support/stage5_harness.dart';

List<DailyMetrics> trendRows({bool demo = false}) => [
  for (var i = 0; i < 31; i++)
    DailyMetrics(
      date: testToday.subtract(Duration(days: i)),
      sleepMinutes: i < 7 ? 420 : 450,
      restingHr: 60, steps: i == 3 ? 0 : 8000, isDemo: demo,
    ),
];

void main() {
  testWidgets('week summary uses a mean and the existing 28-day median', (tester) async {
    await startStage5(tester, screen: const TrendsScreen(),
      health: FakeHealthRepository(rows: trendRows()));
    expect(find.text('This week you averaged 7 h 00 min of sleep, '
      '30 min below typical.'), findsOneWidget);
    final chart = tester.widget<BarChart>(find.byType(BarChart));
    expect(chart.data.extraLinesData.horizontalLines.single.y, 7.5);
    expect(chart.data.extraLinesData.horizontalLines.single.dashArray, [6, 4]);
    expect(chart.data.barGroups.length, 7);
  });

  testWidgets('missing day has an empty slot, marker and accessible value', (tester) async {
    final semantics = tester.ensureSemantics();
    final rows = trendRows()
      ..[2] = DailyMetrics(date: testToday.subtract(const Duration(days: 2)));
    await startStage5(tester, screen: const TrendsScreen(),
      health: FakeHealthRepository(rows: rows));
    expect(find.byKey(const ValueKey('missing-2026-11-10')), findsOneWidget);
    final chart = tester.widget<BarChart>(find.byType(BarChart));
    expect(chart.data.barGroups[4].barRods, isEmpty);
    expect(find.textContaining('1 day missing.'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Nov 10, 2026: no data')), findsOneWidget);
    expect(find.text('Still learning your usual'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('Month switches to 30 dates and fetches the inclusive period', (tester) async {
    final health = FakeHealthRepository(rows: trendRows());
    await startStage5(tester, screen: const TrendsScreen(), health: health);
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This month you averaged'), findsOneWidget);
    expect(tester.widget<BarChart>(find.byType(BarChart)).data.barGroups.length, 30);
    expect(health.rangeStart, civilDate(testToday).subtract(const Duration(days: 29)));
    expect(health.rangeEnd, civilDate(testToday));
  });

  testWidgets('real zero steps is a bar, not a missing day', (tester) async {
    await startStage5(tester, screen: const TrendsScreen(initialMetric: 'steps'),
      health: FakeHealthRepository(rows: trendRows()));
    final chart = tester.widget<BarChart>(find.byType(BarChart));
    expect(chart.data.barGroups[3].barRods.single.toY, 0);
    expect(find.byKey(const ValueKey('missing-2026-11-09')), findsNothing);
  });

  testWidgets('demo rows show the Demo data chip without a connection', (tester) async {
    await startStage5(tester, screen: const TrendsScreen(),
      health: FakeHealthRepository(connection: null, rows: trendRows(demo: true)));
    expect(find.widgetWithText(Chip, 'Demo data'), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
  });

  testWidgets('without health consent there is no range or connection fetch', (tester) async {
    final health = FakeHealthRepository(rows: trendRows(demo: true));
    await startStage5(tester, screen: const TrendsScreen(),
      health: health, profile: FakeProfileRepository(consented: false));
    expect(health.rangeFetches, 0);
    expect(health.connections, 0);
    expect(find.text('Connect Google Health to see your daily summary.'), findsOneWidget);
    expect(find.byType(BarChart), findsNothing);
  });

  testWidgets('unconnected real rows show the connect prompt', (tester) async {
    await startStage5(tester, screen: const TrendsScreen(),
      health: FakeHealthRepository(connection: null, rows: trendRows()));
    expect(find.text('Connect Google Health to see your daily summary.'), findsOneWidget);
    expect(find.byType(BarChart), findsNothing);
  });

  testWidgets('range error can be retried', (tester) async {
    final health = FakeHealthRepository(rows: trendRows())..fetchError = Exception('offline');
    await startStage5(tester, screen: const TrendsScreen(), health: health);
    expect(find.text('Could not load your trends. Please try again.'), findsOneWidget);
    health.fetchError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(BarChart), findsOneWidget);
  });

  for (final month in [false, true]) {
    testWidgets('Ask the coach passes the ${month ? 'month' : 'week'} question through the shell',
      (tester) async {
        final coach = FakeCoachRepository();
        final container = await startStage5(tester, coach: coach,
          health: FakeHealthRepository(rows: trendRows()));
        final router = container.read(routerProvider);
        router.go('/trends');
        await tester.pumpAndSettle();
        if (month) {
          await tester.tap(find.text('Month'));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(find.text('Ask the coach'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ask the coach'));
        await tester.pumpAndSettle();
        final question = month
          ? 'How did this month compare with the month before?'
          : 'Why was this week different from my usual?';
        expect(router.routeInformationProvider.value.uri.path, '/coach');
        expect(router.routeInformationProvider.value.uri.queryParameters['q'], question);
        expect(find.byType(CoachScreen), findsOneWidget);
        expect(tester.widget<TextField>(find.byKey(const Key('coach-input'))).controller!.text,
          question);
        expect(coach.asks, 0);
      });
  }

  testWidgets('reopening the same Today metric resets Trends to Week', (tester) async {
    final container = await startStage5(tester);
    final router = container.read(routerProvider);
    await tester.tap(find.text('Sleep'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    router.go('/today');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sleep'));
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentedButton<TrendRange>>(
      find.byType(SegmentedButton<TrendRange>)).selected, {TrendRange.week});
  });

  testWidgets('the same Trends question prefills again after editing a draft', (tester) async {
    final coach = FakeCoachRepository();
    final container = await startStage5(tester, coach: coach);
    final router = container.read(routerProvider);
    router.go('/trends');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Ask the coach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask the coach'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('coach-input')), 'An unfinished draft');
    router.go('/trends');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Ask the coach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask the coach'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('coach-input'))).controller!.text,
      'Why was this week different from my usual?');
    expect(coach.asks, 0);
  });
}
