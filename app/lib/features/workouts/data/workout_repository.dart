import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/workout_session.dart';
import 'pending_workout_queue.dart';
import 'workout_row.dart';

abstract interface class WorkoutRepository {
  List<WorkoutSession> get sessions;
  Stream<void> get changes;
  String? get lastError;
  Future<void> save(WorkoutSession session);

  /// Start times in [from, to), using instants at the local day's boundaries.
  Future<void> loadRange(DateTime from, DateTime to);
  Future<void> retryPending();
  void dispose();
}

class InMemoryWorkoutRepository implements WorkoutRepository {
  final List<WorkoutSession> _sessions = [];
  final _changes = StreamController<void>.broadcast();
  bool _disposed = false;

  @override
  Stream<void> get changes => _changes.stream;
  @override
  String? get lastError => null;
  @override
  List<WorkoutSession> get sessions => List.unmodifiable(_sessions);

  @override
  Future<void> save(WorkoutSession session) async => _cache(session);

  void _cache(WorkoutSession session) {
    if (_disposed) return;
    final index = session.id == null
        ? -1
        : _sessions.indexWhere((s) => s.id == session.id);
    if (index < 0) {
      _sessions.add(session);
    } else {
      _sessions[index] = session;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) _changes.add(null);
  }

  @override
  Future<void> loadRange(DateTime from, DateTime to) async {}
  @override
  Future<void> retryPending() async {}
  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes.close());
  }
}

/// Thin network boundary so retries and merging can be tested without a client.
abstract interface class WorkoutStore {
  Future<void> insertIgnoringDuplicates(Map<String, dynamic> row);
  Future<List<Map<String, dynamic>>> loadRange(
    String userId,
    DateTime from,
    DateTime to,
  );
}

class SupabaseWorkoutStore implements WorkoutStore {
  SupabaseWorkoutStore(this._client);
  final SupabaseClient _client;

  void _requireUser(String userId) {
    if (_client.auth.currentUser?.id != userId) {
      throw StateError('Workout account changed.');
    }
  }

  @override
  Future<void> insertIgnoringDuplicates(Map<String, dynamic> row) async {
    _requireUser(row['user_id'] as String);
    await _client
        .from('workouts')
        .upsert(row, onConflict: 'id', ignoreDuplicates: true)
        .retry(enabled: false);
  }

  @override
  Future<List<Map<String, dynamic>>> loadRange(
    String userId,
    DateTime from,
    DateTime to,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += 1000) {
      _requireUser(userId);
      final page = await _client
          .from('workouts')
          .select()
          .eq('user_id', userId)
          .gte('started_at', from.toUtc().toIso8601String())
          .lt('started_at', to.toUtc().toIso8601String())
          .order('started_at')
          .order('id')
          .range(offset, offset + 999);
      rows.addAll(page);
      if (page.length < 1000) return rows;
    }
  }
}

class SupabaseWorkoutRepository extends InMemoryWorkoutRepository {
  SupabaseWorkoutRepository({
    required this.store,
    required this.userId,
    DateTime Function()? clock,
  }) : _queue = PendingWorkoutQueue(userId),
       _clock = clock ?? DateTime.now {
    unawaited(retryPending());
  }
  final WorkoutStore store;
  final String userId;
  final PendingWorkoutQueue _queue;
  final DateTime Function() _clock;
  final Map<String, PendingWorkout> _pending = {};
  final Set<String> _unpersisted = {};
  bool _restored = false;
  Future<void>? _retry;
  String? _saveError, _loadError, _permanentError;

  @override
  String? get lastError => _permanentError ?? _saveError ?? _loadError;

  @override
  Future<void> save(WorkoutSession session) {
    if (_disposed) return Future.value();
    _cache(session);
    if (session.id == null || session.endedAt == null) {
      _saveError = 'Only finished workouts can be synced.';
      _notify();
      return Future.value();
    }
    final entry = _pending.putIfAbsent(session.id!, () {
      _unpersisted.add(session.id!);
      return PendingWorkout(workoutToRow(session, userId));
    });
    // Begin persisting immediately, even if the provider is disposed while the
    // write is in flight. No request may precede this durable enqueue.
    return _enqueue(entry);
  }

  Future<void> _enqueue(PendingWorkout entry) async {
    try {
      await _queue.add(entry);
      _unpersisted.remove(entry.id);
    } catch (_) {
      _saveError = 'Workouts could not be stored on this device. Please retry.';
      _notify();
      return;
    }
    await retryPending();
  }

  @override
  Future<void> retryPending() {
    if (_disposed) return Future.value();
    return _retry ??= _flushPending().whenComplete(() => _retry = null);
  }

  Future<void> _flushPending() async {
    try {
      if (!_restored) {
        final restored = await _queue.load();
        if (_disposed) return;
        for (final entry in restored) {
          if (_pending.containsKey(entry.id)) continue;
          _pending[entry.id] = entry;
          _cache(workoutFromRow(entry.row));
        }
        _restored = true;
      }
    } catch (_) {
      _saveError = 'Pending workouts could not be loaded. Please retry.';
      _notify();
      return;
    }
    final attempted = <String>{};
    // Include saves made during an in-flight insert, but try each id only once.
    while (!_disposed) {
      final remaining = _pending.keys.where((id) => !attempted.contains(id));
      if (remaining.isEmpty) break;
      final id = remaining.first;
      attempted.add(id);
      try {
        final entry = _unpersisted.contains(id)
            ? await _queue.add(_pending[id]!)
            : await _queue.find(id);
        _unpersisted.remove(id);
        // A disposed repository may have acknowledged or rejected this row
        // since restoration. Never re-enqueue its stale in-memory snapshot.
        if (entry == null) {
          _pending.remove(id);
          continue;
        }
        _pending[id] = entry;
        if (_disposed) return;
        if (entry.retryAfter?.isAfter(_clock()) ?? false) continue;
        final deferred = PendingWorkout(
          entry.row,
          retryAfter: _clock().add(const Duration(minutes: 1)),
        );
        // Persist backoff before sending so recreation during an insert also
        // respects the retry interval. Supabase's own short retries are off.
        if (!await _queue.postpone(deferred)) {
          _pending.remove(id);
          continue;
        }
        _pending[id] = deferred;
        if (_disposed) return;
      } catch (_) {
        _saveError =
            'Workouts could not be stored on this device. Please retry.';
        continue;
      }
      Object? failure;
      try {
        await store.insertIgnoringDuplicates(_pending[id]!.row);
      } catch (error) {
        failure = error;
      }
      final permanentError = _permanentSaveError(failure);
      if (failure == null || _isDuplicate(failure) || permanentError != null) {
        try {
          // Acknowledgements still remove this user's row after disposal.
          await _queue.remove(id);
        } catch (_) {
          _saveError =
              'Workouts could not be stored on this device. Please retry.';
          continue;
        }
        _pending.remove(id);
        if (permanentError != null) _permanentError = permanentError;
      } else {
        _saveError = 'Workouts could not sync. They will retry automatically.';
      }
    }
    if (_pending.isEmpty) _saveError = null;
    _notify();
  }

  bool _isDuplicate(Object error) =>
      error is PostgrestException && error.code == '23505';

  String? _permanentSaveError(Object? error) {
    if (error is PostgrestException) {
      return switch (error.code) {
        '42501' => 'Workout not saved: health data consent is off.',
        '401' || '403' || 'PGRST301' || 'PGRST302' || 'PGRST303' =>
          'Workout not saved: permission denied. Check sign-in and health data consent.',
        '23514' =>
          'Workout not saved: workout values are outside allowed limits.',
        _ => null,
      };
    }
    return null;
  }

  @override
  Future<void> loadRange(DateTime from, DateTime to) async {
    if (_disposed) return;
    await retryPending();
    if (_disposed) return;
    try {
      final rows = await store.loadRange(userId, from, to);
      if (_disposed) return;
      final sessions = rows
          .where((row) => row['user_id'] == userId)
          .map(workoutFromRow)
          .toList();
      for (final session in sessions) {
        // A local save may still be awaiting acknowledgement from the server.
        if (!_pending.containsKey(session.id)) _cache(session);
      }
      _loadError = null;
    } catch (_) {
      if (!_disposed) _loadError = 'Saved workouts could not be loaded.';
    }
  }
}
