import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/data/workout_repository.dart';
import 'package:wearable_companion/features/workouts/data/workout_row.dart';

import 'support/workout_fakes.dart';

void main() {
  late FakeWorkoutStore store;
  late SupabaseWorkoutRepository repository;
  final from = DateTime(2026, 11, 16);
  final to = DateTime(2026, 11, 17);
  setUp(() {
    store = FakeWorkoutStore();
    repository = SupabaseWorkoutRepository(store: store, userId: 'user-a');
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
      expect(repository.loadError, isNull);
      expect(repository.sessions.single, session);
      expect(store.inserts, hasLength(1));
      store.failInserts = false;
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

  test('save retries older pending workouts too', () async {
    store.failInserts = true;
    final first = finishedWorkout();
    await repository.save(first);
    store.failInserts = false;
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
      expect(repository.loadError, 'Saved workouts could not be loaded.');
      store.failLoads = false;
      await repository.loadRange(from, to);
      expect(repository.lastError, isNull);
      expect(repository.loadError, isNull);
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
      expect(repository.loadError, isNull);
      expect(store.inserts, hasLength(2));
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
}
