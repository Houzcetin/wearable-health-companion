import 'dart:async';

import 'activity_sample.dart';
import 'auto_workout_detector.dart';

abstract interface class WorkoutPromptActions {
  void acceptStart(ExerciseType type);
  void dismissStart();
  void acceptStop();
  void dismissStop();
}

class WorkoutPromptNotification {
  const WorkoutPromptNotification({
    required this.key,
    required this.title,
    required this.isStart,
    required this.remaining,
  });
  final String key, title;
  final bool isStart;
  final Duration remaining;
}

abstract interface class WorkoutNotificationSink {
  Future<void> initialize(void Function(String action, String? key) onAction);
  Future<bool> checkPermission();
  Future<bool> requestPermission();
  Future<void> show(WorkoutPromptNotification prompt);
  Future<void> cancel();
}

/// No plugin or Riverpod dependency: the bridge always checks the latest prompt
/// after async permission checks, and rejects actions from old notifications.
class WorkoutNotificationBridge {
  WorkoutNotificationBridge({
    required this.sink,
    required this.actions,
    this.onOpen,
  });
  final WorkoutNotificationSink sink;
  final WorkoutPromptActions actions;
  final void Function()? onOpen;
  StartPrompt? _start;
  StopPrompt? _stop;
  WorkoutPromptNotification? _desired;
  String? _shown;
  bool _disposed = false;
  Future<void>? _initialization;
  Future<void> _queue = Future.value();

  Future<void> initialize() => _initialization ??= () async {
    await sink.initialize(handleAction);
    await sink.cancel(); // Clear live prompts left by a terminated process.
  }();

  Future<void> update({
    required bool resumed,
    required bool autoStart,
    required bool autoStop,
    required DateTime now,
    StartPrompt? start,
    StopPrompt? stop,
  }) {
    _start = autoStart && start != null && now.isBefore(start.deadline)
        ? start
        : null;
    _stop = autoStop && stop != null && now.isBefore(stop.deadline)
        ? stop
        : null;
    final prompt = _start ?? _stop;
    _desired = resumed || prompt == null
        ? null
        : WorkoutPromptNotification(
            key: _start != null
                ? 'start:${_start!.activityStartedAt.microsecondsSinceEpoch}:${_start!.deadline.microsecondsSinceEpoch}'
                : 'stop:${_stop!.deadline.microsecondsSinceEpoch}',
            title: _start != null
                ? 'Start ${_start!.type.label}?'
                : 'Stop workout?',
            isStart: _start != null,
            remaining: (_start?.deadline ?? _stop!.deadline).difference(now),
          );
    _queue = _queue.then((_) => _sync()).catchError((Object _) {});
    return _queue;
  }

  Future<void> _sync() async {
    await initialize();
    if (_disposed) return;
    final desired = _desired;
    if (desired?.key == _shown) return;
    if (_shown != null) {
      await sink.cancel();
      _shown = null;
    }
    if (desired == null) return;
    // Never prompt here, and never retain a denial across resumes/settings
    // changes. The settings button is the only permission request path.
    final permitted = await sink.checkPermission();
    if (!permitted || _disposed || _desired?.key != desired.key) {
      return;
    }
    await sink.show(desired);
    _shown = desired.key;
    // A resolution during show() is handled by the next queued update.
  }

  void handleAction(String action, String? key) {
    if (_disposed || key == null) return;
    if (action.isEmpty) {
      onOpen?.call();
      return;
    }
    final start = _start;
    final startKey = start == null
        ? null
        : 'start:${start.activityStartedAt.microsecondsSinceEpoch}:${start.deadline.microsecondsSinceEpoch}';
    final stopKey = _stop == null
        ? null
        : 'stop:${_stop!.deadline.microsecondsSinceEpoch}';
    if (key == startKey && start != null) {
      if (action == 'start') actions.acceptStart(start.type);
      if (action == 'not_now') actions.dismissStart();
    } else if (key == stopKey && _stop != null) {
      if (action == 'stop') actions.acceptStop();
      if (action == 'keep_going') actions.dismissStop();
    }
    // A body tap leaves state alone; the foreground host displays the sheet.
  }

  void dispose() {
    _disposed = true;
    unawaited(_queue.then((_) => sink.cancel()).catchError((Object _) {}));
  }
}
