import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/workout_session.dart';
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
    _changes.add(null);
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
        .upsert(row, onConflict: 'id', ignoreDuplicates: true);
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
  SupabaseWorkoutRepository({required this.store, required this.userId});
  final WorkoutStore store;
  final String userId;
  final Map<String, WorkoutSession> _pending = {};
  Future<void>? _retry;
  String? _saveError, _loadError;

  @override
  String? get lastError => _saveError ?? _loadError;

  @override
  Future<void> save(WorkoutSession session) {
    if (_disposed) return Future.value();
    _cache(session);
    if (session.id == null || session.endedAt == null) {
      _saveError = 'Only finished workouts can be synced.';
      return Future.value();
    }
    _pending[session.id!] = session;
    return retryPending();
  }

  @override
  Future<void> retryPending() {
    if (_disposed) return Future.value();
    return _retry ??= _flushPending().whenComplete(() => _retry = null);
  }

  Future<void> _flushPending() async {
    final attempted = <String>{};
    // Include saves made during an in-flight insert, but try each id only once.
    while (!_disposed) {
      final remaining = _pending.keys.where((id) => !attempted.contains(id));
      if (remaining.isEmpty) break;
      final id = remaining.first;
      attempted.add(id);
      try {
        await store.insertIgnoringDuplicates(
          workoutToRow(_pending[id]!, userId),
        );
        if (_disposed) return;
        _pending.remove(id);
      } catch (_) {
        if (_disposed) return;
        _saveError = 'Workouts could not sync. They will retry automatically.';
      }
    }
    if (_pending.isEmpty) _saveError = null;
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

  @override
  void dispose() {
    _pending.clear();
    super.dispose();
  }
}
