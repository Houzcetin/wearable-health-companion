import '../domain/activity_sample.dart';
import '../domain/workout_session.dart';

Map<String, dynamic> workoutToRow(WorkoutSession session, String userId) {
  if (session.id == null || session.endedAt == null) {
    throw ArgumentError('Only finished workouts can be persisted.');
  }
  return {
    'id': session.id,
    'user_id': userId,
    'type': session.type.name,
    'source': session.source.name,
    'started_at': session.startedAt.toUtc().toIso8601String(),
    'ended_at': session.endedAt!.toUtc().toIso8601String(),
    'steps': session.steps,
    'distance_m': session.distanceMeters,
    'calories': session.calories,
    'weight_kg': session.weightKg,
  };
}

/// Bound finite measurements before enqueueing, including rows from older apps.
/// Non-finite values remain serializable locally, but validation blocks upload.
Map<String, dynamic> boundedWorkoutRow(Map<String, dynamic> original) {
  final row = Map<String, dynamic>.of(original);
  for (final (key, lower, upper) in [
    ('steps', 0, 500000),
    ('distance_m', 0, 1000000),
    ('calories', 0, 50000),
    ('weight_kg', 20, 400),
  ]) {
    final value = row[key];
    final number = value is num ? value : num.tryParse('$value');
    if (number == null) continue;
    row[key] = number.isFinite
        ? (key == 'steps'
              ? number.clamp(lower, upper).toInt()
              : number.clamp(lower, upper))
        : number.toString();
  }
  final start = DateTime.parse(row['started_at'] as String);
  final end = DateTime.parse(row['ended_at'] as String);
  if (end.difference(start) > const Duration(hours: 24)) {
    row['ended_at'] = start
        .add(const Duration(hours: 24))
        .toUtc()
        .toIso8601String();
  }
  return row;
}

String? workoutSyncError(Map<String, dynamic> row) {
  final session = workoutFromRow(row);
  if (session.duration <= Duration.zero) {
    return 'Workout stays on this device: end time must be after start time.';
  }
  if (!session.distanceMeters.isFinite ||
      !session.calories.isFinite ||
      !session.weightKg.isFinite) {
    return 'Workout stays on this device: measurements must be finite numbers.';
  }
  return null;
}

WorkoutSession workoutFromRow(Map<String, dynamic> row) {
  double number(String key) => switch (row[key]) {
    num value => value.toDouble(),
    String value => double.parse(value),
    _ => throw FormatException('Missing workout $key'),
  };
  final endedAt = DateTime.parse(row['ended_at'] as String);
  return WorkoutSession(
    id: row['id'] as String,
    type: ExerciseType.values.byName(row['type'] as String),
    source: WorkoutSource.values.byName(row['source'] as String),
    startedAt: DateTime.parse(row['started_at'] as String),
    endedAt: endedAt,
    measuredAt: endedAt,
    steps: number('steps').toInt(),
    weightKg: row['weight_kg'] == null ? 70 : number('weight_kg'),
    recordedDistanceMeters: number('distance_m'),
    recordedCalories: number('calories'),
  );
}
