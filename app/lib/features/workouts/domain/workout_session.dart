import 'activity_sample.dart';

enum WorkoutSource { auto, manual }

class WorkoutSession {
  const WorkoutSession({
    required this.type,
    required this.startedAt,
    required this.measuredAt,
    required this.steps,
    required this.source,
    this.endedAt,
    this.weightKg = 70,
    this.strideMeters = 0.75,
  });

  final ExerciseType type;
  final DateTime startedAt;
  final DateTime measuredAt;
  final DateTime? endedAt;
  final int steps;
  final WorkoutSource source;
  final double weightKg;
  final double strideMeters;

  Duration get duration => (endedAt ?? measuredAt).difference(startedAt);
  double get distanceMeters => steps * strideMeters;
  double get calories =>
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
