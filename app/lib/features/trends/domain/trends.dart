import 'package:intl/intl.dart';

import '../../../data/daily_metrics.dart';
import '../../../data/health_repository.dart';
import '../../today/domain/usual.dart';

enum TrendRange {
  week(7, 'Week', 'This week'),
  month(30, 'Month', 'This month');
  const TrendRange(this.days, this.label, this.sentence);
  final int days;
  final String label, sentence;
  String get question => this == week
      ? 'Why was this week different from my usual?'
      : 'How did this month compare with the month before?';
}

enum TrendMetric {
  sleep('Sleep'), heart('Resting heart rate'), steps('Steps');
  const TrendMetric(this.label);
  final String label;
  static TrendMetric fromQuery(String? value) => switch (value) {
    'heart' || 'resting_hr' => heart,
    'steps' => steps,
    _ => sleep,
  };
  double? read(DailyMetrics row) => switch (this) {
    sleep => row.sleepMinutes?.toDouble(),
    heart => row.restingHr,
    steps => row.steps?.toDouble(),
  };
  MetricComparison comparison(UsualSummary summary) => switch (this) {
    sleep => summary.sleep,
    heart => summary.restingHeartRate,
    steps => summary.steps,
  };
  double chartValue(double value) => this == sleep ? value / 60 : value;
  String get unit => switch (this) {
    sleep => 'hours', heart => 'bpm', steps => 'steps',
  };
  String valueLabel(double value) => switch (this) {
    sleep => '${value.round() ~/ 60} h ${(value.round() % 60).toString().padLeft(2, '0')} min',
    heart => '${NumberFormat('0.#', 'en').format(value)} bpm',
    steps => '${NumberFormat.decimalPattern('en').format(value.round())} steps',
  };
  String differenceLabel(double value) => this == sleep
      ? '${value.abs().round()} min'
      : valueLabel(value.abs());
}

class TrendDay {
  const TrendDay(this.date, this.value);
  final DateTime date;
  final double? value;
}

class TrendsData {
  const TrendsData({
    required this.metric,
    required this.range,
    required this.end,
    this.connection,
    this.rows = const [],
  });
  final TrendMetric metric;
  final TrendRange range;
  final DateTime end;
  final HealthConnection? connection;
  /// Includes the chart period and the 28 days before its last date.
  final List<DailyMetrics> rows;
  DateTime get start => civilDate(end).subtract(Duration(days: range.days - 1));
  List<TrendDay> get days {
    final byDate = {for (final row in rows) civilDate(row.date): row};
    return [
      for (var i = 0; i < range.days; i++)
        TrendDay(start.add(Duration(days: i)),
          byDate[start.add(Duration(days: i))] == null ? null :
            metric.read(byDate[start.add(Duration(days: i))]!)),
    ];
  }
  int get missingDays => days.where((day) => day.value == null).length;
  double? get average {
    final values = days.map((day) => day.value).whereType<double>().toList();
    return values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
  }
  MetricComparison get _baseline => metric.comparison(calculateUsual(rows, end));
  double? get usual => _baseline.usual;

  /// Usual range (usual ± the steady threshold, from the 28 days before [end]).
  double? get usualLow => _baseline.low;
  double? get usualHigh => _baseline.high;

  /// True when [value] falls outside the usual range.
  bool isOutsideUsual(double value) {
    final low = usualLow, high = usualHigh;
    return low != null && high != null && (value < low || value > high);
  }

  /// Days outside the usual range, largest difference first.
  List<TrendDay> get outsideUsual {
    final baseline = usual;
    if (baseline == null) return const [];
    return days
        .where((day) => day.value != null && isOutsideUsual(day.value!))
        .toList()
      ..sort((a, b) =>
          (b.value! - baseline).abs().compareTo((a.value! - baseline).abs()));
  }
  bool get learning => range.days - missingDays < 7 || usual == null;
  bool get isDemo => rows.any((row) => row.isDemo);
  String get summary {
    final mean = average;
    final subject = switch (metric) {
      TrendMetric.sleep => ' of sleep',
      TrendMetric.heart => ' resting heart rate',
      TrendMetric.steps => '',
    };
    var sentence = mean == null
        ? '${range.sentence} has no ${metric.label.toLowerCase()} data yet.'
        : '${range.sentence} you averaged ${metric.valueLabel(mean)}$subject';
    if (mean != null) {
      final baseline = usual;
      if (baseline == null) {
        sentence += '.';
      } else {
        final delta = mean - baseline;
        sentence += delta.abs() < (metric == TrendMetric.heart ? 0.05 : 0.5)
            ? ', matching your usual.'
            : ', ${metric.differenceLabel(delta)} ${delta < 0 ? 'below' : 'above'} your usual.';
      }
    }
    if (missingDays > 0) {
      sentence += ' $missingDays ${missingDays == 1 ? 'day' : 'days'} missing.';
    }
    return sentence;
  }
}
