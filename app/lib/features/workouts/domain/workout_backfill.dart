import 'activity_sample.dart';
import 'auto_workout_detector.dart';
import 'workout_session.dart';

/// CoreMotion records are changes of state, not periodic heartbeats. The final
/// state continues to [to]; an ongoing bout is never offered as completed.
class WorkoutBackfill {
  const WorkoutBackfill({this.config = const DetectorConfig()});
  final DetectorConfig config;

  BackfillResult replay({
    required List<ActivitySample> activities,
    required List<StepSample> steps,
    required DateTime from,
    required DateTime to,
    Iterable<WorkoutSession> existing = const [],
    double weightKg = 70,
  }) {
    final ordered = activities.where((a) => !a.timestamp.isAfter(to)).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final counts = steps.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final candidates = <WorkoutSession>[];
    DateTime? start, end;
    ExerciseType? type;
    var toleratedUncertainGap = false;
    var awaitingUncertainReturn = false;
    final ignored = <ActivitySample>{};
    var checkedThrough = to;

    void finish() {
      final boutStart = start;
      final boutEnd = end;
      final boutType = type;
      if (boutStart == null || boutEnd == null || boutType == null) return;
      // A fresh detector for each bout avoids the live dismissal cooldown
      // hiding a second historical workout. Replay its normal start threshold
      // and inactivity/stop timeout with a deterministic clock.
      var now = boutStart;
      final detector = AutoWorkoutDetector(clock: () => now, config: config)
        ..weightKg = weightKg;
      detector.addSteps(
        StepSample(count: _countAt(counts, now), timestamp: now),
      );
      detector.addActivity(
        ActivitySample(
          type: _activity(boutType),
          confidence: 100,
          timestamp: now,
        ),
      );
      final threshold = boutStart.add(config.startAfter(boutType));
      if (threshold.isAfter(boutEnd)) return;
      final points = <DateTime>{
        threshold,
        boutEnd,
        ...ordered
            .where(
              (s) =>
                  s.timestamp.isAfter(boutStart) &&
                  s.timestamp.isBefore(boutEnd),
            )
            .map((s) => s.timestamp),
        ...counts
            .where(
              (s) =>
                  s.timestamp.isAfter(boutStart) &&
                  !s.timestamp.isAfter(boutEnd),
            )
            .map((s) => s.timestamp),
      }.toList()..sort();
      var activityIndex = 0;
      var stepIndex = 0;
      void tick() {
        detector.tick();
        if (detector.startPrompt != null) detector.acceptStart(boutType);
      }

      for (final point in points) {
        now = point;
        tick();
        while (stepIndex < counts.length &&
            !counts[stepIndex].timestamp.isAfter(now)) {
          final sample = counts[stepIndex++];
          if (sample.timestamp.isAfter(boutStart)) detector.addSteps(sample);
        }
        while (activityIndex < ordered.length &&
            !ordered[activityIndex].timestamp.isAfter(now)) {
          final sample = ordered[activityIndex++];
          if (!ignored.contains(sample) &&
              sample.timestamp.isAfter(boutStart) &&
              sample.timestamp.isBefore(boutEnd)) {
            detector.addActivity(
              ActivitySample(
                type: sample.confidence >= config.minConfidence
                    ? sample.type
                    : ActivityType.unknown,
                confidence: 100,
                timestamp: sample.timestamp,
              ),
            );
          }
        }
        tick();
      }
      now = boutEnd;
      detector.addActivity(
        ActivitySample(
          type: ActivityType.still,
          confidence: 100,
          timestamp: now,
        ),
      );
      now = now.add(config.stopAfterStill);
      detector.tick();
      now = now.add(config.stopPromptTimeout);
      detector.tick();
      final session = detector.finishedSession;
      if (session != null &&
          !existing.any((saved) => workoutsOverlap(saved, session))) {
        candidates.add(session);
      }
    }

    for (var i = 0; i < ordered.length; i++) {
      final sample = ordered[i];
      final at = sample.timestamp.isBefore(from) ? from : sample.timestamp;
      // Match Swift: bridge one uncertain record lasting at most two minutes,
      // only when high-confidence movement resumes with the same exercise.
      if (type != null &&
          end == null &&
          !toleratedUncertainGap &&
          sample.confidence < config.minConfidence &&
          i + 1 < ordered.length) {
        final following = ordered[i + 1];
        final nextAt = following.timestamp.isBefore(from)
            ? from
            : following.timestamp;
        if (following.confidence >= config.minConfidence &&
            ExerciseType.fromActivity(following.type) == type &&
            nextAt.difference(at) <= const Duration(minutes: 2)) {
          ignored.add(sample);
          toleratedUncertainGap = true;
          continue;
        }
      }
      // An uncertain interval breaks continuity; the live detector ignores low
      // confidence events, which would otherwise extend old movement forever.
      final next = sample.confidence >= config.minConfidence
          ? ExerciseType.fromActivity(sample.type)
          : null;
      if (next != null) {
        if (type != next ||
            (end != null && at.difference(end) > config.briefGapTolerance)) {
          if (type != null) end ??= at;
          finish();
          start = at;
          type = next;
          toleratedUncertainGap = false;
        }
        end = null;
        awaitingUncertainReturn = false;
      } else if (type != null) {
        awaitingUncertainReturn =
            end == null &&
            !toleratedUncertainGap &&
            sample.confidence < config.minConfidence;
        end ??= at;
      }
    }
    if (start != null) {
      final tailTolerance = awaitingUncertainReturn
          ? const Duration(minutes: 2)
          : config.briefGapTolerance;
      if (end != null && to.difference(end) > tailTolerance) {
        finish();
      } else {
        // Re-query the unfinished tail next time, including its original onset.
        checkedThrough = start;
      }
    }
    return BackfillResult(candidates, checkedThrough);
  }

  static int _countAt(List<StepSample> steps, DateTime at) {
    for (final sample in steps.reversed) {
      if (!sample.timestamp.isAfter(at)) return sample.count;
    }
    return 0;
  }

  static ActivityType _activity(ExerciseType type) => switch (type) {
    ExerciseType.walk => ActivityType.walking,
    ExerciseType.run => ActivityType.running,
    ExerciseType.bike => ActivityType.cycling,
  };
}

class BackfillResult {
  const BackfillResult(this.candidates, this.checkedThrough);
  final List<WorkoutSession> candidates;
  final DateTime checkedThrough;
}

bool workoutsOverlap(WorkoutSession a, WorkoutSession b) =>
    a.startedAt.isBefore(b.endedAt ?? b.measuredAt) &&
    b.startedAt.isBefore(a.endedAt ?? a.measuredAt);
