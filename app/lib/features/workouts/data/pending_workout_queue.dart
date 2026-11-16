import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'workout_row.dart';

class PendingWorkout {
  const PendingWorkout(
    this.row, {
    this.retryAfter,
    this.paused = false,
    this.lastError,
  });

  final Map<String, dynamic> row;
  final DateTime? retryAfter;
  final bool paused;
  final String? lastError;
  String get id => row['id'] as String;

  Map<String, dynamic> toJson() => {
    'row': row,
    'retry_after': retryAfter?.toUtc().toIso8601String(),
    'paused': paused,
    'last_error': lastError,
  };

  factory PendingWorkout.fromJson(Map<String, dynamic> json) => PendingWorkout(
    Map<String, dynamic>.from(json['row'] as Map),
    retryAfter: DateTime.tryParse(json['retry_after'] as String? ?? ''),
    paused: json['paused'] as bool? ?? false,
    lastError: json['last_error'] as String?,
  );
}

/// Each account owns a separate key. Serialize read/modify/write operations
/// across repository lifetimes so a late acknowledgement cannot erase a save.
class PendingWorkoutQueue {
  PendingWorkoutQueue(this.userId, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _generation = _generations[userId] ?? 0;

  final String userId;
  final DateTime Function() _clock;
  final int _generation;
  String get _key => 'workouts.pending.v1.$userId';
  static Future<void>? _operations;
  static final Map<String, int> _generations = {};
  bool get _cleared => _generation != (_generations[userId] ?? 0);

  Future<T> _serialized<T>(Future<T> Function(SharedPreferences) action) {
    final result = (_operations ?? Future<void>.value()).then(
      (_) async => action(await SharedPreferences.getInstance()),
    );
    // Keep only in-flight work, releasing the completed future and its zone.
    late final Future<void> operation;
    void release() {
      if (identical(_operations, operation)) _operations = null;
    }

    operation = result.then<void>(
      (_) => release(),
      onError: (Object _, StackTrace _) => release(),
    );
    _operations = operation;
    return result;
  }

  Future<Map<String, PendingWorkout>> _read(
    SharedPreferences preferences,
  ) async {
    final value = preferences.get(_key);
    if (value == null) return {};
    List<dynamic> entries;
    try {
      entries = jsonDecode(value as String) as List;
    } catch (_) {
      await preferences.setString('$_key.corrupt', value.toString());
      await preferences.remove(_key);
      return {};
    }
    final pending = <String, PendingWorkout>{};
    for (final json in entries) {
      try {
        final entry = PendingWorkout.fromJson(
          Map<String, dynamic>.from(json as Map),
        );
        if (entry.row['user_id'] != userId || entry.id.isEmpty) continue;
        // Parse each item independently so one malformed row cannot hide others.
        workoutFromRow(entry.row);
        pending[entry.id] = entry;
      } catch (_) {
        continue;
      }
    }
    _prune(pending);
    if (pending.length != entries.length) await _write(preferences, pending);
    return pending;
  }

  void _prune(Map<String, PendingWorkout> pending) {
    final cutoff = _clock().subtract(const Duration(days: 30));
    DateTime startedAt(PendingWorkout entry) =>
        DateTime.parse(entry.row['started_at'] as String);
    pending.removeWhere((_, entry) => startedAt(entry).isBefore(cutoff));
    if (pending.length <= 200) return;
    final oldest = pending.values.toList()
      ..sort((a, b) => startedAt(a).compareTo(startedAt(b)));
    for (final entry in oldest.take(pending.length - 200)) {
      pending.remove(entry.id);
    }
  }

  Future<void> _write(
    SharedPreferences preferences,
    Map<String, PendingWorkout> pending,
  ) async {
    _prune(pending);
    final saved = pending.isEmpty
        ? await preferences.remove(_key)
        : await preferences.setString(
            _key,
            jsonEncode(pending.values.map((entry) => entry.toJson()).toList()),
          );
    if (!saved) {
      await preferences.reload();
      throw StateError('Pending workouts could not be stored.');
    }
  }

  Future<List<PendingWorkout>> load() => _serialized(
    (preferences) async => (await _read(preferences)).values.toList(),
  );

  Future<PendingWorkout?> find(String id) =>
      _serialized((preferences) async => (await _read(preferences))[id]);

  Future<PendingWorkout> add(PendingWorkout entry) =>
      _serialized((prefs) async {
        if (_cleared) throw StateError('Pending workouts were cleared.');
        final pending = await _read(prefs);
        final saved = pending.putIfAbsent(entry.id, () => entry);
        await _write(prefs, pending);
        return saved;
      });

  Future<bool> postpone(PendingWorkout entry) => _serialized((prefs) async {
    if (_cleared) return false;
    final pending = await _read(prefs);
    if (!pending.containsKey(entry.id)) return false;
    pending[entry.id] = entry;
    await _write(prefs, pending);
    return true;
  });

  Future<void> remove(String id) => _serialized((prefs) async {
    if (_cleared) return;
    final pending = (await _read(prefs))..remove(id);
    await _write(prefs, pending);
  });

  /// Invalidate old handles immediately so a late save cannot restore deleted
  /// health data. Serialization also clears writes already in flight.
  Future<void> clear() {
    _generations[userId] = (_generations[userId] ?? 0) + 1;
    return _serialized((prefs) async {
      await _write(prefs, {});
      await prefs.remove('$_key.corrupt');
    });
  }
}
