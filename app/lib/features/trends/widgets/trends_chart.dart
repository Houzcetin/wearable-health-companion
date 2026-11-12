import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme.dart';
import '../../../data/daily_metrics.dart';
import '../domain/trends.dart';

class TrendsChart extends StatefulWidget {
  const TrendsChart({super.key, required this.data});
  final TrendsData data;
  @override
  State<TrendsChart> createState() => _TrendsChartState();
}

class _TrendsChartState extends State<TrendsChart> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final days = data.days;
    final metric = data.metric;
    final color = switch (metric) {
      TrendMetric.sleep => AppColors.sleep,
      TrendMetric.heart => AppColors.heart,
      TrendMetric.steps => AppColors.activity,
    };
    final usual = data.usual;
    final maxValue = [
      1.0,
      if (usual != null) metric.chartValue(usual),
      ...days.map((day) => day.value).whereType<double>().map(metric.chartValue),
    ].reduce(math.max);
    String dayLabel(TrendDay day) =>
        '${DateFormat('MMM d, yyyy', 'en_US').format(day.date)}: '
        '${day.value == null ? 'no data' : metric.valueLabel(day.value!)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${DateFormat('MMM d', 'en_US').format(data.start)} – '
          '${DateFormat('MMM d', 'en_US').format(data.end)} · ${metric.unit}'),
        const SizedBox(height: 8),
        Semantics(
          key: const Key('trends-chart-semantics'),
          label: [data.summary, ...days.map(dayLabel)].join(' '),
          child: ExcludeSemantics(
            child: SizedBox(
              height: 260,
              child: BarChart(
                BarChartData(
                  minY: 0,
                  maxY: maxValue * 1.2,
                  alignment: BarChartAlignment.spaceAround,
                  borderData: FlBorderData(show: false),
                  gridData: const FlGridData(drawVerticalLine: false),
                  barGroups: [
                    for (var i = 0; i < days.length; i++)
                      BarChartGroupData(
                        x: i,
                        // An empty group reserves this date without a zero rod.
                        barRods: [
                          if (days[i].value != null)
                            BarChartRodData(
                              toY: metric.chartValue(days[i].value!),
                              color: color,
                              width: data.range == TrendRange.week ? 20 : 6,
                              borderRadius: BorderRadius.circular(3),
                            ),
                        ],
                      ),
                  ],
                  extraLinesData: ExtraLinesData(horizontalLines: [
                    if (usual != null)
                      HorizontalLine(
                        y: metric.chartValue(usual),
                        color: color,
                        strokeWidth: 2,
                        dashArray: [6, 4],
                      ),
                  ]),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        // The top edge (max * 1.2) is rarely a round value; skip
                        // its label so the axis only shows interval steps.
                        getTitlesWidget: (value, meta) =>
                            value == meta.max && value % meta.appliedInterval != 0
                            ? const SizedBox.shrink()
                            : Text(
                                NumberFormat.compact(locale: 'en').format(value),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true, reservedSize: 44, interval: 1,
                        getTitlesWidget: (value, _) {
                          final i = value.toInt();
                          if (i < 0 || i >= days.length) return const SizedBox.shrink();
                          final day = days[i];
                          final labelDate = data.range == TrendRange.week ||
                              i % 7 == 0 || i == days.length - 1;
                          return Column(children: [
                            if (day.value == null)
                              Tooltip(
                                key: ValueKey('missing-${dateKey(day.date)}'),
                                message: 'no data',
                                child: const Icon(Icons.remove, size: 10),
                              )
                            else
                              const SizedBox(height: 10),
                            if (labelDate)
                              Text('${day.date.day}',
                                style: Theme.of(context).textTheme.labelSmall),
                          ]);
                        },
                      ),
                    ),
                  ),
                  barTouchData: BarTouchData(
                    touchCallback: (event, response) {
                      final spot = response?.spot;
                      if (event is FlTapUpEvent && spot != null) {
                        setState(() => _selected = dayLabel(days[spot.touchedBarGroupIndex]));
                      }
                    },
                    touchTooltipData: BarTouchTooltipData(
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipItem: (group, _, _, _) => BarTooltipItem(
                        dayLabel(days[group.x]),
                        const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
                duration: Duration.zero,
              ),
            ),
          ),
        ),
        if (data.missingDays > 0)
          const Text('− no data', style: TextStyle(fontSize: 12)),
        if (usual != null)
          Text('Dashed line: your usual, ${metric.valueLabel(usual)}'),
        if (_selected != null)
          Semantics(liveRegion: true, child: Text(_selected!,
            key: const Key('selected-trend-day'))),
      ],
    );
  }
}
