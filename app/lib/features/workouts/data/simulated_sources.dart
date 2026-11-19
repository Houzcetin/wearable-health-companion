import 'dart:async';

import '../domain/activity_sample.dart';
import '../domain/auto_workout_detector.dart';
import 'activity_sources.dart';

/// The notifier advances this clock on each real 4-second simulator tick. Tests may
/// advance it directly. Prompts and metrics use the same accelerated time.
class SimulationClock {
  SimulationClock({required DateTime startedAt, this.timeAcceleration = 20})
    : _now = startedAt;

  final int timeAcceleration;
  DateTime _now;
  DateTime now() => _now;
  void advance(Duration realElapsed) {
    _now = _now.add(realElapsed * timeAcceleration);
  }
}

class SimulatedActivitySource extends ActivitySource {
  SimulatedActivitySource({required this.clock});
  final WorkoutClock clock;
  final _controller = StreamController<ActivitySample>.broadcast(sync: true);
  ActivityType type = ActivityType.still;

  @override
  Stream<ActivitySample> get samples => _controller.stream;

  void emit(ActivityType activity, {int confidence = 100}) {
    type = activity;
    _controller.add(
      ActivitySample(
        type: activity,
        confidence: confidence,
        timestamp: clock(),
      ),
    );
  }

  Future<void> dispose() => _controller.close();
}

class SimulatedStepSource extends StepSource {
  SimulatedStepSource({required this.clock});
  final WorkoutClock clock;
  final _controller = StreamController<StepSample>.broadcast(sync: true);
  int _count = 0;
  @override
  Stream<StepSample> get samples => _controller.stream;

  void emit(int cumulativeCount) {
    _count = cumulativeCount;
    _controller.add(StepSample(count: _count, timestamp: clock()));
  }

  void advance(ActivityType activity, Duration simulatedElapsed) {
    final perMinute = switch (activity) {
      ActivityType.walking => 100,
      ActivityType.running => 160,
      _ => 0,
    };
    emit(
      _count +
          (perMinute *
                  simulatedElapsed.inMilliseconds /
                  Duration.millisecondsPerMinute)
              .round(),
    );
  }

  Future<void> dispose() => _controller.close();
}
