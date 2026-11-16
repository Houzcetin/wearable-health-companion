import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wearable_companion/data/auth_repository.dart';
import 'package:wearable_companion/data/providers.dart';
import 'package:wearable_companion/features/settings/settings_screen.dart';
import 'package:wearable_companion/features/workouts/data/pending_workout_queue.dart';
import 'package:wearable_companion/features/workouts/data/workout_row.dart';

import 'support/fake_repositories.dart';
import 'support/stage5_harness.dart';
import 'support/workout_fakes.dart';

class _InspectingAuthRepository extends FakeAuthRepository {
  void Function()? onSignOut;

  @override
  Future<void> signOut() async {
    onSignOut?.call();
    await super.signOut();
  }
}

class _DelayedDeletionRepository extends FakeHealthRepository {
  final completion = Completer<void>();

  @override
  Future<void> deleteData({required bool account}) async {
    await completion.future;
    await super.deleteData(account: account);
  }
}

void main() {
  const key = 'workouts.pending.v1.user-a';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<PendingWorkoutQueue> seedQueue(String userId) async {
    final now = DateTime.now();
    final queue = PendingWorkoutQueue(userId, clock: () => now);
    await queue.add(
      PendingWorkout(
        workoutToRow(
          finishedWorkout(start: now.subtract(const Duration(hours: 1))),
          userId,
        ),
        paused: true,
        retryAfter: now.add(const Duration(hours: 6)),
        lastError: 'Workouts are waiting: health data consent is off.',
      ),
    );
    return queue;
  }

  Future<void> confirmDeletion(
    WidgetTester tester, {
    bool account = false,
  }) async {
    final action = find.text(account ? 'Delete account' : 'Delete health data');
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
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pump();
  }

  for (final account in [false, true]) {
    for (final consented in [false, true]) {
      testWidgets(
        '${account ? 'account' : 'health'} deletion clears only the owner queue '
        'and backup with consent $consented',
        (tester) async {
          final queue = await seedQueue(testUser.id);
          final other = await seedQueue('user-b');
          final preferences = await SharedPreferences.getInstance();
          await preferences.setString('$key.corrupt', 'private backup');
          final profile = FakeProfileRepository(consented: consented);
          final health = FakeHealthRepository();
          health.onDelete = (_) => profile.consented = false;
          var clearedBeforeSignOut = false;
          final auth = _InspectingAuthRepository()
            ..onSignOut = () {
              clearedBeforeSignOut =
                  !preferences.containsKey(key) &&
                  !preferences.containsKey('$key.corrupt');
            };
          await startStage5(
            tester,
            screen: const SettingsScreen(),
            profile: profile,
            health: health,
            auth: auth,
          );
          expect(await queue.load(), hasLength(1));
          await confirmDeletion(tester, account: account);
          await tester.pumpAndSettle();
          expect(health.deletions, [account]);
          expect(preferences.containsKey(key), isFalse);
          expect(preferences.containsKey('$key.corrupt'), isFalse);
          expect(await other.load(), hasLength(1));
          expect(auth.signOuts, account ? 1 : 0);
          if (account) expect(clearedBeforeSignOut, isTrue);
          // A save holding a pre-deletion queue handle cannot restore the data.
          await expectLater(
            queue.add(
              PendingWorkout(workoutToRow(finishedWorkout(), testUser.id)),
            ),
            throwsStateError,
          );
        },
      );
    }

    testWidgets(
      'failed ${account ? 'account' : 'health'} deletion preserves the queue',
      (tester) async {
        final queue = await seedQueue(testUser.id);
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString('$key.corrupt', 'private backup');
        final auth = FakeAuthRepository();
        await startStage5(
          tester,
          screen: const SettingsScreen(),
          profile: FakeProfileRepository(consented: false),
          health: FakeHealthRepository()..deleteError = StateError('offline'),
          auth: auth,
        );
        await confirmDeletion(tester, account: account);
        await tester.pumpAndSettle();
        expect(await queue.load(), hasLength(1));
        expect(preferences.getString('$key.corrupt'), 'private backup');
        expect(auth.signOuts, 0);
      },
    );
  }

  testWidgets('deletion clears its original owner after an account switch', (
    tester,
  ) async {
    final queue = await seedQueue(testUser.id);
    final other = await seedQueue('user-b');
    final health = _DelayedDeletionRepository();
    final auth = FakeAuthRepository();
    final container = await startStage5(
      tester,
      screen: const SettingsScreen(),
      profile: FakeProfileRepository(consented: false),
      health: health,
      auth: auth,
    );
    await confirmDeletion(tester);
    expect(await queue.load(), hasLength(1));
    auth.emit(const AppUser(id: 'user-b'));
    await tester.pump();
    expect(container.read(currentUserProvider)?.id, 'user-b');
    health.completion.complete();
    await tester.pumpAndSettle();
    expect(await queue.load(), isEmpty);
    expect(await other.load(), hasLength(1));
  });

  testWidgets('successful deletion clears the queue after Settings unmounts', (
    tester,
  ) async {
    final queue = await seedQueue(testUser.id);
    final health = _DelayedDeletionRepository();
    await startStage5(
      tester,
      screen: const SettingsScreen(),
      profile: FakeProfileRepository(consented: false),
      health: health,
    );
    await confirmDeletion(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    health.completion.complete();
    await tester.pumpAndSettle();
    expect(health.deletions, [false]);
    expect(await queue.load(), isEmpty);
  });
}
