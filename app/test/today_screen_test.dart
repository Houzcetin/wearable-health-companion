import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wearable_companion/core/theme.dart';
import 'package:wearable_companion/core/router.dart';
import 'package:wearable_companion/features/trends/domain/trends.dart';
import 'package:wearable_companion/data/daily_metrics.dart';
import 'package:wearable_companion/data/health_repository.dart';
import 'package:wearable_companion/data/providers.dart';
import 'package:wearable_companion/features/today/today_screen.dart';

import 'support/fake_repositories.dart';
import 'support/stage5_harness.dart';

void main() {
  Future<void> showToday(
    WidgetTester tester,
    FakeHealthRepository health,
  ) async {
    final auth = FakeAuthRepository();
    addTearDown(auth.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendConfiguredProvider.overrideWithValue(true),
          authRepositoryProvider.overrideWithValue(auth),
          profileRepositoryProvider.overrideWithValue(FakeProfileRepository()),
          healthRepositoryProvider.overrideWithValue(health),
          todayDateProvider.overrideWithValue(testToday),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const TodayScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('changed sleep insight, three values and secondary metrics', (
    tester,
  ) async {
    await showToday(tester, FakeHealthRepository(rows: history()));
    expect(find.text('You slept 52 min less than typical.'), findsOneWidget);
    expect(find.text('6 h 38 min'), findsOneWidget);
    expect(find.text('64 bpm'), findsOneWidget);
    expect(find.text('9,000 steps'), findsOneWidget);
    expect(find.textContaining('HRV 42 ms'), findsOneWidget);
    expect(find.text('24 active zone min'), findsOneWidget);
    expect(find.text('Demo data'), findsNothing);
    expect(find.text('Last synced: never'), findsOneWidget);
  });
  testWidgets('learning state counts non-null nights', (tester) async {
    await showToday(tester, FakeHealthRepository(rows: history(nights: 5)));
    expect(
      find.text('Still learning your usual range (5 of 7 nights).'),
      findsOneWidget,
    );
    expect(find.text('6 h 38 min'), findsOneWidget);
  });
  testWidgets('not connected offers connect action', (tester) async {
    final health = FakeHealthRepository(connection: null);
    await showToday(tester, health);
    expect(
      find.widgetWithText(FilledButton, 'Connect Google Health'),
      findsOneWidget,
    );
    // Rows are still fetched so demo data can show before a device exists.
    expect(health.fetches, 1);
  });
  testWidgets('connection action navigates to connect', (tester) async {
    final auth = FakeAuthRepository();
    addTearDown(auth.close);
    final router = GoRouter(
      initialLocation: '/today',
      routes: [
        GoRoute(path: '/today', builder: (_, _) => const TodayScreen()),
        GoRoute(
          path: '/connect',
          builder: (_, _) => const Scaffold(body: Text('Connection page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendConfiguredProvider.overrideWithValue(true),
          authRepositoryProvider.overrideWithValue(auth),
          profileRepositoryProvider.overrideWithValue(FakeProfileRepository()),
          healthRepositoryProvider.overrideWithValue(
            FakeHealthRepository(connection: null),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Connect Google Health'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connection page'), findsOneWidget);
  });
  testWidgets('demo chip includes demo history used by usual', (tester) async {
    final rows = history()
      ..[0] = DailyMetrics(
        date: testToday.subtract(const Duration(days: 1)),
        sleepMinutes: 450,
        restingHr: 60,
        steps: 8000,
        isDemo: true,
      );
    await showToday(tester, FakeHealthRepository(rows: rows));
    expect(find.widgetWithText(Chip, 'Demo data'), findsOneWidget);
  });
  testWidgets('half-unit differences from an even-length median are rounded', (
    tester,
  ) async {
    final rows = [
      for (var i = 1; i <= 8; i++)
        DailyMetrics(
          date: testToday.subtract(Duration(days: i)),
          sleepMinutes: i.isEven ? 450 : 451,
          restingHr: 60,
          steps: i.isEven ? 8000 : 8001,
        ),
      DailyMetrics(
        date: testToday,
        sleepMinutes: 398,
        restingHr: 60,
        steps: 9000,
      ),
    ];
    await showToday(tester, FakeHealthRepository(rows: rows));
    expect(find.text('You slept 53 min less than typical.'), findsOneWidget);
    expect(find.text('Above your usual range (+1,000 steps)'), findsOneWidget);
    expect(find.textContaining('.5'), findsNothing);
  });

  // Sleep spread wide enough that the usual range (412–488 min) is wider
  // than typical ± 15 min; heart rate and steps are flat.
  List<DailyMetrics> spread({
    required int sleepToday,
    double heartToday = 60,
    int stepsToday = 8000,
  }) => [
    for (final (i, sleep) in [400, 420, 440, 460, 480, 500, 450].indexed)
      DailyMetrics(
        date: testToday.subtract(Duration(days: i + 1)),
        sleepMinutes: sleep,
        restingHr: 60,
        steps: 8000,
      ),
    DailyMetrics(
      date: testToday,
      sleepMinutes: sleepToday,
      restingHr: heartToday,
      steps: stepsToday,
    ),
  ];
  testWidgets('steady but off typical: in range, with the gap and no arrow', (
    tester,
  ) async {
    await showToday(
      tester,
      FakeHealthRepository(rows: spread(sleepToday: 425)),
    );
    expect(
      find.text('Your sleep was within your usual range.'),
      findsOneWidget,
    );
    expect(
      find.text('In your usual range (25 min under typical)'),
      findsOneWidget,
    );
    expect(find.text('In your usual range'), findsNWidgets(2));
    expect(
      find.text('Heart rate and steps are within your usual range.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.arrow_downward), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
  });
  testWidgets('changed: outside the range with signed gap and arrow', (
    tester,
  ) async {
    await showToday(tester, FakeHealthRepository(rows: history()));
    expect(find.text('Below your usual range (−52 min)'), findsOneWidget);
    expect(find.text('Above your usual range (+4 bpm)'), findsOneWidget);
    expect(find.text('Above your usual range (+1,000 steps)'), findsOneWidget);
    expect(
      find.text('Heart rate and steps also differ from usual.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsNWidgets(2));
  });
  testWidgets('others line drops "also" when sleep is steady', (tester) async {
    await showToday(
      tester,
      FakeHealthRepository(
        rows: spread(sleepToday: 450, heartToday: 64, stepsToday: 9000),
      ),
    );
    expect(
      find.text('Your sleep was within your usual range.'),
      findsOneWidget,
    );
    expect(
      find.text('Heart rate and steps differ from usual.'),
      findsOneWidget,
    );
    expect(find.textContaining('also'), findsNothing);
  });
  testWidgets('small screen with large text does not overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    // Today is a ListView: off-screen cards are only laid out once scrolled
    // to, so scroll to the end and check for overflow at every step.
    Future<void> scrollThrough() async {
      expect(tester.takeException(), isNull);
      final list = find.byType(Scrollable).first;
      ScrollPosition position() =>
          tester.state<ScrollableState>(list).position;
      expect(position().maxScrollExtent, greaterThan(0));
      while (position().pixels < position().maxScrollExtent) {
        await tester.drag(list, const Offset(0, -150));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(find.text('Last synced: never'), findsOneWidget);
    }

    await showToday(
      tester,
      FakeHealthRepository(rows: spread(sleepToday: 425, stepsToday: 12345)),
    );
    await scrollThrough();
    await showToday(tester, FakeHealthRepository(rows: history()));
    await scrollThrough();
  });

  testWidgets('demo data shows before Google Health is connected', (
    tester,
  ) async {
    final health = FakeHealthRepository(rows: history(demo: true))
      ..connection = null;
    await showToday(tester, health);
    expect(find.text('Demo data'), findsOneWidget);
    expect(find.text('Sample data, not from your device.'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
  });

  testWidgets('real rows without a connection still ask to connect', (
    tester,
  ) async {
    final health = FakeHealthRepository(rows: history())..connection = null;
    await showToday(tester, health);
    expect(
      find.text('Connect Google Health to see your daily summary.'),
      findsOneWidget,
    );
  });

  testWidgets('demo today shows chip', (tester) async {
    await showToday(tester, FakeHealthRepository(rows: history(demo: true)));
    expect(find.text('Demo data'), findsOneWidget);
  });
  testWidgets('revoked connection shows reconnect and hides old metrics', (
    tester,
  ) async {
    await showToday(
      tester,
      FakeHealthRepository(
        connection: const HealthConnection(status: ConnectionStatus.revoked),
        rows: history(),
      ),
    );
    expect(find.text('Google Health connection revoked'), findsOneWidget);
    expect(find.text('Reconnect Google Health'), findsOneWidget);
    expect(find.text('6 h 38 min'), findsNothing);
  });
  testWidgets('no rows explains first sync and missing sleep', (tester) async {
    await showToday(tester, FakeHealthRepository());
    expect(find.text('No sleep data for last night.'), findsOneWidget);
    expect(
      find.textContaining('No data yet. Sync your device'),
      findsOneWidget,
    );
  });
  testWidgets(
    'sync loads, disables repeat taps, refetches and reports partial failure',
    (tester) async {
      final health = FakeHealthRepository(rows: history())
        ..syncCompleter = Completer<SyncResult>();
      await showToday(tester, health);
      final before = health.fetches;
      await tester.tap(find.text('Sync now'));
      await tester.pump();
      expect(find.text('Syncing…'), findsOneWidget);
      expect(health.syncs, 1);
      health.syncCompleter!.complete(
        const SyncResult(processed: 2, failed: 1, remaining: 0),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Some data could not sync. Please try again.'),
        findsOneWidget,
      );
      expect(health.fetches, greaterThan(before));
      expect(find.text('Sync now'), findsOneWidget);
    },
  );
  testWidgets('sync error is visible and retry is available', (tester) async {
    final health = FakeHealthRepository(rows: history())
      ..syncError = Exception('offline');
    await showToday(tester, health);
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not sync. Check your connection and try again.'),
      findsOneWidget,
    );
    expect(find.text('Sync now'), findsOneWidget);
  });
  testWidgets('data error shows a retry action', (tester) async {
    final health = FakeHealthRepository()..fetchError = Exception('offline');
    await showToday(tester, health);
    expect(
      find.text('Could not load your daily summary. Please try again.'),
      findsOneWidget,
    );
    health.fetchError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No sleep data for last night.'), findsOneWidget);
  });
  testWidgets('pull to refresh refetches metrics', (tester) async {
    final health = FakeHealthRepository(rows: history());
    await showToday(tester, health);
    final before = health.fetches;
    await tester.drag(find.byType(ListView), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(health.fetches, greaterThan(before));
  });
  testWidgets('phone viewport shows three metrics and sync without scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await showToday(
      tester,
      FakeHealthRepository(rows: history(demo: true, sleepToday: 425)),
    );
    expect(find.text('7 h 05 min'), findsOneWidget);
    expect(tester.getBottomRight(find.text('Sync now')).dy, lessThan(844));
    expect(tester.takeException(), isNull);
  });

  for (final metric in {
    'Sleep': 'sleep',
    'Heart': 'heart',
    'Activity': 'steps',
  }.entries) {
    testWidgets('tapping ${metric.key} opens its Week trend', (tester) async {
      final container = await startStage5(tester);
      await tester.tap(find.text(metric.key));
      await tester.pumpAndSettle();
      final uri = container
          .read(routerProvider)
          .routeInformationProvider
          .value
          .uri;
      expect(uri.toString(), '/trends?metric=${metric.value}');
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(
                ChoiceChip,
                metric.value == 'heart'
                    ? 'Resting heart rate'
                    : metric.value == 'steps'
                    ? 'Steps'
                    : 'Sleep',
              ),
            )
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<SegmentedButton<TrendRange>>(
              find.byType(SegmentedButton<TrendRange>),
            )
            .selected,
        {TrendRange.week},
      );
    });
  }
}
