import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wearable_companion/data/providers.dart';
import 'package:wearable_companion/features/settings/settings_screen.dart';
import 'package:wearable_companion/features/trends/domain/trends.dart';
import 'package:wearable_companion/features/workouts/data/pending_workout_queue.dart';
import 'package:wearable_companion/features/workouts/data/workout_row.dart';

import 'support/fake_repositories.dart';
import 'support/stage5_harness.dart';
import 'support/workout_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  const key = 'flutter.workouts.pending.v1.user-a';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final stored = <String, Object>{};
  final removals = <String>[];

  setUp(() {
    SharedPreferences.resetStatic();
    stored.clear();
    removals.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getAll':
          return Map<String, Object>.of(stored);
        case 'setString':
          final arguments = call.arguments as Map;
          stored[arguments['key'] as String] = arguments['value'] as Object;
          return true;
        case 'remove':
          final removedKey = (call.arguments as Map)['key'] as String;
          removals.add(removedKey);
          return false;
        default:
          throw UnsupportedError(call.method);
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    SharedPreferences.resetStatic();
  });

  for (final account in [false, true]) {
    testWidgets(
      '${account ? 'account' : 'health'} deletion continues when local removal returns false',
      (tester) async {
        final now = DateTime.now();
        await PendingWorkoutQueue(testUser.id).add(
          PendingWorkout(
            workoutToRow(finishedWorkout(start: now), testUser.id),
          ),
        );
        final originalQueue = stored[key];
        final auth = FakeAuthRepository();
        final profile = FakeProfileRepository(coachConsented: true);
        final health = FakeHealthRepository(rows: history());
        health.onDelete = (_) => profile.consented = false;
        final container = await startStage5(
          tester,
          screen: const SettingsScreen(),
          auth: auth,
          profile: profile,
          health: health,
        );
        final today = await container.read(todayDataProvider.future);
        final trends = await container.read(
          trendsDataProvider((TrendMetric.sleep, TrendRange.week)).future,
        );
        final coach = await container.read(coachThreadProvider.future);
        final profileFetches = profile.fetches;
        final action = find.text(
          account ? 'Delete account' : 'Delete health data',
        );
        await tester.ensureVisible(action);
        await tester.pump();
        await tester.tap(action);
        await tester.pumpAndSettle();
        if (account) {
          await tester.enterText(
            find.byKey(const Key('delete-account-confirmation')),
            'DELETE',
          );
          await tester.pump();
        }

        final reports = <FlutterErrorDetails>[];
        final originalOnError = FlutterError.onError;
        FlutterError.onError = reports.add;
        try {
          await tester.tap(find.byKey(const Key('confirm-delete')));
          await tester.pumpAndSettle();
        } finally {
          FlutterError.onError = originalOnError;
        }

        expect(health.deletions, [account]);
        expect(removals, contains(key));
        expect(stored[key], originalQueue);
        expect(
          reports.where((details) => details.exception is StateError),
          hasLength(1),
        );
        expect(
          reports.first.exceptionAsString(),
          contains('Pending workouts could not be stored.'),
        );
        expect(reports.first.stack, isNotNull);
        expect(
          reports.skip(1).map((details) => details.exception),
          everyElement('Pending workouts could not be cleared.'),
        );
        expect(auth.signOuts, account ? 1 : 0);
        expect(find.textContaining('Could not'), findsNothing);
        expect(
          find.text(
            account ? 'Deleting your account…' : 'Deleting your health data…',
          ),
          findsNothing,
        );
        if (!account) {
          expect(
            find.text('Your health data and coach history were deleted.'),
            findsOneWidget,
          );
          expect(profile.fetches, greaterThan(profileFetches));
          final refreshedToday = await container.read(todayDataProvider.future);
          expect(refreshedToday, isNot(same(today)));
          expect(refreshedToday.rows, isEmpty);
          final refreshedTrends = await container.read(
            trendsDataProvider((TrendMetric.sleep, TrendRange.week)).future,
          );
          expect(refreshedTrends, isNot(same(trends)));
          expect(refreshedTrends.rows, isEmpty);
          expect(
            await container.read(coachThreadProvider.future),
            isNot(same(coach)),
          );
          expect(container.read(connectionProvider).value, isNull);
          expect(container.read(currentUserProvider), isNotNull);
        }
      },
    );
  }
}
