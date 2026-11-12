import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class NumbersUsed extends StatelessWidget {
  const NumbersUsed({super.key, required this.facts});
  final Map<String, dynamic> facts;

  @override
  Widget build(BuildContext context) {
    final tools = facts['tools'];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Numbers used'),
      children: [
        if (tools is! List || tools.isEmpty)
          const Text('No numbers were returned.')
        else
          for (final tool in tools)
            if (tool is Map)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ToolFacts(tool: tool),
              ),
      ],
    );
  }
}

class _ToolFacts extends StatelessWidget {
  const _ToolFacts({required this.tool});
  final Map<dynamic, dynamic> tool;

  @override
  Widget build(BuildContext context) {
    final input = _map(tool['input']);
    final result = _map(tool['result']);
    final name = tool['name'];
    final children = <Widget>[];
    if (name == 'compare_periods') {
      final metric = input['metric'] as String? ?? '';
      final a = _map(result['a'] ?? result['period_a']);
      final b = _map(result['b'] ?? result['period_b']);
      children.add(Text(_metricName(metric),
        style: Theme.of(context).textTheme.titleSmall));
      for (final period in [('A', 'a', a), ('B', 'b', b)]) {
        final (label, key, values) = period;
        children.add(Text('Period $label: ${input['${key}_start'] ?? '—'} – '
          '${input['${key}_end'] ?? '—'}'));
        children.add(Text('Mean: ${_value(values['mean'], metric)}'));
        final missing = values['missing_dates'];
        final count = missing is List ? missing.length : values['missing_days'];
        children.add(Text('Missing days: ${count ?? 'unknown'}'));
        if (missing is List && missing.isNotEmpty) {
          children.add(Text(missing.join(', ')));
        }
      }
      final contributors = result['top_contributors'];
      if (contributors is List && contributors.isNotEmpty) {
        children.add(const Text('Top contributor dates'));
        for (final contributor in contributors) {
          if (contributor is Map) {
            children.add(Text('${contributor['date'] ?? '—'}: '
              '${_value(contributor['value'], metric)}'));
          }
        }
      }
    } else if (name == 'get_daily_metrics') {
      children.add(Text('Daily summaries: ${input['start_date'] ?? '—'} – '
        '${input['end_date'] ?? '—'}'));
      final days = result['days'];
      children.add(Text(days is List
          ? '${days.length} ${days.length == 1 ? 'day' : 'days'} with data'
          : 'No daily summaries were returned.'));
    } else {
      children.add(const Text('No readable numbers were returned for this tool.'));
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: children),
    );
  }
}

Map<dynamic, dynamic> _map(dynamic value) => value is Map ? value : const {};

String _metricName(String metric) => switch (metric) {
  'sleep_minutes' => 'Sleep',
  'resting_hr' => 'Resting heart rate',
  'hrv_ms' => 'Heart rate variability',
  'steps' => 'Steps',
  'active_zone_min' => 'Active zone minutes',
  'deep_min' => 'Deep sleep',
  'rem_min' => 'REM sleep',
  'awake_min' => 'Time awake',
  _ => 'Period comparison',
};

String _value(dynamic value, String metric) {
  if (value is! num) return 'No data';
  final number = NumberFormat('0.#', 'en').format(value);
  return switch (metric) {
    'sleep_minutes' || 'deep_min' || 'rem_min' || 'awake_min' =>
      '${value.round() ~/ 60} h ${(value.round() % 60).toString().padLeft(2, '0')} min',
    'resting_hr' => '$number bpm',
    'hrv_ms' => '$number ms',
    'steps' => '${NumberFormat.decimalPattern('en').format(value)} steps',
    'active_zone_min' => '$number min',
    _ => number,
  };
}
