import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wearable_companion/features/workouts/data/pending_workout_queue.dart';
import 'package:wearable_companion/features/workouts/data/workout_row.dart';

import 'support/workout_fakes.dart';

void main() {
  const key = 'workouts.pending.v1.user-a';
  final now = DateTime(2026, 11, 16, 12);
  late PendingWorkoutQueue queue;

  PendingWorkout entry({DateTime? start, String userId = 'user-a'}) =>
      PendingWorkout(workoutToRow(finishedWorkout(start: start), userId));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    queue = PendingWorkoutQueue('user-a', clock: () => now);
  });

  for (final (name, corrupt) in [
    ('invalid JSON', '{broken'),
    ('non-list JSON', '{"row":{}}'),
    ('wrong preference type', 42),
  ]) {
    test('$name is backed up and a subsequent add succeeds', () async {
      SharedPreferences.setMockInitialValues({key: corrupt});
      expect(await queue.load(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('$key.corrupt'), '$corrupt');
      expect(prefs.containsKey(key), isFalse);
      final saved = entry();
      await queue.add(saved);
      expect((await queue.load()).single.id, saved.id);
      expect(prefs.getString('$key.corrupt'), '$corrupt');
    });
  }

  test(
    'bad items are skipped individually without hiding valid rows',
    () async {
      final first = entry();
      final second = entry();
      final missingEnd = first.toJson();
      missingEnd['row'] = Map.of(first.row)..remove('ended_at');
      SharedPreferences.setMockInitialValues({
        key: jsonEncode([
          first.toJson(),
          null,
          'bad item',
          {},
          {
            'row': {'user_id': 'user-a'},
          },
          missingEnd,
          entry(userId: 'user-b').toJson(),
          second.toJson(),
        ]),
      });
      expect((await queue.load()).map((e) => e.id), [first.id, second.id]);
      final third = entry();
      await queue.add(third);
      expect((await queue.load()).map((e) => e.id), [
        first.id,
        second.id,
        third.id,
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect((jsonDecode(prefs.getString(key)!) as List), hasLength(3));
    },
  );

  test('prunes rows older than 30 days on read and on add', () async {
    final expired = entry(start: now.subtract(const Duration(days: 31)));
    final boundary = entry(start: now.subtract(const Duration(days: 30)));
    SharedPreferences.setMockInitialValues({
      key: jsonEncode([expired.toJson(), boundary.toJson()]),
    });
    expect((await queue.load()).single.id, boundary.id);
    await queue.add(expired);
    expect((await queue.load()).single.id, boundary.id);
    expect(
      (await SharedPreferences.getInstance()).getString(key),
      isNot(contains(expired.id)),
    );
  });

  test(
    'caps persisted queues at 200, dropping oldest workouts first',
    () async {
      final entries = List.generate(
        202,
        (i) => entry(start: now.subtract(Duration(minutes: 202 - i))),
      );
      SharedPreferences.setMockInitialValues({
        key: jsonEncode(entries.reversed.map((e) => e.toJson()).toList()),
      });
      final restored = await queue.load();
      expect(restored, hasLength(200));
      expect(restored.map((e) => e.id), isNot(contains(entries[0].id)));
      expect(restored.map((e) => e.id), isNot(contains(entries[1].id)));
      final newest = entry(start: now);
      await queue.add(newest);
      final capped = await queue.load();
      expect(capped, hasLength(200));
      expect(capped.map((e) => e.id), contains(newest.id));
      expect(capped.map((e) => e.id), isNot(contains(entries[2].id)));
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(key)!) as List, hasLength(200));
    },
  );

  test(
    'concurrent writes across handles survive an earlier failed operation',
    () async {
      await queue.clear();
      final fresh = PendingWorkoutQueue('user-a', clock: () => now);
      final other = PendingWorkoutQueue('user-a', clock: () => now);
      final first = entry();
      final second = entry();
      final third = entry();
      final rejected = queue.add(entry());
      final savingFirst = fresh.add(first);
      final savingSecond = other.add(second);
      await expectLater(rejected, throwsStateError);
      final savingThird = fresh.add(third);
      await Future.wait([savingFirst, savingSecond, savingThird]);
      expect(
        (await fresh.load()).map((row) => row.id),
        unorderedEquals([first.id, second.id, third.id]),
      );
    },
  );

  test(
    'clear removes backups and blocks late writes from old handles',
    () async {
      final saved = entry();
      final other = PendingWorkoutQueue('user-a', clock: () => now);
      final saving = queue.add(saved);
      final clearing = other.clear();
      await expectLater(saving, throwsStateError);
      await clearing;
      expect(await queue.load(), isEmpty);
      await expectLater(queue.add(saved), throwsStateError);
      final fresh = PendingWorkoutQueue('user-a', clock: () => now);
      await fresh.add(saved);
      expect((await fresh.load()).single.id, saved.id);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$key.corrupt', 'private backup');
      await fresh.clear();
      expect(prefs.containsKey(key), isFalse);
      expect(prefs.containsKey('$key.corrupt'), isFalse);
    },
  );
}
