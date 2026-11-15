import 'package:flutter/services.dart';
import 'package:flutter_activity_recognition/flutter_activity_recognition.dart'
    as ar;
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/data/activity_sources.dart';
import 'package:wearable_companion/features/workouts/data/simulated_sources.dart';
import 'package:wearable_companion/features/workouts/data/workout_repository.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/workout_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'phone activity maps OS types, confidence and observation time',
    () async {
      final now = DateTime(2026, 11, 16);
      final source = PhoneActivitySource(
        clock: () => now,
        requestPermission: () async => true,
        activityStream: () => Stream.fromIterable([
          const ar.Activity(
            ar.ActivityType.WALKING,
            ar.ActivityConfidence.HIGH,
          ),
          const ar.Activity(
            ar.ActivityType.RUNNING,
            ar.ActivityConfidence.MEDIUM,
          ),
          const ar.Activity(
            ar.ActivityType.ON_BICYCLE,
            ar.ActivityConfidence.HIGH,
          ),
          const ar.Activity(ar.ActivityType.STILL, ar.ActivityConfidence.HIGH),
          const ar.Activity(ar.ActivityType.UNKNOWN, ar.ActivityConfidence.LOW),
        ]),
      );
      final samples = await source.samples.toList();
      expect(samples.map((sample) => sample.type), [
        ActivityType.walking,
        ActivityType.running,
        ActivityType.cycling,
        ActivityType.still,
        ActivityType.unknown,
      ]);
      expect(samples.map((sample) => sample.confidence), [
        100,
        50,
        100,
        100,
        0,
      ]);
      expect(samples.every((sample) => sample.timestamp == now), isTrue);
    },
  );

  test('permission denial does not subscribe to phone streams', () async {
    var subscribed = false;
    final activity = PhoneActivitySource(
      clock: DateTime.now,
      requestPermission: () async => false,
      activityStream: () {
        subscribed = true;
        return const Stream.empty();
      },
    );
    final steps = PhoneStepSource(
      requestPermission: () async => false,
      stepStream: () {
        subscribed = true;
        return const Stream.empty();
      },
    );
    expect(await activity.samples.toList(), isEmpty);
    expect(await steps.samples.toList(), isEmpty);
    expect(subscribed, isFalse);
    expect(activity.unavailableReason, contains('permission denied'));
    expect(steps.unavailableReason, contains('permission denied'));
  });

  for (final error in [
    MissingPluginException(),
    PlatformException(code: 'sensor_unavailable'),
    UnsupportedError('desktop'),
  ]) {
    test('phone adapters safely handle ${error.runtimeType}', () async {
      Future<bool> unavailable() async => throw error;
      final activity = PhoneActivitySource(
        clock: DateTime.now,
        requestPermission: unavailable,
      );
      final steps = PhoneStepSource(requestPermission: unavailable);
      expect(await activity.samples.toList(), isEmpty);
      expect(await steps.samples.toList(), isEmpty);
      expect(activity.unavailableReason, isNotNull);
      expect(steps.unavailableReason, isNotNull);
    });
  }

  test(
    'platform activity stream errors are safe after permission is granted',
    () async {
      final source = PhoneActivitySource(
        clock: DateTime.now,
        requestPermission: () async => true,
        activityStream: () async* {
          throw PlatformException(code: 'unavailable');
        },
      );
      expect(await source.samples.toList(), isEmpty);
      expect(source.unavailableReason, contains('unavailable'));
    },
  );

  test(
    'simulator uses one accelerated clock for activity and cumulative steps',
    () async {
      final origin = DateTime(2026, 11, 16);
      final clock = SimulationClock(startedAt: origin);
      final activity = SimulatedActivitySource(clock: clock.now);
      final steps = SimulatedStepSource(clock: clock.now);
      final samples = <StepSample>[];
      final activities = <ActivitySample>[];
      final stepSubscription = steps.samples.listen(samples.add);
      final activitySubscription = activity.samples.listen(activities.add);
      steps.emit(0);
      activity.emit(ActivityType.walking);
      clock.advance(const Duration(seconds: 15));
      steps.advance(activity.type, const Duration(minutes: 5));
      expect(clock.now().difference(origin), const Duration(minutes: 5));
      expect(samples.last.count, 500);
      expect(activities.single.timestamp, origin);
      activity.emit(ActivityType.running);
      clock.advance(const Duration(seconds: 15));
      steps.advance(activity.type, const Duration(minutes: 5));
      expect(samples.last.count, 1300);
      activity.emit(ActivityType.still);
      steps.advance(activity.type, const Duration(minutes: 5));
      expect(samples.last.count, 1300);
      await stepSubscription.cancel();
      await activitySubscription.cancel();
      await activity.dispose();
      await steps.dispose();
    },
  );

  test('repository exposes an immutable snapshot', () {
    final repository = InMemoryWorkoutRepository();
    final before = repository.sessions;
    repository.save(
      WorkoutSession(
        type: ExerciseType.walk,
        startedAt: DateTime(2026),
        measuredAt: DateTime(2026),
        steps: 0,
        source: WorkoutSource.manual,
      ),
    );
    expect(before, isEmpty);
    expect(repository.sessions, hasLength(1));
    expect(() => repository.sessions.clear(), throwsUnsupportedError);
  });
}
