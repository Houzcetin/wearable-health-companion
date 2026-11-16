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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = MetricColors.of(context);
    final (color, tint) = switch (metric) {
      TrendMetric.sleep => (palette.sleep, palette.sleepTint),
      TrendMetric.heart => (palette.heart, palette.heartTint),
      TrendMetric.steps => (palette.activity, palette.activityTint),
    };
    // With a usual range, days inside it are muted so the off days stand out.
    final hasRange = data.usualLow != null && data.usualHigh != null;
    // Dark surfaces need a stronger tint for the same visual separation.
    final dark = theme.brightness == Brightness.dark;
    final muted = Color.alphaBlend(
      color.withValues(alpha: dark ? 0.5 : 0.32), scheme.surfaceContainerLowest);
    final band = color.withValues(alpha: dark ? 0.22 : 0.12);
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
        Semantics(
          key: const Key('trends-chart-semantics'),
          label: [data.summary, ...days.map(dayLabel)].join(' '),
          child: ExcludeSemantics(
            child: SizedBox(
              height: 220,
              child: BarChart(
                BarChartData(
                  minY: 0,
                  maxY: maxValue * 1.2,
                  alignment: BarChartAlignment.spaceAround,
                  borderData: FlBorderData(show: false),
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: scheme.outlineVariant, strokeWidth: 1,
                    ),
                  ),
                  rangeAnnotations: RangeAnnotations(horizontalRangeAnnotations: [
                    if (hasRange)
                      HorizontalRangeAnnotation(
                        y1: metric.chartValue(data.usualLow!),
                        y2: metric.chartValue(data.usualHigh!),
                        color: band,
                      ),
                  ]),
                  barGroups: [
                    for (var i = 0; i < days.length; i++)
                      BarChartGroupData(
                        x: i,
                        // An empty group reserves this date without a zero rod.
                        barRods: [
                          if (days[i].value != null)
                            BarChartRodData(
                              toY: metric.chartValue(days[i].value!),
                              color: !hasRange || data.isOutsideUsual(days[i].value!)
                                  ? color : muted,
                              width: data.range == TrendRange.week ? 22 : 6,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(6), bottom: Radius.circular(2)),
                            ),
                        ],
                      ),
                  ],
                  extraLinesData: ExtraLinesData(horizontalLines: [
                    if (usual != null)
                      HorizontalLine(
                        y: metric.chartValue(usual),
                        color: scheme.onSurfaceVariant,
                        strokeWidth: 1.5,
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
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant),
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
                          // The last day is always labelled, unless a weekly
                          // label is right next to it and would collide.
                          final last = days.length - 1;
                          final labelDate = data.range == TrendRange.week ||
                              (i % 7 == 0 && last - i >= 3) || i == last;
                          return Column(children: [
                            if (day.value == null)
                              Tooltip(
                                key: ValueKey('missing-${dateKey(day.date)}'),
                                message: 'no data',
                                child: Icon(Icons.remove, size: 10,
                                  color: scheme.onSurfaceVariant),
                              )
                            else
                              const SizedBox(height: 10),
                            if (labelDate)
                              Text('${day.date.day}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant)),
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
                      getTooltipColor: (_) => scheme.inverseSurface,
                      getTooltipItem: (group, _, _, _) => BarTooltipItem(
                        dayLabel(days[group.x]),
                        TextStyle(color: scheme.onInverseSurface),
                      ),
                    ),
                  ),
                ),
                duration: Duration.zero,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        DefaultTextStyle.merge(
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          child: Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              if (hasRange)
                _LegendItem(
                  swatch: Container(width: 14, height: 10, decoration: BoxDecoration(
                    color: band, borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: color.withValues(alpha: 0.3)))),
                  label: 'Usual range',
                ),
              if (usual != null)
                _LegendItem(
                  swatch: SizedBox(width: 16, child: CustomPaint(
                    size: const Size(16, 1),
                    painter: _DashPainter(scheme.onSurfaceVariant))),
                  label: 'Typical ${metric.valueLabel(usual)}',
                ),
              if (hasRange)
                _LegendItem(
                  swatch: Container(width: 10, height: 10, decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(3))),
                  label: 'Outside usual range',
                ),
              if (data.missingDays > 0)
                const _LegendItem(swatch: Text('−'), label: 'No data'),
            ],
          ),
        ),
        if (_selected != null) ...[
          const SizedBox(height: 8),
          Semantics(liveRegion: true, child: Text(_selected!,
            key: const Key('selected-trend-day'),
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
        ],
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.swatch, required this.label});
  final Widget swatch;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [swatch, const SizedBox(width: 6), Text(label)],
  );
}

class _DashPainter extends CustomPainter {
  const _DashPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 1.5;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, 0), Offset(math.min(x + 4, size.width), 0), paint);
    }
  }
  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
