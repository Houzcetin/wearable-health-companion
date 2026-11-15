import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/auto_workout_detector.dart';
import 'package:wearable_companion/features/workouts/domain/workout_session.dart';

void main() {
  late DateTime now;
  late DateTime origin;
  late AutoWorkoutDetector detector;

  void advance(Duration elapsed) {
    now = now.add(elapsed);
    detector.tick();
  }

  void activity(ActivityType type, {int confidence = 100}) =>
      detector.addActivity(
        ActivitySample(type: type, confidence: confidence, timestamp: now),
      );
  void steps(int count) =>
      detector.addSteps(StepSample(count: count, timestamp: now));
  void prompt([ActivityType type = ActivityType.walking]) {
    activity(type);
    advance(detector.config.startAfter(ExerciseType.fromActivity(type)!));
    expect(detector.phase, DetectorPhase.promptingStart);
  }

  void start() {
    prompt();
    detector.acceptStart(ExerciseType.walk);
  }

  setUp(() {
    origin = now = DateTime(2026, 11, 16, 12);
    detector = AutoWorkoutDetector(clock: () => now);
  });

  test('mapping, alternatives and MET constants', () {
    expect(ExerciseType.fromActivity(ActivityType.walking), ExerciseType.walk);
    expect(ExerciseType.fromActivity(ActivityType.running), ExerciseType.run);
    expect(ExerciseType.fromActivity(ActivityType.cycling), ExerciseType.bike);
    expect(ExerciseType.fromActivity(ActivityType.still), isNull);
    expect(ExerciseType.fromActivity(ActivityType.unknown), isNull);
    expect(ExerciseType.walk.alternatives, [ExerciseType.run]);
    expect(ExerciseType.run.alternatives, [ExerciseType.walk]);
    expect(ExerciseType.bike.alternatives, isEmpty);
    expect(ExerciseType.values.map((type) => type.met), [3.5, 9.8, 7.5]);
  });

  for (final entry in {
    ActivityType.walking: const Duration(minutes: 10),
    ActivityType.running: const Duration(minutes: 3),
    ActivityType.cycling: const Duration(minutes: 5),
  }.entries) {
    test('${entry.key} needs sustained activity before a prompt', () {
      activity(entry.key);
      advance(entry.value - const Duration(seconds: 1));
      expect(detector.phase, DetectorPhase.candidate);
      advance(const Duration(seconds: 1));
      expect(detector.phase, DetectorPhase.promptingStart);
      expect(detector.takeEvents().single, isA<StartPrompt>());
    });
  }

  test('low confidence is ignored, including a low-confidence still', () {
    activity(ActivityType.walking, confidence: 74);
    advance(const Duration(minutes: 10));
    expect(detector.phase, DetectorPhase.idle);
    activity(ActivityType.walking, confidence: 75);
    activity(ActivityType.still, confidence: 20);
    advance(const Duration(minutes: 10));
    expect(detector.phase, DetectorPhase.promptingStart);
  });

  test(
    'a brief gap including exactly 60 seconds preserves the first sample',
    () {
      activity(ActivityType.walking);
      advance(const Duration(minutes: 6));
      activity(ActivityType.still);
      advance(const Duration(seconds: 60));
      activity(ActivityType.walking);
      advance(const Duration(minutes: 3));
      expect(detector.startPrompt!.activityStartedAt, origin);
    },
  );

  test('a long gap resets the candidate even with no new samples', () {
    activity(ActivityType.walking);
    advance(const Duration(minutes: 6));
    activity(ActivityType.still);
    advance(const Duration(seconds: 61));
    expect(detector.phase, DetectorPhase.idle);
    final resumed = now;
    activity(ActivityType.walking);
    advance(const Duration(minutes: 10));
    expect(detector.startPrompt!.activityStartedAt, resumed);
  });

  test('unknown activity creates a gap rather than sustaining a candidate', () {
    activity(ActivityType.walking);
    activity(ActivityType.unknown);
    advance(const Duration(minutes: 10));
    expect(detector.phase, DetectorPhase.idle);
  });

  test('changing activity type restarts the candidate', () {
    activity(ActivityType.walking);
    advance(const Duration(minutes: 9));
    activity(ActivityType.running);
    final runStart = now;
    advance(const Duration(minutes: 3));
    expect(detector.startPrompt!.type, ExerciseType.run);
    expect(detector.startPrompt!.activityStartedAt, runStart);
  });

  test('a still transition at the threshold does not emit a stale prompt', () {
    activity(ActivityType.walking);
    now = now.add(const Duration(minutes: 10));
    activity(ActivityType.still);
    expect(detector.phase, DetectorPhase.candidate);
    expect(detector.takeEvents(), isEmpty);
  });

  test(
    'start prompt timeout is deterministic and late accept does nothing',
    () {
      prompt();
      advance(const Duration(minutes: 2));
      expect(detector.phase, DetectorPhase.idle);
      expect(detector.startPrompt, isNull);
      detector.acceptStart(ExerciseType.walk);
      expect(detector.currentSession, isNull);
    },
  );

  test('dismiss cooldown suppresses prompts for 30 minutes', () {
    prompt();
    detector.dismissStart();
    advance(const Duration(minutes: 29));
    activity(ActivityType.running);
    expect(detector.phase, DetectorPhase.idle);
    advance(const Duration(minutes: 1));
    prompt(ActivityType.running);
    expect(detector.startPrompt!.type, ExerciseType.run);
  });

  test('accepting backdates to the first sample and emits WorkoutStarted', () {
    prompt();
    detector.takeEvents();
    advance(const Duration(seconds: 30));
    detector.acceptStart(ExerciseType.walk);
    expect(detector.currentSession!.startedAt, origin);
    expect(
      detector.currentSession!.duration,
      const Duration(minutes: 10, seconds: 30),
    );
    expect(detector.currentSession!.source, WorkoutSource.auto);
    expect(detector.takeEvents().single, isA<WorkoutStarted>());
  });

  test('alternative type works and unsupported choices are ignored', () {
    prompt();
    detector.acceptStart(ExerciseType.bike);
    expect(detector.phase, DetectorPhase.promptingStart);
    detector.acceptStart(ExerciseType.run);
    expect(detector.currentSession!.type, ExerciseType.run);
    expect(detector.currentSession!.startedAt, origin);
  });

  test(
    'five minutes still triggers stop; movement cancels and restarts it',
    () {
      start();
      activity(ActivityType.still);
      advance(const Duration(minutes: 4, seconds: 59));
      expect(detector.phase, DetectorPhase.active);
      advance(const Duration(seconds: 1));
      expect(detector.phase, DetectorPhase.promptingStop);
      activity(ActivityType.walking);
      expect(detector.phase, DetectorPhase.active);
      expect(detector.stopPrompt, isNull);
      advance(const Duration(minutes: 10));
      expect(detector.phase, DetectorPhase.active);
      activity(ActivityType.still);
      advance(const Duration(minutes: 5));
      expect(detector.phase, DetectorPhase.promptingStop);
    },
  );

  test(
    'timed out stop ends at the last movement and trims steps at that time',
    () {
      steps(1000);
      start();
      steps(2000);
      activity(ActivityType.still);
      final lastMovement = now;
      advance(const Duration(minutes: 5));
      advance(const Duration(minutes: 2));
      final session = detector.finishedSession!;
      expect(detector.phase, DetectorPhase.finished);
      expect(session.endedAt, lastMovement);
      expect(session.duration, const Duration(minutes: 10));
      expect(session.steps, 1000);
      expect(detector.takeEvents().last, isA<WorkoutFinished>());
    },
  );

  test(
    'pedometer movement cancels a stop prompt even while OS reports still',
    () {
      steps(100);
      start();
      activity(ActivityType.still);
      advance(const Duration(minutes: 5));
      steps(101);
      expect(detector.phase, DetectorPhase.active);
      final movement = now;
      advance(const Duration(minutes: 5));
      advance(const Duration(minutes: 2));
      expect(detector.finishedSession!.endedAt, movement);
    },
  );

  test('dismiss stop restarts inactivity without moving the last movement', () {
    start();
    activity(ActivityType.still);
    final movement = now;
    advance(const Duration(minutes: 5));
    detector.dismissStop();
    advance(const Duration(minutes: 4));
    expect(detector.phase, DetectorPhase.active);
    advance(const Duration(minutes: 1));
    advance(const Duration(minutes: 2));
    expect(detector.finishedSession!.endedAt, movement);
  });

  test('steps include the pre-prompt interval and counter resets', () {
    steps(1000);
    activity(ActivityType.walking);
    advance(const Duration(minutes: 10));
    steps(2000);
    detector.acceptStart(ExerciseType.walk);
    expect(detector.currentSession!.steps, 1000);
    advance(const Duration(seconds: 15));
    steps(20);
    expect(detector.currentSession!.steps, 1020);
    advance(const Duration(seconds: 15));
    steps(50);
    expect(detector.currentSession!.steps, 1050);
  });

  test(
    'late first step reading becomes the baseline instead of device lifetime steps',
    () {
      start();
      steps(50000);
      expect(detector.currentSession!.steps, 0);
      advance(const Duration(seconds: 15));
      steps(50020);
      expect(detector.currentSession!.steps, 20);
    },
  );

  test('manual actions use current time and manual source', () {
    detector.manualStart(ExerciseType.bike);
    advance(const Duration(minutes: 1));
    detector.manualStop();
    expect(detector.finishedSession!.startedAt, origin);
    expect(detector.finishedSession!.endedAt, now);
    expect(detector.finishedSession!.source, WorkoutSource.manual);
  });

  test(
    'disabled prompt toggles suppress transitions and cancel open prompts',
    () {
      detector.autoStartPrompts = false;
      activity(ActivityType.walking);
      advance(const Duration(minutes: 10));
      expect(detector.phase, DetectorPhase.idle);
      detector.autoStartPrompts = true;
      start();
      activity(ActivityType.still);
      advance(const Duration(minutes: 5));
      detector.autoStopPrompts = false;
      advance(const Duration(minutes: 20));
      expect(detector.phase, DetectorPhase.active);
      expect(detector.stopPrompt, isNull);
    },
  );

  test('future and out of order sensor samples are rejected', () {
    detector.addActivity(
      ActivitySample(
        type: ActivityType.walking,
        confidence: 100,
        timestamp: now.add(const Duration(seconds: 1)),
      ),
    );
    expect(detector.phase, DetectorPhase.idle);
    activity(ActivityType.walking);
    advance(const Duration(minutes: 1));
    activity(ActivityType.walking);
    detector.addActivity(
      ActivitySample(
        type: ActivityType.running,
        confidence: 100,
        timestamp: origin,
      ),
    );
    expect(detector.candidateType, ExerciseType.walk);
    steps(100);
    detector.addSteps(StepSample(count: 10000, timestamp: origin));
    detector.acceptStart(ExerciseType.walk);
    advance(const Duration(minutes: 9));
    detector.acceptStart(ExerciseType.walk);
    expect(detector.currentSession!.steps, 0);
  });

  for (final type in ExerciseType.values) {
    test('$type distance, calories, pace and default weight math', () {
      final session = WorkoutSession(
        type: type,
        startedAt: origin,
        measuredAt: origin.add(const Duration(hours: 1)),
        steps: 4000,
        source: WorkoutSource.auto,
      );
      expect(session.distanceMeters, 3000);
      expect(session.weightKg, 70);
      expect(session.calories, closeTo(type.met * 3.5 * 70 / 200 * 60, 0.001));
      expect(session.pace, const Duration(minutes: 20));
    });
  }

  test('zero distance has no pace and weight is captured at workout start', () {
    detector.weightKg = 80;
    start();
    detector.weightKg = 100;
    expect(detector.currentSession!.weightKg, 80);
    expect(detector.currentSession!.pace, isNull);
  });
}
