import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/workout_backfill.dart';
import 'package:wearable_companion/features/workouts/domain/workout_session.dart';

void main() {
  final origin = DateTime.utc(2026, 11, 15, 9, 10);
  DateTime at(int minutes) => origin.add(Duration(minutes: minutes));
  ActivitySample activity(
    int minute,
    ActivityType type, {
    int confidence = 100,
  }) =>
      ActivitySample(type: type, confidence: confidence, timestamp: at(minute));
  BackfillResult replay(
    List<ActivitySample> activities, {
    List<WorkoutSession> existing = const [],
    int until = 60,
  }) => const WorkoutBackfill().replay(
    activities: activities,
    from: origin,
    to: at(until),
    existing: existing,
    steps: [
      for (var i = 0; i <= until; i++)
        StepSample(count: 1000 + i * 100, timestamp: at(i)),
    ],
  );

  test(
    'finds a completed walk, preserving onset, end, steps and auto source',
    () {
      final workout = replay([
        activity(0, ActivityType.walking),
        activity(35, ActivityType.still),
      ]).candidates.single;
      expect(workout.type, ExerciseType.walk);
      expect(workout.startedAt, origin);
      expect(workout.endedAt, at(35));
      expect(workout.steps, 3500);
      expect(workout.duration, const Duration(minutes: 35));
      expect(workout.source, WorkoutSource.auto);
      expect(workout.id, isNotNull);
    },
  );

  test('too short is ignored', () {
    expect(
      replay([
        activity(0, ActivityType.walking),
        activity(9, ActivityType.still),
      ]).candidates,
      isEmpty,
    );
  });

  test(
    'any saved overlap is ignored, including a manual boundary crossing',
    () {
      final saved = WorkoutSession(
        type: ExerciseType.run,
        startedAt: at(-10),
        endedAt: at(1),
        measuredAt: at(1),
        steps: 0,
        source: WorkoutSource.manual,
      );
      expect(
        replay(
          [activity(0, ActivityType.walking), activity(35, ActivityType.still)],
          existing: [saved],
        ).candidates,
        isEmpty,
      );
      final touching = WorkoutSession(
        type: ExerciseType.run,
        startedAt: at(-10),
        endedAt: origin,
        measuredAt: origin,
        steps: 0,
        source: WorkoutSource.manual,
      );
      expect(
        replay(
          [activity(0, ActivityType.walking), activity(35, ActivityType.still)],
          existing: [touching],
        ).candidates,
        hasLength(1),
      );
    },
  );

  test('medium and low confidence never meet the detector threshold', () {
    for (final confidence in [0, 50]) {
      expect(
        replay([
          activity(0, ActivityType.walking, confidence: confidence),
          activity(35, ActivityType.still),
        ]).candidates,
        isEmpty,
      );
    }
    expect(
      replay([
        activity(0, ActivityType.walking),
        activity(5, ActivityType.walking, confidence: 50),
        activity(35, ActivityType.still),
      ]).candidates,
      isEmpty,
    );
  });

  test('run uses its own three minute minimum and retains its type', () {
    expect(
      replay([
        activity(0, ActivityType.running),
        activity(4, ActivityType.still),
      ]).candidates.single.type,
      ExerciseType.run,
    );
    expect(
      replay([
        activity(0, ActivityType.walking),
        activity(4, ActivityType.still),
      ]).candidates,
      isEmpty,
    );
    expect(
      replay([
        activity(0, ActivityType.cycling),
        activity(5, ActivityType.still),
      ]).candidates.single.type,
      ExerciseType.bike,
    );
  });

  test(
    'gaps over a minute split bouts without the live dismissal cooldown',
    () {
      final workouts = replay([
        activity(0, ActivityType.walking),
        activity(12, ActivityType.still),
        activity(14, ActivityType.walking),
        activity(30, ActivityType.still),
      ]).candidates;
      expect(workouts, hasLength(2));
      expect(workouts.map((w) => w.duration.inMinutes), [12, 16]);
      expect(workouts.map((w) => w.steps), [1200, 1600]);
    },
  );

  test('brief gaps merge and a change of exercise splits', () {
    final workouts = replay([
      activity(0, ActivityType.walking),
      activity(11, ActivityType.still),
      activity(12, ActivityType.walking),
      activity(15, ActivityType.running),
      activity(20, ActivityType.still),
    ]).candidates;
    expect(workouts.map((w) => w.type), [ExerciseType.walk, ExerciseType.run]);
    expect(workouts.map((w) => w.duration.inMinutes), [15, 5]);
  });

  test(
    'an ongoing final state is retained for the next resume, not completed',
    () {
      final result = replay([activity(5, ActivityType.walking)]);
      expect(result.candidates, isEmpty);
      expect(result.checkedThrough, at(5));
    },
  );

  test('sorts change records and bounds a pre-window onset', () {
    final workout = replay([
      activity(35, ActivityType.still),
      activity(-5, ActivityType.walking),
    ]).candidates.single;
    expect(workout.startedAt, origin);
    expect(workout.steps, 3500);
  });
}
