/// Daily aggregates only. Dates are local civil dates, not UTC instants.
class DailyMetrics {
  const DailyMetrics({
    required this.date,
    this.sleepMinutes,
    this.sleepEfficiency,
    this.deepMin,
    this.remMin,
    this.lightMin,
    this.awakeMin,
    this.bedtime,
    this.wakeTime,
    this.restingHr,
    this.hrvMs,
    this.spo2Avg,
    this.steps,
    this.activeZoneMin,
    this.activeMin,
    this.totalCalories,
    this.exerciseCount,
    this.isDemo = false,
    this.updatedAt,
  });

  factory DailyMetrics.fromJson(Map<String, dynamic> json) => DailyMetrics(
    date: DateTime.parse(json['date'] as String),
    sleepMinutes: (json['sleep_minutes'] as num?)?.toInt(),
    sleepEfficiency: (json['sleep_efficiency'] as num?)?.toDouble(),
    deepMin: (json['deep_min'] as num?)?.toInt(),
    remMin: (json['rem_min'] as num?)?.toInt(),
    lightMin: (json['light_min'] as num?)?.toInt(),
    awakeMin: (json['awake_min'] as num?)?.toInt(),
    bedtime: _timestamp(json['bedtime']),
    wakeTime: _timestamp(json['wake_time']),
    restingHr: (json['resting_hr'] as num?)?.toDouble(),
    hrvMs: (json['hrv_ms'] as num?)?.toDouble(),
    spo2Avg: (json['spo2_avg'] as num?)?.toDouble(),
    steps: (json['steps'] as num?)?.toInt(),
    activeZoneMin: (json['active_zone_min'] as num?)?.toInt(),
    activeMin: (json['active_min'] as num?)?.toInt(),
    totalCalories: (json['total_calories'] as num?)?.toDouble(),
    exerciseCount: (json['exercise_count'] as num?)?.toInt(),
    isDemo: json['is_demo'] as bool? ?? false,
    updatedAt: _timestamp(json['updated_at']),
  );

  final DateTime date;
  final int? sleepMinutes, deepMin, remMin, lightMin, awakeMin;
  final double? sleepEfficiency, restingHr, hrvMs, spo2Avg;
  final int? steps, activeZoneMin, activeMin, exerciseCount;
  final double? totalCalories;
  final DateTime? bedtime, wakeTime, updatedAt;
  final bool isDemo;

  bool get hasData => [
    sleepMinutes,
    sleepEfficiency,
    deepMin,
    remMin,
    lightMin,
    awakeMin,
    bedtime,
    wakeTime,
    restingHr,
    hrvMs,
    spo2Avg,
    steps,
    activeZoneMin,
    activeMin,
    totalCalories,
    exerciseCount,
  ].any((value) => value != null);

  static DateTime? _timestamp(dynamic value) =>
      value == null ? null : DateTime.parse(value as String);
}

/// Use UTC constructors only for civil-date arithmetic, avoiding DST shifts.
DateTime civilDate(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

String dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
