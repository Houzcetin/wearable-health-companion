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
