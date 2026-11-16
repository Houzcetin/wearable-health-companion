import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/data/motion_history_source.dart';
import 'package:wearable_companion/features/workouts/data/workout_history_review.dart';
import 'package:wearable_companion/features/workouts/data/workout_repository.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/auto_workout_detector.dart';
import 'package:wearable_companion/features/workouts/domain/workout_session.dart';

import 'support/motion_history_fake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final origin = DateTime.utc(2026, 11, 15, 9, 10);
  late DateTime now;
  late FakeMotionHistory source;
  late InMemoryWorkoutRepository repository;
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
