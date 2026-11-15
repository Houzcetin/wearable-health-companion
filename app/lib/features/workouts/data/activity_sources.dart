import 'package:flutter/services.dart';
import 'package:flutter_activity_recognition/flutter_activity_recognition.dart'
    as ar;
import 'package:pedometer/pedometer.dart';

import '../domain/activity_sample.dart';
import '../domain/auto_workout_detector.dart';

abstract class ActivitySource {
  Stream<ActivitySample> get samples;
  String? get unavailableReason => null;
}

abstract class StepSource {
  Stream<StepSample> get samples;
  String? get unavailableReason => null;
}

/// Shared by both adapters so the pedometer cannot race the permission dialog.
class MotionPermission {
  Future<bool>? _pending;

  Future<bool> request() =>
      _pending ??= _request().whenComplete(() => _pending = null);

  Future<bool> _request() async {
    final plugin = ar.FlutterActivityRecognition.instance;
    var permission = await plugin.checkPermission();
    if (permission == ar.ActivityPermission.DENIED) {
      permission = await plugin.requestPermission();
    }
    return permission == ar.ActivityPermission.GRANTED;
  }
}

class UnavailableActivitySource extends ActivitySource {
  @override
  Stream<ActivitySample> get samples => const Stream.empty();
  @override
  String get unavailableReason =>
      'Phone sensors unavailable. Try the simulator in Settings.';
}

class UnavailableStepSource extends StepSource {
  @override
  Stream<StepSample> get samples => const Stream.empty();
}

class PhoneActivitySource extends ActivitySource {
  PhoneActivitySource({
    required this.clock,
    required this.requestPermission,
    Stream<ar.Activity> Function()? activityStream,
  }) : _activityStream =
           activityStream ??
           (() => ar.FlutterActivityRecognition.instance.activityStream);
  final WorkoutClock clock;
  final Future<bool> Function() requestPermission;
  final Stream<ar.Activity> Function() _activityStream;
  @override
  String? unavailableReason;

  @override
  Stream<ActivitySample> get samples async* {
    unavailableReason = null;
    try {
      if (!await requestPermission()) {
        unavailableReason =
            'Motion permission denied. Enable it in your phone settings or use the simulator.';
        return;
      }
      await for (final activity in _activityStream()) {
        yield ActivitySample(
          type: switch (activity.type) {
            ar.ActivityType.WALKING => ActivityType.walking,
            ar.ActivityType.RUNNING => ActivityType.running,
            ar.ActivityType.ON_BICYCLE => ActivityType.cycling,
            ar.ActivityType.STILL => ActivityType.still,
            _ => ActivityType.unknown,
          },
          confidence: switch (activity.confidence) {
            ar.ActivityConfidence.HIGH => 100,
            ar.ActivityConfidence.MEDIUM => 50,
            ar.ActivityConfidence.LOW => 0,
          },
          // This plugin exposes no native onset/boot timestamp. The first
          // observed sample is the earliest start we can faithfully preserve.
          timestamp: clock(),
        );
      }
    } on MissingPluginException {
      unavailableReason =
          'Phone sensors unavailable. Try the simulator in Settings.';
    } on PlatformException {
      unavailableReason =
          'Motion sensor unavailable. Try the simulator in Settings.';
    } on UnsupportedError {
      unavailableReason =
          'Motion sensor unsupported. Try the simulator in Settings.';
    }
  }
}

class PhoneStepSource extends StepSource {
  PhoneStepSource({
    required this.requestPermission,
    Stream<StepCount> Function()? stepStream,
  }) : _stepStream = stepStream ?? (() => Pedometer.stepCountStream);

  final Future<bool> Function() requestPermission;
  final Stream<StepCount> Function() _stepStream;
  @override
  String? unavailableReason;

  @override
  Stream<StepSample> get samples async* {
    unavailableReason = null;
    try {
      if (!await requestPermission()) {
        unavailableReason =
            'Motion permission denied. Enable it in your phone settings or use the simulator.';
        return;
      }
      await for (final event in _stepStream()) {
        yield StepSample(count: event.steps, timestamp: event.timeStamp);
      }
    } on MissingPluginException {
      unavailableReason = 'Step sensor unavailable.';
    } on PlatformException {
      unavailableReason = 'Step sensor unavailable or permission denied.';
    } on UnsupportedError {
      unavailableReason = 'Step sensor unsupported.';
    }
  }
}
