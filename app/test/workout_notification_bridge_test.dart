import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/auto_workout_detector.dart';
import 'package:wearable_companion/features/workouts/domain/workout_notification_bridge.dart';

class FakeActions implements WorkoutPromptActions {
  final calls = <String>[];
  @override
  void acceptStart(ExerciseType type) => calls.add('start:${type.name}');
  @override
  void dismissStart() => calls.add('dismissStart');
  @override
  void acceptStop() => calls.add('acceptStop');
  @override
  void dismissStop() => calls.add('dismissStop');
}

class FakeNotifications implements WorkoutNotificationSink {
  final shown = <WorkoutPromptNotification>[];
  int cancellations = 0, permissions = 0, checks = 0;
  bool granted = true;
  Completer<bool>? permissionGate;
  late void Function(String, String?) action;
  @override
  Future<void> initialize(void Function(String, String?) onAction) async =>
      action = onAction;
  @override
  Future<bool> checkPermission() async {
    checks++;
    return permissionGate?.future ?? granted;
  }

  @override
  Future<bool> requestPermission() async {
    permissions++;
    return granted;
  }

  @override
  Future<void> show(WorkoutPromptNotification prompt) async =>
      shown.add(prompt);
  @override
  Future<void> cancel() async => cancellations++;
}

void main() {
  final now = DateTime.utc(2026, 11, 15, 10);
  final start = StartPrompt(
    type: ExerciseType.walk,
    activityStartedAt: now.subtract(const Duration(minutes: 10)),
    deadline: now.add(const Duration(minutes: 2)),
  );
  final stop = StopPrompt(deadline: now.add(const Duration(minutes: 2)));
  late FakeActions actions;
  late FakeNotifications sink;
  late WorkoutNotificationBridge bridge;
  Future<void> update({
    bool resumed = false,
    bool autoStart = true,
    bool autoStop = true,
    StartPrompt? start,
    StopPrompt? stop,
    DateTime? at,
  }) => bridge.update(
    resumed: resumed,
    autoStart: autoStart,
    autoStop: autoStop,
    now: at ?? now,
    start: start,
    stop: stop,
  );

  setUp(() {
    actions = FakeActions();
    sink = FakeNotifications();
    bridge = WorkoutNotificationBridge(sink: sink, actions: actions);
  });
  tearDown(() => bridge.dispose());

  test('initialization/foreground prompts never request permission', () async {
    await bridge.initialize();
    await update(resumed: true, start: start);
    expect(sink.permissions, 0);
    expect(sink.shown, isEmpty);
  });
  test(
    'shows a background prompt once and cancels on resolution and timeout',
    () async {
      await update(start: start);
      expect(sink.shown.single.title, 'Start Walk?');
      await update(start: start);
      expect(sink.shown, hasLength(1));
      final before = sink.cancellations;
      await update();
      expect(sink.cancellations, before + 1);
      await update(stop: stop);
      expect(sink.shown.last.title, 'Stop workout?');
      await update(stop: stop, at: stop.deadline);
      expect(sink.cancellations, before + 2);
      expect(sink.permissions, 0);
    },
  );
  test(
    'all four actions use the notifier interface; body tap leaves the sheet',
    () async {
      await update(start: start);
      final startKey = sink.shown.last.key;
      sink.action('', startKey);
      expect(actions.calls, isEmpty);
      sink.action('start', startKey);
      sink.action('not_now', startKey);
      await update(stop: stop);
      sink.action('stop', sink.shown.last.key);
      sink.action('keep_going', sink.shown.last.key);
      sink.action('start', startKey); // Stale notification.
      expect(actions.calls, [
        'start:walk',
        'dismissStart',
        'acceptStop',
        'dismissStop',
      ]);
    },
  );
  test(
    'toggles suppress prompts, cancel already displayed prompts and reject actions',
    () async {
      await update(start: start, autoStart: false);
      await update(stop: stop, autoStop: false);
      expect(sink.permissions, 0);
      expect(sink.shown, isEmpty);
      await update(start: start);
      final key = sink.shown.last.key;
      final before = sink.cancellations;
      await update(start: start, autoStart: false);
      sink.action('start', key);
      expect(sink.cancellations, before + 1);
      expect(actions.calls, isEmpty);
    },
  );
  test('returning to foreground cancels the notification', () async {
    await update(stop: stop);
    final before = sink.cancellations;
    await update(resumed: true, stop: stop);
    expect(sink.cancellations, before + 1);
  });
  test(
    'body taps request the workout screen without accepting the prompt',
    () async {
      var opens = 0;
      bridge.dispose();
      bridge = WorkoutNotificationBridge(
        sink: sink,
        actions: actions,
        onOpen: () => opens++,
      );
      await update(start: start);
      sink.action('', sink.shown.single.key);
      expect(opens, 1);
      expect(actions.calls, isEmpty);
    },
  );
  test(
    'resolution while permission is pending cannot display a stale prompt',
    () async {
      sink.permissionGate = Completer<bool>();
      final pending = update(start: start);
      await Future<void>.delayed(Duration.zero);
      final resolved = update();
      sink.permissionGate!.complete(true);
      await Future.wait([pending, resolved]);
      expect(sink.shown, isEmpty);
    },
  );
  test(
    'denial skips silently; permission is rechecked after resume without asking',
    () async {
      sink.granted = false;
      await update(start: start);
      await update(start: start);
      expect(sink.shown, isEmpty);
      expect(sink.checks, 2);
      expect(sink.permissions, 0);
      await update(resumed: true, start: start);
      sink.granted = true;
      await update(start: start);
      expect(sink.shown, hasLength(1));
      expect(sink.checks, 3);
      expect(sink.permissions, 0);
    },
  );
}
