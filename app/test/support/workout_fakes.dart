import 'dart:async';

import 'package:wearable_companion/features/workouts/data/workout_repository.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/workout_session.dart';

WorkoutSession finishedWorkout({
  String? id,
  DateTime? start,
  int steps = 1000,
}) {
  final startedAt = start ?? DateTime(2026, 11, 16, 10);
  final end = startedAt.add(const Duration(minutes: 30));
  return WorkoutSession(
    id: id,
    type: ExerciseType.walk,
    source: WorkoutSource.auto,
    startedAt: startedAt,
    measuredAt: end,
    endedAt: end,
    steps: steps,
  );
}

class FakeWorkoutStore implements WorkoutStore {
  final inserts = <Map<String, dynamic>>[];
  final loads = <({String userId, DateTime from, DateTime to})>[];
  List<Map<String, dynamic>> rows = [];
  bool failInserts = false, failLoads = false;
  Object? insertError;
  Completer<void>? insertGate;
  Future<List<Map<String, dynamic>>> Function(String)? onLoad;

  @override
  Future<void> insertIgnoringDuplicates(Map<String, dynamic> row) async {
    inserts.add(Map.of(row));
    await insertGate?.future;
    if (insertError != null) throw insertError!;
    if (failInserts) throw StateError('offline');
    if (!rows.any((saved) => saved['id'] == row['id'])) rows.add(Map.of(row));
  }

  @override
  Future<List<Map<String, dynamic>>> loadRange(
    String userId,
    DateTime from,
    DateTime to,
  ) async {
    loads.add((userId: userId, from: from, to: to));
    if (failLoads) throw StateError('offline');
    if (onLoad != null) return onLoad!(userId);
    return rows.where((row) {
      final start = DateTime.parse(row['started_at'] as String);
      return row['user_id'] == userId &&
          !start.isBefore(from) &&
          start.isBefore(to);
    }).toList();
  }
}
