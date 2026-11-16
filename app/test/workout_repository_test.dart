import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wearable_companion/features/workouts/data/workout_repository.dart';
import 'package:wearable_companion/features/workouts/data/workout_row.dart';

import 'support/workout_fakes.dart';

void main() {
  late FakeWorkoutStore store;
  late SupabaseWorkoutRepository repository;
  late DateTime now;
  final from = DateTime(2026, 11, 16);
  final to = DateTime(2026, 11, 17);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = from;
    store = FakeWorkoutStore();
    repository = SupabaseWorkoutRepository(
      store: store,
      userId: 'user-a',
      clock: () => now,
    );
  });
  tearDown(() => repository.dispose());

  test(
    'save updates the cache and notifies before the insert completes',
    () async {
      store.insertGate = Completer<void>();
      final session = finishedWorkout();
      final changed = repository.changes.first;
      final save = repository.save(session);
      expect(repository.sessions.single, same(session));
      await changed;
      expect(store.rows, isEmpty);
      store.insertGate!.complete();
      await save;
      expect(store.inserts.single, workoutToRow(session, 'user-a'));
      expect(repository.lastError, isNull);
    },
  );

  test(
    'failed saves remain cached and retry the same id without duplicates',
    () async {
      store.failInserts = true;
      final session = finishedWorkout();
      await repository.save(session);
      expect(repository.lastError, isNotNull);
      expect(repository.sessions.single, session);
      expect(store.inserts, hasLength(1));
      store.failInserts = false;
      now = now.add(const Duration(minutes: 1));
      await repository.retryPending();
      await repository.retryPending();
      expect(store.inserts, hasLength(2));
      expect(store.inserts[0], store.inserts[1]);
      expect(repository.lastError, isNull);
      await repository.save(session);
      expect(repository.sessions, hasLength(1));
      expect(store.rows, hasLength(1));
    },
  );

  test('save retries older pending workouts once backoff expires', () async {
    store.failInserts = true;
    final first = finishedWorkout();
    await repository.save(first);
    store.failInserts = false;
    now = now.add(const Duration(minutes: 1));
    final second = finishedWorkout();
    await repository.save(second);
    expect(store.inserts.map((row) => row['id']), [
      first.id,
      first.id,
      second.id,
    ]);
    expect(store.rows, hasLength(2));
    expect(repository.sessions, hasLength(2));
  });

  test(
    'concurrent saves and retries share a flush and drain newly added ids',
    () async {
      store.insertGate = Completer<void>();
      final first = repository.save(finishedWorkout());
      final second = repository.save(finishedWorkout());
      final retry = repository.retryPending();
      await Future<void>.delayed(Duration.zero);
      expect(store.inserts, hasLength(1));
      store.insertGate!.complete();
      await Future.wait([first, second, retry]);
      expect(store.inserts, hasLength(2));
      expect(store.rows, hasLength(2));
    },
  );

  test(
    'load retries pending, merges by id, filters range and notifies',
    () async {
      final local = finishedWorkout();
      store.failInserts = true;
      await repository.save(local);
      final remote = finishedWorkout(
        start: from.add(const Duration(hours: 12)),
      );
      store.rows = [
        workoutToRow(remote, 'user-a'),
        workoutToRow(
          finishedWorkout(start: from.subtract(const Duration(seconds: 1))),
          'user-a',
        ),
        workoutToRow(finishedWorkout(start: to), 'user-a'),
        workoutToRow(finishedWorkout(), 'user-b'),
      ];
      store.failInserts = false;
      now = now.add(const Duration(minutes: 1));
      final changed = repository.changes.first;
      await repository.loadRange(from, to);
      await changed;
      await repository.loadRange(from, to);
      expect(store.loads.first, (userId: 'user-a', from: from, to: to));
      expect(repository.sessions.map((s) => s.id), [local.id, remote.id]);
      expect(repository.lastError, isNull);
    },
  );

  test(
    'load errors never throw or remove local data; retry clears the error',
    () async {
      await repository.save(finishedWorkout());
      store.failLoads = true;
      await repository.loadRange(from, to);
      expect(repository.sessions, hasLength(1));
      expect(repository.lastError, isNotNull);
      store.failLoads = false;
      await repository.loadRange(from, to);
      expect(repository.lastError, isNull);
    },
  );

  test(
    'a successful load preserves unsynced local data and its error',
    () async {
      store.failInserts = true;
      final session = finishedWorkout();
      await repository.save(session);
      store.rows = [
        workoutToRow(finishedWorkout(id: session.id, steps: 99), 'user-a'),
      ];
      await repository.loadRange(from, to);
      expect(repository.sessions.single.steps, 1000);
      expect(repository.lastError, isNotNull);
      expect(store.inserts, hasLength(1));
    },
  );

  test(
    'foreign rows and late responses after disposal cannot enter the cache',
    () async {
      store.onLoad = (_) async => [workoutToRow(finishedWorkout(), 'user-b')];
      await repository.loadRange(from, to);
      expect(repository.sessions, isEmpty);
      final gate = Completer<List<Map<String, dynamic>>>();
      store.onLoad = (_) => gate.future;
      final load = repository.loadRange(from, to);
      await Future<void>.delayed(Duration.zero);
      repository.dispose();
      gate.complete([workoutToRow(finishedWorkout(), 'user-a')]);
      await load;
      expect(repository.sessions, isEmpty);
      await repository.save(finishedWorkout());
      expect(store.inserts, isEmpty);
    },
  );

  test(
    'pending rows survive restart and restore their retry backoff',
    () async {
      store.failInserts = true;
      final session = finishedWorkout();
      await repository.save(session);
      final preferences = await SharedPreferences.getInstance();
      final persisted = {
        for (final key in preferences.getKeys()) key: preferences.get(key)!,
      };
      expect(persisted['workouts.pending.v1.user-a'], contains(session.id!));
      repository.dispose();
      // Reinitialize the preferences cache as a fresh app process would.
      SharedPreferences.setMockInitialValues(persisted);
      store = FakeWorkoutStore();
      repository = SupabaseWorkoutRepository(
        store: store,
        userId: 'user-a',
        clock: () => now,
      );
      await repository.retryPending();
      expect(repository.sessions.single.id, session.id);
      expect(store.inserts, isEmpty);
      now = now.add(const Duration(seconds: 59));
      await repository.retryPending();
      expect(store.inserts, isEmpty);
      now = now.add(const Duration(seconds: 1));
      await repository.retryPending();
      expect(store.inserts.single, workoutToRow(session, 'user-a'));
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'workouts.pending.v1.user-a',
        ),
        isFalse,
      );
    },
  );

  test(
    'a save persists even when disposed before its enqueue completes',
    () async {
      final session = finishedWorkout();
      final save = repository.save(session);
      repository.dispose();
      await save;
      expect(store.inserts, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'workouts.pending.v1.user-a',
        ),
        contains(session.id!),
      );
      repository = SupabaseWorkoutRepository(
        store: store,
        userId: 'user-a',
        clock: () => now,
      );
      await repository.retryPending();
      expect(store.rows.single['id'], session.id);
    },
  );

  test(
    'an insert is durable before sending and acknowledged after disposal',
    () async {
      store.insertGate = Completer<void>();
      final session = finishedWorkout();
      final save = repository.save(session);
      await Future<void>.delayed(Duration.zero);
      expect(store.inserts, hasLength(1));
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('workouts.pending.v1.user-a'),
        contains(session.id!),
      );
      repository.dispose();
      store.insertGate!.complete();
      await save;
      expect(preferences.containsKey('workouts.pending.v1.user-a'), isFalse);
    },
  );

  test(
    'switching accounts retains and only retries each account own rows',
    () async {
      store.failInserts = true;
      final workoutA = finishedWorkout();
      await repository.save(workoutA);
      repository.dispose();
      final storeB = FakeWorkoutStore()..failInserts = true;
      repository = SupabaseWorkoutRepository(
        store: storeB,
        userId: 'user-b',
        clock: () => now,
      );
      await repository.retryPending();
      expect(repository.sessions, isEmpty);
      expect(storeB.inserts, isEmpty);
      final workoutB = finishedWorkout();
      await repository.save(workoutB);
      expect(storeB.inserts.single['user_id'], 'user-b');
      repository.dispose();
      now = now.add(const Duration(minutes: 1));
      store.failInserts = false;
      repository = SupabaseWorkoutRepository(
        store: store,
        userId: 'user-a',
        clock: () => now,
      );
      await repository.retryPending();
      expect(store.rows.single['id'], workoutA.id);
      expect(repository.sessions.single.id, workoutA.id);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('workouts.pending.v1.user-a'), isFalse);
      expect(
        preferences.getString('workouts.pending.v1.user-b'),
        contains(workoutB.id!),
      );
      repository.dispose();
      storeB.failInserts = false;
      repository = SupabaseWorkoutRepository(
        store: storeB,
        userId: 'user-b',
        clock: () => now,
      );
      await repository.retryPending();
      expect(storeB.rows.single['id'], workoutB.id);
      expect(storeB.inserts.every((row) => row['user_id'] == 'user-b'), isTrue);
    },
  );

  for (final code in ['42501', '401', '403', 'PGRST301', '23514']) {
    test(
      'permanent $code drops the row and preserves a clear lastError',
      () async {
        store.insertError = PostgrestException(message: 'rejected', code: code);
        await repository.save(finishedWorkout());
        expect(repository.lastError, startsWith('Workout not saved:'));
        expect(
          repository.lastError,
          contains(code == '23514' ? 'allowed limits' : 'consent'),
        );
        final error = repository.lastError;
        expect(
          (await SharedPreferences.getInstance()).containsKey(
            'workouts.pending.v1.user-a',
          ),
          isFalse,
        );
        now = now.add(const Duration(minutes: 2));
        await repository.retryPending();
        await repository.loadRange(from, to);
        expect(store.inserts, hasLength(1));
        expect(repository.lastError, error);
      },
    );
  }

  for (final error in [
    StateError('offline'),
    const PostgrestException(message: 'unavailable', code: '503'),
  ]) {
    test(
      'transient $error stays durable and throttles retries from all callers',
      () async {
        store.insertError = error;
        final first = finishedWorkout();
        await repository.save(first);
        await repository.retryPending();
        await repository.loadRange(from, to);
        expect(store.inserts, hasLength(1));
        await repository.save(finishedWorkout());
        expect(store.inserts, hasLength(2));
        expect(store.inserts.last['id'], isNot(first.id));
        final preferences = await SharedPreferences.getInstance();
        expect(
          preferences.getString('workouts.pending.v1.user-a'),
          contains(first.id!),
        );
        expect(repository.lastError, contains('retry automatically'));
        now = now.add(const Duration(minutes: 1));
        store.insertError = null;
        await repository.retryPending();
        expect(store.rows, hasLength(2));
        expect(preferences.containsKey('workouts.pending.v1.user-a'), isFalse);
        expect(repository.lastError, isNull);
      },
    );
  }

  test('duplicate acknowledgement removes the durable row', () async {
    store.insertError = const PostgrestException(
      message: 'duplicate id',
      code: '23505',
    );
    await repository.save(finishedWorkout());
    expect(repository.lastError, isNull);
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        'workouts.pending.v1.user-a',
      ),
      isFalse,
    );
    now = now.add(const Duration(minutes: 1));
    await repository.retryPending();
    expect(store.inserts, hasLength(1));
  });

  test(
    'a replacement cannot resurrect a row rejected after disposal',
    () async {
      store.insertError = const PostgrestException(
        message: 'invalid',
        code: '23514',
      );
      store.insertGate = Completer<void>();
      final rejected = finishedWorkout();
      final saving = repository.save(rejected);
      await Future<void>.delayed(Duration.zero);
      expect(store.inserts, hasLength(1));
      final oldStore = store;
      repository.dispose();
      store = FakeWorkoutStore()..failInserts = true;
      repository = SupabaseWorkoutRepository(
        store: store,
        userId: 'user-a',
        clock: () => now,
      );
      await repository.retryPending();
      final pending = finishedWorkout();
      await repository.save(pending);
      oldStore.insertGate!.complete();
      await saving;
      now = now.add(const Duration(minutes: 1));
      store.failInserts = false;
      await repository.retryPending();
      expect(store.inserts.map((row) => row['id']), [pending.id, pending.id]);
      expect(store.rows.single['id'], pending.id);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'workouts.pending.v1.user-a',
        ),
        isFalse,
      );
    },
  );
}
