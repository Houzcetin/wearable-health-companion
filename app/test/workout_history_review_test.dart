import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/data/motion_history_source.dart';
import 'package:wearable_companion/features/workouts/data/workout_history_review.dart';
import 'package:wearable_companion/features/workouts/data/workout_repository.dart';
import 'package:wearable_companion/features/workouts/data/workout_row.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/auto_workout_detector.dart';
import 'package:wearable_companion/features/workouts/domain/workout_session.dart';

import 'support/motion_history_fake.dart';
import 'support/workout_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final origin = DateTime.utc(2026, 11, 15, 9, 10);
  late DateTime now;
  late FakeMotionHistory source;
  late WorkoutRepository repository;
  WorkoutHistoryReview review({String owner = 'local'}) => WorkoutHistoryReview(
    source: source,
    repository: repository,
    owner: owner,
    clock: () => now,
    config: const DetectorConfig(),
  );
  setUp(() {
    now = origin.add(const Duration(hours: 1));
    source = FakeMotionHistory(origin);
    repository = InMemoryWorkoutRepository();
  });
  tearDown(() => repository.dispose());

  test(
    'cold start caps at 24h, persists pending reviews; Save uses async repository',
    () async {
      source.stored['local'] = {
        'checkpoint': now.subtract(const Duration(days: 5)).toIso8601String(),
      };
      final first = review();
      await first.check(enabled: true, weightKg: 80);
      expect(source.ranges.single.$1, now.subtract(const Duration(hours: 24)));
      final candidate = first.candidates.single;
      expect(candidate.steps, 3500);
      expect(candidate.weightKg, 80);
      final reopened = review();
      await reopened.check(enabled: true, weightKg: 70);
      expect(reopened.candidates.single.id, candidate.id);
      await reopened.resolve(reopened.candidates.single, save: true);
      expect(repository.sessions.single.id, candidate.id);
      expect(repository.sessions.single.source, WorkoutSource.auto);
      expect(source.cursorAdvances.single, candidate.endedAt);
      expect(source.stored['local']!['candidates'], isEmpty);
      await reopened.resolve(candidate, save: true);
      expect(repository.sessions, hasLength(1));
    },
  );

  test('Discard is persisted, and owner state is isolated', () async {
    final first = review();
    await first.check(enabled: true, weightKg: 70);
    await first.resolve(first.candidates.single, save: false);
    final reopened = review();
    await reopened.check(enabled: true, weightKg: 70);
    expect(reopened.candidates, isEmpty);
    expect(repository.sessions, isEmpty);
    expect(source.cursorAdvances, isEmpty);
    final other = review(owner: 'another-account');
    await other.check(enabled: true, weightKg: 70);
    expect(other.candidates, hasLength(1));
  });

  test('ongoing tail retains onset across resume checks', () async {
    now = origin.add(const Duration(minutes: 30));
    final controller = review();
    await controller.check(enabled: true, weightKg: 70);
    expect(controller.candidates, isEmpty);
    expect(source.stored['local']!['checkpoint'], origin.toIso8601String());
    now = origin.add(const Duration(hours: 1));
    await controller.check(enabled: true, weightKg: 70);
    expect(source.ranges.last.$1, origin);
    expect(controller.candidates.single.duration.inMinutes, 35);
  });

  test(
    'permission/query failures leave checkpoint available for retry',
    () async {
      source.fail = true;
      final controller = review();
      await expectLater(
        controller.check(enabled: true, weightKg: 70),
        throwsStateError,
      );
      expect(source.stored, isEmpty);
      source.fail = false;
      await controller.check(enabled: true, weightKg: 70);
      expect(controller.candidates, hasLength(1));
    },
  );

  test(
    'turning auto-start off clears reviews and skips historical queries',
    () async {
      final controller = review();
      await controller.check(enabled: true, weightKg: 70);
      await controller.check(enabled: false, weightKg: 70);
      expect(controller.candidates, isEmpty);
      expect(source.ranges, hasLength(1));
      expect(source.stored['local']!['checkpoint'], now.toIso8601String());
    },
  );

  test(
    'a saved workout that arrives after detection excludes a pending review',
    () async {
      final controller = review();
      await controller.check(enabled: true, weightKg: 70);
      await repository.save(controller.candidates.single);
      await controller.check(enabled: true, weightKg: 70);
      expect(controller.candidates, isEmpty);
    },
  );

  test(
    'loadRange covers from minus 24h through to, including crossing workouts',
    () async {
      repository.dispose();
      final store = FakeWorkoutStore();
      repository = SupabaseWorkoutRepository(store: store, userId: 'local');
      final crossing = WorkoutSession(
        type: ExerciseType.walk,
        startedAt: origin.subtract(const Duration(hours: 23)),
        endedAt: origin.add(const Duration(minutes: 1)),
        measuredAt: origin.add(const Duration(minutes: 1)),
        steps: 100,
        source: WorkoutSource.manual,
      );
      store.rows.add(workoutToRow(crossing, 'local'));
      source.stored['local'] = {'checkpoint': origin.toIso8601String()};
      final controller = review();
      await controller.check(enabled: true, weightKg: 70);
      expect(store.loads.single, (
        userId: 'local',
        from: origin.subtract(const Duration(hours: 24)),
        to: now,
      ));
      expect(controller.candidates, isEmpty);
      expect(source.stepRanges, isEmpty);
    },
  );

  test('cold-start repository load is bounded to 48h', () async {
    repository.dispose();
    final store = FakeWorkoutStore();
    repository = SupabaseWorkoutRepository(store: store, userId: 'local');
    await review().check(enabled: true, weightKg: 70);
    expect(store.loads.single.from, now.subtract(const Duration(hours: 48)));
    expect(store.loads.single.to, now);
  });

  test(
    'save errors do not block reviews; load errors keep the cursor for retry',
    () async {
      repository.dispose();
      final store = FakeWorkoutStore()..failInserts = true;
      repository = SupabaseWorkoutRepository(store: store, userId: 'local');
      await repository.save(
        finishedWorkout(start: origin.subtract(const Duration(hours: 2))),
      );
      expect(repository.lastError, isNotNull);
      expect(repository.loadError, isNull);
      final controller = review();
      store.failLoads = true;
      await controller.check(enabled: true, weightKg: 70);
      expect(repository.loadError, isNotNull);
      expect(source.ranges, isEmpty);
      expect(source.stored, isEmpty);
      store.failLoads = false;
      await controller.check(enabled: true, weightKg: 70);
      expect(repository.lastError, isNotNull);
      expect(repository.loadError, isNull);
      expect(controller.candidates, hasLength(1));
      expect(source.stored['local']!['checkpoint'], now.toIso8601String());
    },
  );

  test(
    'only eligible workout boundaries query steps, regardless of sample count',
    () async {
      source.activities = [
        for (var minute = 0; minute < 10; minute++)
          ActivitySample(
            type: ActivityType.still,
            confidence: 100,
            timestamp: origin.add(Duration(minutes: minute)),
          ),
        for (var minute = 10; minute < 45; minute++)
          ActivitySample(
            type: ActivityType.walking,
            confidence: 100,
            timestamp: origin.add(Duration(minutes: minute)),
          ),
        ActivitySample(
          type: ActivityType.still,
          confidence: 100,
          timestamp: origin.add(const Duration(minutes: 45)),
        ),
        for (var minute = 46; minute < 60; minute++)
          ActivitySample(
            type: ActivityType.running,
            confidence: 50,
            timestamp: origin.add(Duration(minutes: minute)),
          ),
      ];
      final controller = review();
      await controller.check(enabled: true, weightKg: 70);
      expect(controller.candidates, hasLength(1));
      expect(source.stepRanges, [
        (
          origin.add(const Duration(minutes: 10)),
          origin.add(const Duration(minutes: 45)),
        ),
      ]);
      expect(source.maxConcurrentStepQueries, 1);
    },
  );

  test(
    'idle, uncertain, short and unfinished activity never queries steps',
    () async {
      source.activities = [
        ActivitySample(
          type: ActivityType.unknown,
          confidence: 100,
          timestamp: origin,
        ),
        ActivitySample(
          type: ActivityType.walking,
          confidence: 50,
          timestamp: origin.add(const Duration(minutes: 1)),
        ),
        ActivitySample(
          type: ActivityType.walking,
          confidence: 100,
          timestamp: origin.add(const Duration(minutes: 20)),
        ),
        ActivitySample(
          type: ActivityType.still,
          confidence: 100,
          timestamp: origin.add(const Duration(minutes: 25)),
        ),
        ActivitySample(
          type: ActivityType.running,
          confidence: 100,
          timestamp: origin.add(const Duration(minutes: 40)),
        ),
      ];
      final controller = review();
      await controller.check(enabled: true, weightKg: 70);
      expect(controller.candidates, isEmpty);
      expect(source.stepRanges, isEmpty);
    },
  );

  test('active overlaps do not query steps or become reviews', () async {
    final controller = review();
    await controller.check(
      enabled: true,
      weightKg: 70,
      active: WorkoutSession(
        type: ExerciseType.walk,
        startedAt: origin,
        measuredAt: now,
        steps: 100,
        source: WorkoutSource.manual,
      ),
    );
    expect(controller.candidates, isEmpty);
    expect(source.stepRanges, isEmpty);
  });

  test('active markers expire after 15 minutes or 24 hours from onset', () {
    WorkoutSession snapshot({
      DateTime? from,
      DateTime? through,
      DateTime? end,
    }) => WorkoutSession(
      type: ExerciseType.walk,
      startedAt: from ?? origin,
      measuredAt: through ?? origin,
      endedAt: end,
      steps: 0,
      source: WorkoutSource.manual,
    );
    final active = snapshot();
    final expiry = origin.add(const Duration(minutes: 15));
    expect(active.isFreshActiveAt(expiry), isTrue);
    expect(
      active.isFreshActiveAt(expiry.add(const Duration(milliseconds: 1))),
      isFalse,
    );
    final cap = origin.add(const Duration(hours: 24));
    expect(snapshot(through: cap).isFreshActiveAt(cap), isTrue);
    final afterCap = cap.add(const Duration(milliseconds: 1));
    expect(snapshot(through: afterCap).isFreshActiveAt(afterCap), isFalse);
    expect(snapshot(through: now).isFreshActiveAt(origin), isFalse);
    expect(snapshot(from: now).isFreshActiveAt(now), isFalse);
    expect(snapshot(end: now).isFreshActiveAt(now), isFalse);
  });

  for (final age in [
    const Duration(minutes: 15),
    const Duration(minutes: 15, milliseconds: 1),
  ]) {
    test(
      'review ignores an active marker only while fresh (age $age)',
      () async {
        final controller = review();
        await controller.check(
          enabled: true,
          weightKg: 70,
          active: WorkoutSession(
            type: ExerciseType.walk,
            startedAt: origin,
            measuredAt: now.subtract(age),
            steps: 0,
            source: WorkoutSource.manual,
          ),
        );
        final expired = age > const Duration(minutes: 15);
        expect(controller.candidates, hasLength(expired ? 1 : 0));
        expect(source.stepRanges, hasLength(expired ? 1 : 0));
      },
    );
  }

  test(
    'a renewed marker older than 24 hours does not suppress a review',
    () async {
      final controller = review();
      await controller.check(
        enabled: true,
        weightKg: 70,
        active: WorkoutSession(
          type: ExerciseType.walk,
          startedAt: now.subtract(const Duration(hours: 24, milliseconds: 1)),
          measuredAt: now,
          steps: 0,
          source: WorkoutSource.manual,
        ),
      );
      expect(controller.candidates, hasLength(1));
    },
  );

  test(
    'step queries are sequential and bounded, retaining excess bouts for next check',
    () async {
      const total = WorkoutHistoryReview.maxStepQueriesPerCheck + 2;
      now = origin.add(const Duration(hours: 6));
      source.activities = [
        for (var i = 0; i < total; i++) ...[
          ActivitySample(
            type: ActivityType.running,
            confidence: 100,
            timestamp: origin.add(Duration(minutes: i * 6)),
          ),
          ActivitySample(
            type: ActivityType.still,
            confidence: 100,
            timestamp: origin.add(Duration(minutes: i * 6 + 3)),
          ),
        ],
      ];
      final controller = review();
      await controller.check(enabled: true, weightKg: 70);
      expect(
        source.stepRanges,
        hasLength(WorkoutHistoryReview.maxStepQueriesPerCheck),
      );
      expect(
        source.stored['local']!['checkpoint'],
        origin
            .add(
              const Duration(
                minutes: WorkoutHistoryReview.maxStepQueriesPerCheck * 6,
              ),
            )
            .toIso8601String(),
      );
      await controller.check(enabled: true, weightKg: 70);
      expect(controller.candidates, hasLength(total));
      expect(source.stepRanges, hasLength(total));
      expect(source.maxConcurrentStepQueries, 1);
    },
  );

  test(
    'workout cursor and active ranges use the existing native channel',
    () async {
      const channel = MethodChannel('test/workout_cursor');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final adapter = MotionHistorySource(channel: channel, available: true);
      await adapter.advanceRefreshCursor(now);
      await adapter.setActiveWorkout(
        WorkoutSession(
          type: ExerciseType.walk,
          startedAt: origin,
          measuredAt: now,
          steps: 0,
          source: WorkoutSource.manual,
        ),
      );
      await adapter.setActiveWorkout(null);
      expect(calls.map((call) => call.method), [
        'advanceRefreshCursor',
        'setActiveWorkout',
        'setActiveWorkout',
      ]);
      expect(calls[0].arguments, {'through': now.millisecondsSinceEpoch});
      expect(calls[1].arguments, {
        'from': origin.millisecondsSinceEpoch,
        'through': now.millisecondsSinceEpoch,
      });
      expect(calls[2].arguments, isEmpty);
    },
  );

  test(
    'native channel maps all confidence levels and step/distance totals',
    () async {
      const channel = MethodChannel('test/motion_history');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect((call.arguments as Map)['from'], origin.millisecondsSinceEpoch);
        if (call.method == 'querySteps') {
          return {'steps': 3200, 'distance': 2200.5};
        }
        return [
          for (var i = 0; i <= 2; i++)
            {
              'start': origin.millisecondsSinceEpoch,
              'walking': true,
              'confidence': i,
            },
          {
            'start': origin.millisecondsSinceEpoch,
            'walking': true,
            'automotive': true,
            'confidence': 2,
          },
        ];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final adapter = MotionHistorySource(channel: channel, available: true);
      final activities = await adapter.queryActivities(origin, now);
      expect(activities.map((a) => a.confidence), [0, 50, 100, 100]);
      expect(activities.last.type, ActivityType.unknown);
      final steps = await adapter.querySteps(origin, now);
      expect(steps.steps, 3200);
      expect(steps.distance, 2200.5);
      final unsupported = MotionHistorySource(
        channel: channel,
        available: false,
      );
      expect(await unsupported.queryActivities(origin, now), isEmpty);
      expect((await unsupported.querySteps(origin, now)).steps, 0);
    },
  );

  test(
    'native reminder open requests survive until Dart consumes them',
    () async {
      const channel = MethodChannel('test/history_open');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var pending = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'takeOpenRequest');
        final result = pending;
        pending = false;
        return result;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final adapter = MotionHistorySource(channel: channel, available: true);
      expect(await adapter.takeOpenRequest(), isTrue);
      expect(await adapter.takeOpenRequest(), isFalse);
      final delivered = <String>[];
      adapter.onOpen(() => delivered.add('open'));
      final completed = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('openHistory'),
        ),
        (_) => completed.complete(),
      );
      await completed.future;
      expect(delivered, ['open']);
      adapter.onOpen(null);
    },
  );
}
