import '../../data/coach_repository.dart';
import '../../data/daily_metrics.dart';

/// Deterministic demo data, relative to "today", so the app opens full without
/// a backend or a device. Everything here is invented and flagged `isDemo`.
const demoDays = 35;

DateTime _date(DateTime from, int daysAgo) {
  final day = DateTime(from.year, from.month, from.day);
  return DateTime(day.year, day.month, day.day - daysAgo);
}

/// [demoDays] days of history before [today], plus today itself.
/// Today's night is short (a changed day); heart rate and steps are typical.
/// A few earlier nights fall outside the usual range.
List<DailyMetrics> demoRows(DateTime today) {
  const shortOrLong = {3: 315, 9: 560, 17: 335, 24: 548};
  DailyMetrics row(int ago) {
    final date = _date(today, ago);
    final sleep = ago == 0 ? 385 : shortOrLong[ago] ?? 420 + (ago * 37) % 70;
    final steps = ago == 0 ? 8900 : 6500 + (ago * 911) % 4500;
    final heart = ago == 0 ? 61.0 : 58.0 + (ago * 3) % 5;
    return DailyMetrics(
      date: date,
      sleepMinutes: sleep,
      sleepEfficiency: 88.0 + ago % 6,
      deepMin: (sleep * 0.16).round(),
      remMin: (sleep * 0.22).round(),
      lightMin: (sleep * 0.5).round(),
      awakeMin: (sleep * 0.12).round(),
      bedtime: DateTime(date.year, date.month, date.day - 1, 23, 10 + ago % 40),
      wakeTime: DateTime(date.year, date.month, date.day, 6, 40 + ago % 25),
      restingHr: heart,
      hrvMs: 38.0 + ago % 9,
      spo2Avg: 96.0 + ago % 3 * 0.5,
      steps: steps,
      activeZoneMin: 10 + ago % 25,
      activeMin: 25 + ago % 40,
      totalCalories: 2150.0 + ago % 7 * 40,
      exerciseCount: ago % 4 == 0 ? 1 : 0,
      isDemo: true,
    );
  }

  return [for (var ago = demoDays; ago >= 0; ago--) row(ago)];
}

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

double _mean(List<int> v) => v.reduce((a, b) => a + b) / v.length;
double _median(List<int> v) {
  final s = [...v]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid].toDouble() : (s[mid - 1] + s[mid]) / 2;
}

double _round(double v) => (v * 10).round() / 10;

/// A `compare_periods` tool result built from the demo rows: the last 7 days
/// (including today) against the 28 days before today. That baseline is the
/// same window Today and Trends use for "typical" (the median), so the coach
/// and the cards quote one number.
Map<String, dynamic> _sleepComparison(DateTime today) {
  final rows = demoRows(today);
  List<DailyMetrics> between(int fromAgo, int toAgo) => rows
      .where((r) {
        final ago = _date(today, 0).difference(r.date).inDays;
        return ago >= toAgo && ago <= fromAgo;
      })
      .toList();
  final a = between(6, 0), b = between(28, 1);
  Map<String, dynamic> period(List<DailyMetrics> p) {
    final v = [for (final r in p) r.sleepMinutes!];
    return {
      'nights_with_data': v.length,
      'missing_dates': <String>[],
      'mean': _round(_mean(v)),
      'median': _round(_median(v)),
    };
  }

  final typicalB = _median([for (final r in b) r.sleepMinutes!]);
  final contributors = [...a]
    ..sort(
      (x, y) => (y.sleepMinutes! - typicalB).abs().compareTo(
        (x.sleepMinutes! - typicalB).abs(),
      ),
    );
  return {
    'a': period(a),
    'b': period(b),
    'enough_data': true,
    'is_demo': true,
    'top_contributors': [
      for (final r in contributors.take(2))
        {'date': _dateKey(r.date), 'value': r.sleepMinutes},
    ],
  };
}

Map<String, dynamic> _compareFacts(DateTime today) => {
  'tools': [
    {
      'name': 'compare_periods',
      'input': {
        'metric': 'sleep_minutes',
        'a_start': _dateKey(_date(today, 6)),
        'a_end': _dateKey(_date(today, 0)),
        'b_start': _dateKey(_date(today, 28)),
        'b_end': _dateKey(_date(today, 1)),
      },
      'result': _sleepComparison(today),
    },
  ],
};

Map<String, dynamic> _heartFacts(DateTime today) {
  final rows = demoRows(today).where(
    (r) => _date(today, 0).difference(r.date).inDays <= 13,
  );
  return {
    'tools': [
      {
        'name': 'get_daily_metrics',
        'input': {
          'start_date': _dateKey(_date(today, 13)),
          'end_date': _dateKey(_date(today, 0)),
        },
        'result': {
          'days': [
            for (final r in rows)
              {'date': _dateKey(r.date), 'resting_hr': r.restingHr},
          ],
          'missing_dates': <String>[],
          'is_demo': true,
        },
      },
    ],
  };
}

const demoThreadId = 'demo-thread';

/// Two prepared questions with answers, shown as the coach's saved history.
List<CoachMessage> demoCoachHistory(DateTime today) {
  final comparison = _sleepComparison(today);
  final a = comparison['a'] as Map<String, dynamic>;
  final b = comparison['b'] as Map<String, dynamic>;
  String hm(num minutes) =>
      '${minutes.round() ~/ 60} h ${(minutes.round() % 60).toString().padLeft(2, '0')} min';
  return [
    const CoachMessage(
      threadId: demoThreadId,
      role: 'user',
      content: 'Why was my sleep shorter this week?',
    ),
    CoachMessage(
      threadId: demoThreadId,
      role: 'assistant',
      content:
          'This is a demo answer. In the sample data you averaged '
          '${hm(a['mean'] as num)} over the last 7 nights, against a typical '
          '${hm(b['median'] as num)} over the 28 nights before. '
          'The numbers behind it are listed under Numbers used.',
      facts: _compareFacts(today),
      isDemo: true,
    ),
    const CoachMessage(
      threadId: demoThreadId,
      role: 'user',
      content: 'How was my resting heart rate?',
    ),
    CoachMessage(
      threadId: demoThreadId,
      role: 'assistant',
      content:
          'This is a demo answer. In the sample data your resting heart rate '
          'stayed between 58 and 62 bpm over the last two weeks.',
      facts: _heartFacts(today),
      isDemo: true,
    ),
  ];
}

/// Every new question gets this fixed, clearly labelled reply. No request is
/// made to any service.
CoachReply demoCoachReply(DateTime today) => CoachReply(
  threadId: demoThreadId,
  answer:
      'Demo answer: this app is running in demo mode, so the coach does not '
      'call a model. In a real account it would answer from your own daily '
      'data and list the numbers it used.',
  facts: _heartFacts(today),
  isDemo: true,
);
