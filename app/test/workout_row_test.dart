import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/data/workout_row.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/auto_workout_detector.dart';
import 'package:wearable_companion/features/workouts/domain/workout_session.dart';

import 'support/workout_fakes.dart';

void main() {
  test(
    'finishing generates a stable UUID v4 and active snapshots have no id',
    () {
      var now = DateTime(2026, 11, 16, 10);
      final detector = AutoWorkoutDetector(clock: () => now);
      detector.manualStart(ExerciseType.walk);
      expect(detector.currentSession!.id, isNull);
      now = now.add(const Duration(minutes: 1));
      detector.manualStop();
      final id = detector.finishedSession!.id!;
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      detector.tick();
      detector.manualStop();
      expect(detector.finishedSession!.id, id);
      expect(finishedWorkout().id, isNot(id));
    },
  );

  for (final type in ExerciseType.values) {
    for (final source in WorkoutSource.values) {
      test('$type / $source round trips ids, UTC instants and estimates', () {
        final start = DateTime.parse('2026-11-16T10:00:00+05:30');
        final end = start.add(const Duration(minutes: 25));
        final session = WorkoutSession(
          type: type,
          source: source,
          startedAt: start,
          endedAt: end,
          measuredAt: end,
          steps: 3000,
          weightKg: 82.5,
          strideMeters: 0.82,
        );
        final row = workoutToRow(session, 'user-a');
        expect(row, {
          'id': session.id,
          'user_id': 'user-a',
          'type': type.name,
          'source': source.name,
          'started_at': '2026-11-16T04:30:00.000Z',
          'ended_at': '2026-11-16T04:55:00.000Z',
          'steps': 3000,
          'distance_m': session.distanceMeters,
          'calories': session.calories,
          'weight_kg': 82.5,
        });
        final restored = workoutFromRow(row);
        expect(restored.id, session.id);
        expect(restored.type, type);
        expect(restored.source, source);
        expect(restored.startedAt, start);
        expect(restored.endedAt, end);
        expect(restored.measuredAt, end);
        expect(restored.steps, session.steps);
        expect(restored.weightKg, session.weightKg);
        expect(restored.distanceMeters, session.distanceMeters);
        expect(restored.calories, session.calories);
        expect(restored.pace, session.pace);
      });
    }
  }

  test('numeric strings and absent weight preserve stored estimates', () {
    final row = workoutToRow(finishedWorkout(), 'user-a')
      ..['weight_kg'] = null
      ..['steps'] = 0
      ..['distance_m'] = '1250.25'
      ..['calories'] = '123.45';
    final session = workoutFromRow(row);
    expect(session.weightKg, 70);
    expect(session.distanceMeters, 1250.25);
    expect(session.calories, 123.45);
    expect(workoutToRow(session, 'user-a')['distance_m'], 1250.25);
  });

  test('mapping rejects active workouts and unknown exercise types', () {
    final active = WorkoutSession(
      type: ExerciseType.run,
      source: WorkoutSource.manual,
      startedAt: DateTime(2026),
      measuredAt: DateTime(2026),
      steps: 0,
    );
    expect(() => workoutToRow(active, 'user-a'), throwsArgumentError);
    final row = workoutToRow(finishedWorkout(), 'user-a')..['type'] = 'swim';
    expect(() => workoutFromRow(row), throwsArgumentError);
  });
}
