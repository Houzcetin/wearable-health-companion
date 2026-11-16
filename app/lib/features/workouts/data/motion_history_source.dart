import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/activity_sample.dart';

class HistorySteps {
  const HistorySteps(this.steps, {this.distance});
  final int steps;
  final double? distance;
}

/// This channel also stores the checkpoint and pending reviews in UserDefaults.
/// No history plugin or preferences dependency is needed on other platforms.
class MotionHistorySource {
  MotionHistorySource({MethodChannel? channel, bool? available})
    : channel = channel ?? const MethodChannel('workouts/motion_history'),
      available =
          available ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  final MethodChannel channel;
  final bool available;

  void onOpen(void Function()? callback) {
    if (!available) return;
    channel.setMethodCallHandler(
      callback == null
          ? null
          : (call) async {
              if (call.method == 'openHistory') callback();
            },
    );
  }

  Future<bool> takeOpenRequest() async =>
      available &&
      (await channel.invokeMethod<bool>('takeOpenRequest') ?? false);

  Map<String, Object> _range(DateTime from, DateTime to) => {
    'from': from.millisecondsSinceEpoch,
    'to': to.millisecondsSinceEpoch,
  };

  Future<List<ActivitySample>> queryActivities(
    DateTime from,
    DateTime to,
  ) async {
    if (!available) return [];
    final rows =
        await channel.invokeListMethod<Map<Object?, Object?>>(
          'queryActivities',
          _range(from, to),
        ) ??
        [];
    return rows
        .map(
          (row) => ActivitySample(
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              (row['start'] as num).toInt(),
            ),
            type: switch (row) {
              {'automotive': true} => ActivityType.unknown,
              {'running': true} => ActivityType.running,
              {'cycling': true} => ActivityType.cycling,
              {'walking': true} => ActivityType.walking,
              {'stationary': true} => ActivityType.still,
              _ => ActivityType.unknown,
            },
            confidence: switch (row['confidence']) {
              2 => 100,
              1 => 50,
              _ => 0,
            },
          ),
        )
        .toList();
  }

  Future<HistorySteps> querySteps(DateTime from, DateTime to) async {
    if (!available) return const HistorySteps(0);
    final row =
        await channel.invokeMapMethod<String, Object?>(
          'querySteps',
          _range(from, to),
        ) ??
        {};
    return HistorySteps(
      (row['steps'] as num?)?.toInt() ?? 0,
      distance: (row['distance'] as num?)?.toDouble(),
    );
  }

  Future<Map<String, dynamic>> readState(String owner) async {
    if (!available) return {};
    return Map<String, dynamic>.from(
      await channel.invokeMapMethod<String, dynamic>('readState', {
            'owner': owner,
          }) ??
          {},
    );
  }

  Future<void> writeState(String owner, Map<String, dynamic> state) async {
    if (available) {
      await channel.invokeMethod<void>('writeState', {
        'owner': owner,
        'state': state,
      });
    }
  }

  Future<void> configure({required bool enabled}) async {
    if (available) {
      await channel.invokeMethod<void>('configure', {'enabled': enabled});
    }
  }
}
