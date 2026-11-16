import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';
import 'package:wearable_companion/features/workouts/domain/workout_backfill.dart';

void main() {
  final file = File('test/fixtures/workout_motion_history.json');
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final origin = DateTime.utc(2026, 11, 15);
  DateTime at(int seconds) => origin.add(Duration(seconds: seconds));
  for (final item in fixture['cases'] as List) {
    final sample = item as Map<String, dynamic>;
    test('shared motion history golden: ${sample['name']}', () {
      final result = const WorkoutBackfill().replay(
        activities: [
          for (final row in sample['activities'] as List)
            ActivitySample(
              timestamp: at(row[0] as int),
              type: switch (row[1]) {
                'walking' => ActivityType.walking,
                'running' => ActivityType.running,
                'cycling' => ActivityType.cycling,
                'stationary' => ActivityType.still,
                _ => ActivityType.unknown,
              },
              confidence: switch (row[2]) {
                2 => 100,
                1 => 50,
                _ => 0,
              },
            ),
        ],
        steps: const [],
        from: origin,
        to: at(sample['to'] as int),
      );
      expect([
        for (final bout in result.candidates)
          [
            bout.type.name,
            bout.startedAt.difference(origin).inSeconds,
            bout.endedAt!.difference(origin).inSeconds,
          ],
      ], sample['bouts']);
      expect(
        result.checkedThrough.difference(origin).inSeconds,
        sample['checkedThrough'],
      );
    });
  }
}
