import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wearable_companion/data/auth_repository.dart';
import 'package:wearable_companion/data/profile_repository.dart';
import 'package:wearable_companion/data/providers.dart';
import 'package:wearable_companion/features/workouts/data/activity_sources.dart';
import 'package:wearable_companion/features/workouts/data/workout_repository.dart';
import 'package:wearable_companion/features/workouts/data/workout_row.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/workout_provider.dart';

import 'support/fake_repositories.dart';
import 'support/workout_fakes.dart';

class CountingWorkoutRepository extends InMemoryWorkoutRepository {
  int retries = 0;
  final loads = <(DateTime, DateTime)>[];
  @override
  Future<void> retryPending() async => retries++;
  @override
  Future<void> loadRange(DateTime from, DateTime to) async {
    loads.add((from, to));
  }
}

void main() {
  late DateTime now;
  late FakeWorkoutStore store;
  late ProviderContainer container;
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await container.pump();
  }

  Future<void> setup({
    bool configured = true,
    bool signedIn = true,
    bool consented = true,
    WorkoutRepository? repository,
  }) async {
    auth = FakeAuthRepository(user: signedIn ? testUser : null);
    profiles = FakeProfileRepository(consented: consented);
    container = ProviderContainer(
      overrides: [
        backendConfiguredProvider.overrideWithValue(configured),
        authRepositoryProvider.overrideWithValue(auth),
        profileRepositoryProvider.overrideWithValue(profiles),
        workoutStoreProvider.overrideWithValue(store),
        workoutClockProvider.overrideWithValue(() => now),
        workoutTickIntervalProvider.overrideWithValue(null),
        activitySourceProvider.overrideWithValue(UnavailableActivitySource()),
        stepSourceProvider.overrideWithValue(UnavailableStepSource()),
        if (repository != null)
          workoutRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await auth.close();
      repository?.dispose();
    });
    container.listen(workoutProvider, (_, _) {});
    await settle();
    if (configured && signedIn && repository == null) {
      await container.read(profileProvider.future);
      await settle();
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 11, 16, 12);
    store = FakeWorkoutStore();
  });

  test(
    'build loads today and republishes remote arrivals without a tick',
    () async {
      final response = Completer<List<Map<String, dynamic>>>();
      store.onLoad = (_) => response.future;
      await setup();
      expect(
        container.read(workoutRepositoryProvider),
        isA<SupabaseWorkoutRepository>(),
      );
      expect(container.read(workoutProvider).todaySessions, isEmpty);
      expect(store.loads.single, (
        userId: testUser.id,
        from: DateTime(2026, 11, 16),
        to: DateTime(2026, 11, 17),
      ));
      final remote = finishedWorkout();
      response.complete([workoutToRow(remote, testUser.id)]);
      await settle();
      expect(
        container.read(workoutProvider).todaySessions.single.id,
        remote.id,
      );
      expect(container.read(workoutProvider).summary, isNull);
    },
  );

  for (final mode in ['signed out', 'no backend', 'no consent']) {
    test('$mode uses memory and makes no workout requests', () async {
      await setup(
        signedIn: mode != 'signed out',
        configured: mode != 'no backend',
        consented: mode != 'no consent',
      );
      final repository = container.read(workoutRepositoryProvider);
      expect(repository, isA<InMemoryWorkoutRepository>());
      expect(repository, isNot(isA<SupabaseWorkoutRepository>()));
      final notifier = container.read(workoutProvider.notifier);
      notifier.manualStart(ExerciseType.walk);
      now = now.add(const Duration(minutes: 1));
      notifier.acceptStop();
      expect(container.read(workoutProvider).todaySessions, hasLength(1));
      await settle();
      expect(store.loads, isEmpty);
      expect(store.inserts, isEmpty);
    });
  }

  for (final unavailable in [false, true]) {
    test(
      'missing or uninitialized Supabase client safely falls back ($unavailable)',
      () async {
        container = ProviderContainer(
          overrides: [
            backendConfiguredProvider.overrideWithValue(true),
            currentUserProvider.overrideWithValue(testUser),
            profileProvider.overrideWith(
              (ref) async => Profile(
                userId: testUser.id,
                timezone: 'UTC',
                healthConsentAt: now,
              ),
            ),
            supabaseClientProvider.overrideWith((ref) {
              if (unavailable) throw StateError('Supabase is not initialized');
              return null;
            }),
          ],
        );
        addTearDown(container.dispose);
        await container.read(profileProvider.future);
        expect(
          container.read(workoutRepositoryProvider),
          isA<InMemoryWorkoutRepository>(),
        );
        expect(
          container.read(workoutRepositoryProvider),
          isNot(isA<SupabaseWorkoutRepository>()),
        );
      },
    );
  }

  test(
    'tick retries at most once per minute and loads the next local day',
    () async {
      final repository = CountingWorkoutRepository();
      await setup(configured: false, repository: repository);
      final notifier = container.read(workoutProvider.notifier);
      expect(repository.loads, [
        (DateTime(2026, 11, 16), DateTime(2026, 11, 17)),
      ]);
      for (var i = 0; i < 10; i++) {
        notifier.tick();
      }
      expect(repository.retries, 0);
      now = now.add(const Duration(seconds: 59));
      notifier.tick();
      expect(repository.retries, 0);
      now = now.add(const Duration(seconds: 1));
      notifier.tick();
      notifier.tick();
      expect(repository.retries, 1);
      now = now.add(const Duration(minutes: 1));
      notifier.tick();
      expect(repository.retries, 2);
      now = DateTime(2026, 11, 17);
      notifier.tick();
      expect(repository.loads.last, (
        DateTime(2026, 11, 17),
        DateTime(2026, 11, 18),
      ));
      expect(repository.loads, hasLength(2));
    },
  );

  test(
    'finishing publishes immediately and the tick retries a failed insert',
    () async {
      await setup();
      store.failInserts = true;
      final notifier = container.read(workoutProvider.notifier);
      notifier.manualStart(ExerciseType.run);
      now = now.add(const Duration(minutes: 5));
      notifier.acceptStop();
      final saved = container.read(workoutProvider).todaySessions.single;
      expect(saved.id, isNotNull);
      expect(container.read(workoutProvider).summary, saved);
      await settle();
      expect(store.inserts, hasLength(1));
      store.failInserts = false;
      now = now.add(const Duration(minutes: 1));
      notifier.tick();
      await settle();
      expect(store.inserts, hasLength(2));
      expect(store.inserts.last['id'], saved.id);
      expect(container.read(workoutProvider).todaySessions, hasLength(1));
    },
  );

  test(
    'account switch clears history, summary and active session; ignores late loads',
    () async {
      store.rows = [workoutToRow(finishedWorkout(), testUser.id)];
      await setup();
      final oldRepository = container.read(workoutRepositoryProvider);
      final notifier = container.read(workoutProvider.notifier);
      notifier.manualStart(ExerciseType.run);
      now = now.add(const Duration(minutes: 1));
      notifier.acceptStop();
      notifier.manualStart(ExerciseType.bike);
      expect(container.read(workoutProvider).summary, isNotNull);
      expect(container.read(workoutProvider).session, isNotNull);
      final oldResponse = Completer<List<Map<String, dynamic>>>();
      final newResponse = Completer<List<Map<String, dynamic>>>();
      store.onLoad = (userId) =>
          userId == testUser.id ? oldResponse.future : newResponse.future;
      final oldLoad = oldRepository.loadRange(
        DateTime(2026, 11, 16),
        DateTime(2026, 11, 17),
      );
      await settle();
      auth.emit(const AppUser(id: 'user-b'));
      await settle();
      await container.read(profileProvider.future);
      await settle();
      expect(container.read(workoutProvider).todaySessions, isEmpty);
      expect(container.read(workoutProvider).summary, isNull);
      expect(container.read(workoutProvider).session, isNull);
      final remoteB = finishedWorkout();
      newResponse.complete([workoutToRow(remoteB, 'user-b')]);
      oldResponse.complete([workoutToRow(finishedWorkout(), testUser.id)]);
      await oldLoad;
      await settle();
      expect(
        container.read(workoutProvider).todaySessions.single.id,
        remoteB.id,
      );
      auth.emit(null);
      await settle();
      expect(container.read(workoutProvider).todaySessions, isEmpty);
      expect(
        container.read(workoutRepositoryProvider),
        isNot(isA<SupabaseWorkoutRepository>()),
      );
    },
  );

  test(
    'consent withdrawal clears workouts and later consent starts a fresh cache',
    () async {
      store.rows = [workoutToRow(finishedWorkout(), testUser.id)];
      await setup();
      expect(container.read(workoutProvider).todaySessions, hasLength(1));
      profiles.consented = false;
      container.invalidate(profileProvider);
      await container.read(profileProvider.future);
      await settle();
      expect(container.read(workoutProvider).todaySessions, isEmpty);
      final local = finishedWorkout();
      await container.read(workoutRepositoryProvider).save(local);
      await settle();
      expect(container.read(workoutProvider).todaySessions.single.id, local.id);
      profiles.consented = true;
      container.invalidate(profileProvider);
      await container.read(profileProvider.future);
      await settle();
      expect(
        container.read(workoutProvider).todaySessions.single.id,
        store.rows.single['id'],
      );
      expect(store.inserts, isEmpty);
    },
  );

  test(
    'a profile refresh with the same consent preserves pending saves',
    () async {
      await setup();
      store.failInserts = true;
      final repository = container.read(workoutRepositoryProvider);
      await repository.save(finishedWorkout());
      container.invalidate(profileProvider);
      await container.read(profileProvider.future);
      await settle();
      expect(container.read(workoutRepositoryProvider), same(repository));
      store.failInserts = false;
      now = now.add(const Duration(minutes: 1));
      await repository.retryPending();
      expect(store.rows, hasLength(1));
    },
  );

  test(
    'account changes retain pending rows until their owner signs back in',
    () async {
      await setup();
      store.failInserts = true;
      final workoutA = finishedWorkout();
      await container.read(workoutRepositoryProvider).save(workoutA);
      auth.emit(const AppUser(id: 'user-b'));
      await settle();
      await container.read(profileProvider.future);
      await settle();
      expect(container.read(workoutProvider).todaySessions, isEmpty);
      expect(store.inserts, hasLength(1));
      final workoutB = finishedWorkout();
      await container.read(workoutRepositoryProvider).save(workoutB);
      expect(store.inserts.last['user_id'], 'user-b');
      now = now.add(const Duration(minutes: 1));
      store.failInserts = false;
      auth.emit(testUser);
      await settle();
      await container.read(profileProvider.future);
      await settle();
      await container.read(workoutRepositoryProvider).retryPending();
      expect(store.rows.single['id'], workoutA.id);
      expect(
        container.read(workoutProvider).todaySessions.single.id,
        workoutA.id,
      );
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('workouts.pending.v1.user-b'),
        contains(workoutB.id!),
      );
      expect(
        preferences.containsKey('workouts.pending.v1.${testUser.id}'),
        isFalse,
      );
    },
  );
}
