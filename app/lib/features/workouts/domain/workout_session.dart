import 'activity_sample.dart';
import 'workout_id.dart';

enum WorkoutSource { auto, manual }

class WorkoutSession {
  WorkoutSession({
    required this.type,
    required this.startedAt,
    required this.measuredAt,
    required this.steps,
    required this.source,
    this.endedAt,
    this.weightKg = 70,
    this.strideMeters = 0.75,
    String? id,
    this.recordedDistanceMeters,
    this.recordedCalories,
  }) : id = id ?? (endedAt == null ? null : newWorkoutId());

  /// Active snapshots have no id; finishing assigns one exactly once.
  final String? id;
  final ExerciseType type;
  final DateTime startedAt;
  final DateTime measuredAt;
  final DateTime? endedAt;
  final int steps;
  final WorkoutSource source;
  final double weightKg;
  final double strideMeters;
  final double? recordedDistanceMeters, recordedCalories;

  Duration get duration => (endedAt ?? measuredAt).difference(startedAt);
  double get distanceMeters => recordedDistanceMeters ?? steps * strideMeters;
  double get calories =>
      recordedCalories ??
      type.met *
          3.5 *
          weightKg /
          200 *
          (duration.inMilliseconds / Duration.millisecondsPerMinute);
  Duration? get pace => distanceMeters > 0
      ? Duration(
          milliseconds: (duration.inMilliseconds / (distanceMeters / 1000))
              .round(),
        )
      : null;
}
