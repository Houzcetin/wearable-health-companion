import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class PendingWorkout {
  const PendingWorkout(this.row, {this.retryAfter});

  final Map<String, dynamic> row;
  final DateTime? retryAfter;
  String get id => row['id'] as String;

  Map<String, dynamic> toJson() => {
    'row': row,
    'retry_after': retryAfter?.toUtc().toIso8601String(),
  };

  factory PendingWorkout.fromJson(Map<String, dynamic> json) => PendingWorkout(
    Map<String, dynamic>.from(json['row'] as Map),
    retryAfter: DateTime.tryParse(json['retry_after'] as String? ?? ''),
  );
}

/// Each account owns a separate key. Serialize read/modify/write operations
/// across repository lifetimes so a late acknowledgement cannot erase a save.
class PendingWorkoutQueue {
  PendingWorkoutQueue(this.userId);

  final String userId;
  String get _key => 'workouts.pending.v1.$userId';
  static Future<void> _operations = Future.value();

  Future<T> _serialized<T>(Future<T> Function(SharedPreferences) action) {
    final result = _operations.then(
      (_) async => action(await SharedPreferences.getInstance()),
    );
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Map<String, PendingWorkout> _read(SharedPreferences preferences) {
    final value = preferences.getString(_key);
    if (value == null) return {};
    final entries = (jsonDecode(value) as List).map(
      (json) => PendingWorkout.fromJson(Map<String, dynamic>.from(json as Map)),
    );
    final pending = <String, PendingWorkout>{};
    for (final entry in entries) {
      if (entry.row['user_id'] != userId) {
        throw const FormatException('Pending workout account mismatch.');
      }
      pending[entry.id] = entry;
    }
    return pending;
  }

  Future<void> _write(
    SharedPreferences preferences,
    Map<String, PendingWorkout> pending,
  ) async {
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

  Future<List<PendingWorkout>> load() =>
      _serialized((preferences) async => _read(preferences).values.toList());

  Future<PendingWorkout?> find(String id) =>
      _serialized((preferences) async => _read(preferences)[id]);

  Future<PendingWorkout> add(PendingWorkout entry) =>
      _serialized((prefs) async {
        final pending = _read(prefs);
        final saved = pending.putIfAbsent(entry.id, () => entry);
        await _write(prefs, pending);
        return saved;
      });

  Future<bool> postpone(PendingWorkout entry) => _serialized((prefs) async {
    final pending = _read(prefs);
    if (!pending.containsKey(entry.id)) return false;
    pending[entry.id] = entry;
    await _write(prefs, pending);
    return true;
  });

  Future<void> remove(String id) => _serialized((prefs) async {
    final pending = _read(prefs)..remove(id);
    await _write(prefs, pending);
  });
}
