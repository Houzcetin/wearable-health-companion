import '../../../data/daily_metrics.dart';

enum UsualStatus { changed, steady, learning, noData }

class MetricComparison {
  const MetricComparison({
    required this.today,
    required this.usual,
    required this.delta,
    required this.status,
    required this.sampleDays,
    this.low,
    this.high,
  });
  final double? today, usual, delta;

  /// The usual range: the 10th–90th percentile of the previous 28 days, never
  /// narrower than the usual plus or minus the steady threshold. A value inside
  /// it (inclusive) is steady, outside it changed. Null while the usual is
  /// still being learned (fewer than seven days).
  final double? low, high;
  final UsualStatus status;
  final int sampleDays;
}

class UsualSummary {
  const UsualSummary({
    required this.sleep,
    required this.restingHeartRate,
    required this.steps,
  });
  final MetricComparison sleep, restingHeartRate, steps;
}

/// Linear-interpolated percentile of [sorted] values, `0 <= p <= 1`.
/// At p = 0.5 this is the usual median (middle pair averaged when even).
double percentile(List<double> sorted, double p) {
  final position = (sorted.length - 1) * p;
  final lower = position.floor();
  final upper = position.ceil();
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
}

/// Median over the previous 28 civil dates, excluding today and missing values.
/// A zero is a real observation. The database guarantees one row per date.
UsualSummary calculateUsual(List<DailyMetrics> rows, DateTime today) {
  final end = civilDate(today);
  final start = end.subtract(const Duration(days: 28));
  final byDate = {for (final row in rows) civilDate(row.date): row};
  final current = byDate[end];
  final history = byDate.entries
      .where((entry) => !entry.key.isBefore(start) && entry.key.isBefore(end))
      .map((entry) => entry.value);

  MetricComparison compare(
    num? value,
    num? Function(DailyMetrics) read,
    double Function(double usual) threshold,
  ) {
    final values =
        history.map(read).whereType<num>().map((v) => v.toDouble()).toList()
          ..sort();
    final enough = values.length >= 7;
    final median = enough ? percentile(values, 0.5) : null;
    final delta = value != null && median != null ? value - median : null;
    final band = median == null ? null : threshold(median);
    final low = median == null
        ? null
        : _min(percentile(values, 0.1), median - band!);
    final high = median == null
        ? null
        : _max(percentile(values, 0.9), median + band!);
    return MetricComparison(
      today: value?.toDouble(),
      usual: median,
      delta: delta,
      sampleDays: values.length,
      low: low,
      high: high,
      status: value == null
          ? UsualStatus.noData
          : !enough
          ? UsualStatus.learning
          : value >= low! && value <= high!
          ? UsualStatus.steady
          : UsualStatus.changed,
    );
  }

  return UsualSummary(
    sleep: compare(current?.sleepMinutes, (row) => row.sleepMinutes, (_) => 15),
    restingHeartRate: compare(
      current?.restingHr,
      (row) => row.restingHr,
      (_) => 2,
    ),
    steps: compare(
      current?.steps,
      (row) => row.steps,
      (usual) => usual.abs() * 0.1,
    ),
  );
}

double _min(double a, double b) => a < b ? a : b;
double _max(double a, double b) => a > b ? a : b;
