enum ActivityType { still, walking, running, cycling, unknown }

class ActivitySample {
  const ActivitySample({
    required this.type,
    required this.confidence,
    required this.timestamp,
  });

  final ActivityType type;
  final int confidence;
  final DateTime timestamp;
}

enum ExerciseType {
  walk('Walk', 3.5),
  run('Run', 9.8),
  bike('Bike', 7.5);

  const ExerciseType(this.label, this.met);

  final String label;
  final double met;

  static ExerciseType? fromActivity(ActivityType activity) =>
      switch (activity) {
        ActivityType.walking => walk,
        ActivityType.running => run,
        ActivityType.cycling => bike,
        _ => null,
      };

  List<ExerciseType> get alternatives => switch (this) {
    walk => const [run],
    run => const [walk],
    bike => const [],
  };
}

class StepSample {
  const StepSample({required this.count, required this.timestamp});

  final int count;
  final DateTime timestamp;
}
