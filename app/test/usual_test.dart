import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/data/daily_metrics.dart';
import 'package:wearable_companion/features/today/domain/usual.dart';

void main() {
  final today = DateTime(2026, 11, 12);
  List<DailyMetrics> rows(List<int?> values, {int? current = 450}) => [
    for (var i = 0; i < values.length; i++)
      DailyMetrics(
        date: today.subtract(Duration(days: i + 1)),
        sleepMinutes: values[i],
      ),
    DailyMetrics(date: today, sleepMinutes: current),
  ];

  test('odd median is sorted; today is excluded', () {
    final sleep = calculateUsual(
      rows([480, 420, 460, 450, 440, 470, 430], current: 1000),
      today,
    ).sleep;
    expect(sleep.usual, 450);
    expect(sleep.delta, 550);
    expect(sleep.today, 1000);
    expect(sleep.status, UsualStatus.changed);
  });
  test('even median averages the middle pair', () {
    final sleep = calculateUsual(
      rows([420, 430, 440, 450, 460, 470, 480, 490]),
      today,
    ).sleep;
    expect(sleep.usual, 455);
    expect(sleep.delta, -5);
    expect(sleep.status, UsualStatus.steady);
  });
  test('nulls ignored; zero counts as data', () {
    final sleep = calculateUsual(
      rows([null, 0, 420, 430, 440, 450, 460, 470, null]),
      today,
    ).sleep;
    expect(sleep.sampleDays, 7);
    expect(sleep.usual, 440);
  });
  test('fewer than seven valid days is learning', () {
    final sleep = calculateUsual(
      rows([450, null, 450, 450, 450, 450, 450]),
      today,
    ).sleep;
    expect(sleep.sampleDays, 6);
    expect(sleep.status, UsualStatus.learning);
    expect(sleep.today, 450);
    expect(sleep.usual, isNull);
    expect(sleep.delta, isNull);
  });
  test('missing today or null today is noData even with a baseline', () {
    final noToday = rows(List.filled(7, 450))..removeLast();
    for (final data in [noToday, rows(List.filled(7, 450), current: null)]) {
      final sleep = calculateUsual(data, today).sleep;
      expect(sleep.status, UsualStatus.noData);
      expect(sleep.today, isNull);
      expect(sleep.usual, 450);
      expect(sleep.delta, isNull);
    }
  });
  test('only previous 28 civil dates count, regardless of input order', () {
    final data = rows(List.filled(28, 450))
      ..addAll([
        DailyMetrics(
          date: today.subtract(const Duration(days: 29)),
          sleepMinutes: 1,
        ),
        DailyMetrics(date: today.add(const Duration(days: 1)), sleepMinutes: 1),
      ]);
    final sleep = calculateUsual(
      data.reversed.toList(),
      DateTime(2026, 11, 12, 23, 59),
    ).sleep;
    expect(sleep.sampleDays, 28);
    expect(sleep.usual, 450);
  });
  test('duplicate dates do not inflate the seven-day requirement', () {
    final data = rows(List.filled(6, 450));
    data.add(data.first);
    expect(calculateUsual(data, today).sleep.status, UsualStatus.learning);
  });
  test('sleep steady threshold includes both 15-minute boundaries', () {
    for (final value in [435, 465]) {
      expect(
        calculateUsual(
          rows(List.filled(7, 450), current: value),
          today,
        ).sleep.status,
        UsualStatus.steady,
      );
    }
    for (final value in [434, 466]) {
      expect(
        calculateUsual(
          rows(List.filled(7, 450), current: value),
          today,
        ).sleep.status,
        UsualStatus.changed,
      );
    }
  });

  List<DailyMetrics> heartAndSteps({
    double? heart = 62,
    int? steps = 8800,
    int baseline = 8000,
  }) => [
    for (var i = 1; i <= 7; i++)
      DailyMetrics(
        date: today.subtract(Duration(days: i)),
        restingHr: 60,
        steps: baseline,
      ),
    DailyMetrics(date: today, restingHr: heart, steps: steps),
  ];

  test('resting HR median and inclusive two-bpm threshold', () {
    for (final value in [58.0, 62.0]) {
      final heart = calculateUsual(
        heartAndSteps(heart: value),
        today,
      ).restingHeartRate;
      expect(heart.usual, 60);
      expect(heart.delta, value - 60);
      expect(heart.status, UsualStatus.steady);
    }
    for (final value in [57.9, 62.1]) {
      expect(
        calculateUsual(
          heartAndSteps(heart: value),
          today,
        ).restingHeartRate.status,
        UsualStatus.changed,
      );
    }
  });
  test('steps median and inclusive ten-percent threshold', () {
    for (final value in [7200, 8800]) {
      final steps = calculateUsual(heartAndSteps(steps: value), today).steps;
      expect(steps.usual, 8000);
      expect(steps.delta, value - 8000);
      expect(steps.status, UsualStatus.steady);
    }
    for (final value in [7199, 8801]) {
      expect(
        calculateUsual(heartAndSteps(steps: value), today).steps.status,
        UsualStatus.changed,
      );
    }
  });
  test('zero usual steps has a zero threshold', () {
    expect(
      calculateUsual(heartAndSteps(steps: 0, baseline: 0), today).steps.status,
      UsualStatus.steady,
    );
    expect(
      calculateUsual(heartAndSteps(steps: 1, baseline: 0), today).steps.status,
      UsualStatus.changed,
    );
  });
  test('each metric learns independently and handles missing values', () {
    final data = heartAndSteps(heart: null, steps: null);
    final result = calculateUsual(data, today);
    expect(result.restingHeartRate.status, UsualStatus.noData);
    expect(result.steps.status, UsualStatus.noData);
    final incomplete = data.take(5).toList()
      ..add(DailyMetrics(date: today, restingHr: 60, steps: 0));
    final learning = calculateUsual(incomplete, today);
    expect(learning.restingHeartRate.status, UsualStatus.learning);
    expect(learning.steps.status, UsualStatus.learning);
  });
  test('usual range is the 10th–90th percentile when it is wider', () {
    final summary = calculateUsual(
      rows([420, 430, 440, 450, 460, 470, 480, 490]),
      today,
    );
    expect(summary.sleep.usual, 455);
    // p10 = 427, p90 = 483 — wider than 455 ± 15.
    expect(summary.sleep.low, 427);
    expect(summary.sleep.high, 483);
    // A steady value lies inside the range.
    expect(summary.sleep.status, UsualStatus.steady);
    expect(summary.sleep.today! >= summary.sleep.low!, isTrue);
    expect(summary.sleep.today! <= summary.sleep.high!, isTrue);
  });
  test('steps range is ten percent either side of the usual', () {
    final steps = calculateUsual(heartAndSteps(steps: 8000), today).steps;
    expect(steps.low, closeTo(steps.usual! * 0.9, 1e-9));
    expect(steps.high, closeTo(steps.usual! * 1.1, 1e-9));
  });
  test('wide spread: range follows the 10th and 90th percentiles', () {
    final sleep = calculateUsual(
      rows([360, 380, 400, 420, 440, 460, 480, 500, 520, 540, 560]),
      today,
    ).sleep;
    expect(sleep.usual, 460);
    expect(sleep.low, 380); // p10, not 445
    expect(sleep.high, 540); // p90, not 475
    const spread = [360, 380, 400, 420, 440, 460, 480, 500, 520, 540, 560];
    UsualStatus statusOf(int value) =>
        calculateUsual(rows(spread, current: value), today).sleep.status;
    // 430 is 30 min from the usual, beyond the 15-min threshold, but inside
    // the usual range, so it is steady.
    expect(calculateUsual(rows(spread, current: 430), today).sleep.delta, -30);
    expect(statusOf(430), UsualStatus.steady);
    // Both bounds are inclusive; just past them is changed.
    expect(statusOf(380), UsualStatus.steady);
    expect(statusOf(540), UsualStatus.steady);
    expect(statusOf(379), UsualStatus.changed);
    expect(statusOf(541), UsualStatus.changed);
  });
  test('narrow spread: range never narrower than the steady threshold', () {
    final sleep = calculateUsual(
      rows([448, 449, 450, 450, 450, 451, 452]),
      today,
    ).sleep;
    expect(sleep.usual, 450);
    expect(sleep.low, 435);
    expect(sleep.high, 465);
  });
  test('one side can widen while the other stays at the threshold', () {
    final sleep = calculateUsual(
      rows([450, 450, 450, 450, 450, 450, 450, 520, 540, 560, 580]),
      today,
    ).sleep;
    expect(sleep.usual, 450);
    expect(sleep.low, 435); // p10 = 450 is inside 450 − 15
    expect(sleep.high, 560); // p90 = 560 beats 450 + 15
  });
  test('fewer than seven days: no range, as before', () {
    final sleep = calculateUsual(
      rows([300, 450, 600, 450, 450, 450]),
      today,
    ).sleep;
    expect(sleep.sampleDays, 6);
    expect(sleep.low, isNull);
    expect(sleep.high, isNull);
  });
  test('usual range is null while learning', () {
    final sleep = calculateUsual(rows([420, 430, 440]), today).sleep;
    expect(sleep.status, UsualStatus.learning);
    expect(sleep.low, isNull);
    expect(sleep.high, isNull);
  });
  test('percentile interpolates between neighbours', () {
    expect(percentile([1, 2, 3, 4], 0.5), 2.5);
    expect(percentile([1, 2, 3, 4, 5], 0.25), 2);
    expect(percentile([7], 0.75), 7);
  });
  test('percentile with an even count interpolates at the tails', () {
    expect(percentile([1, 2, 3, 4], 0.1), closeTo(1.3, 1e-9));
    expect(percentile([1, 2, 3, 4], 0.9), closeTo(3.7, 1e-9));
    expect(percentile([1, 2, 3, 4], 0), 1);
    expect(percentile([1, 2, 3, 4], 1), 4);
  });
  test('percentile with repeated values', () {
    expect(percentile([5, 5, 5, 9], 0.5), 5);
    expect(percentile([5, 5, 5, 9], 0.1), 5);
    expect(percentile([5, 5, 5, 9], 0.9), closeTo(7.8, 1e-9));
    expect(percentile([3, 3, 3, 3], 0.9), 3);
  });
}
