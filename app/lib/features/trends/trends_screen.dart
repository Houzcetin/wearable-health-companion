import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/connect_prompt.dart';
import '../../data/providers.dart';
import 'domain/trends.dart';
import 'widgets/trends_chart.dart';

class TrendsScreen extends ConsumerStatefulWidget {
  const TrendsScreen({super.key, this.initialMetric, this.launchId});
  final String? initialMetric;
  final Object? launchId;
  @override
  ConsumerState<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends ConsumerState<TrendsScreen> {
  late TrendMetric _metric;
  TrendRange _range = TrendRange.week;

  @override
  void initState() {
    super.initState();
    _metric = TrendMetric.fromQuery(widget.initialMetric);
  }

  @override
  void didUpdateWidget(covariant TrendsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialMetric != widget.initialMetric ||
        oldWidget.launchId != widget.launchId) {
      _metric = TrendMetric.fromQuery(widget.initialMetric);
      _range = TrendRange.week;
    }
  }

  void _retry() {
    ref.invalidate(connectionProvider);
    ref.invalidate(trendsDataProvider((_metric, _range)));
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(trendsDataProvider((_metric, _range)));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trends'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.l),
            child: SegmentedButton<TrendRange>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                for (final range in TrendRange.values)
                  ButtonSegment(value: range, label: Text(range.label)),
              ],
              selected: {_range},
              onSelectionChanged: (value) => setState(() => _range = value.first),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: AppSpace.page,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: AppSpace.s,
                    runSpacing: AppSpace.s,
                    children: [
                      for (final metric in TrendMetric.values)
                        ChoiceChip(
                          label: Text(metric.label),
                          selected: _metric == metric,
                          onSelected: (_) => setState(() => _metric = metric),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.l),
                  if (!ref.watch(backendConfiguredProvider))
                    const Text('Backend not configured')
                  else ...data.when(
                    skipLoadingOnRefresh: false,
                    data: _content,
                    loading: () => [
                      const Padding(
                        padding: EdgeInsets.all(AppSpace.xxl),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      const Text('Loading your trends…', textAlign: TextAlign.center),
                    ],
                    error: (_, _) => [
                      const Text('Could not load your trends. Please try again.'),
                      const SizedBox(height: AppSpace.m),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(onPressed: _retry, child: const Text('Retry')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(TrendsData data) {
    if (data.connection?.isActive != true && !data.isDemo) {
      return [ConnectPrompt(status: data.connection?.status)];
    }
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final average = data.average;
    final outside = data.outsideUsual.take(5).toList();
    final period = '${DateFormat('MMM d', 'en_US').format(data.start)} – '
        '${DateFormat('MMM d', 'en_US').format(data.end)}';
    return [
      if (data.isDemo) ...[
        const DemoDataChip(),
        const SizedBox(height: AppSpace.s),
      ],
      AppCard(
        padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.xl, AppSpace.l, AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(average == null ? period : '$period · average',
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            if (average != null) ...[
              const SizedBox(height: AppSpace.xs),
              Text(_metric.valueLabel(average), style: theme.textTheme.headlineSmall),
            ],
            const SizedBox(height: AppSpace.xs),
            Text(data.summary, key: const Key('trends-summary'),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
            if (data.learning) ...[
              const SizedBox(height: AppSpace.s),
              Text('Still learning your usual',
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
            const SizedBox(height: AppSpace.xl),
            TrendsChart(key: ValueKey((_metric, _range)), data: data),
          ],
        ),
      ),
      if (outside.isNotEmpty) ...[
        const SizedBox(height: AppSpace.xl),
        SectionHeader(_metric == TrendMetric.sleep
            ? 'Nights outside your usual' : 'Days outside your usual'),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.l, vertical: AppSpace.xs),
          child: Column(children: [
            for (var i = 0; i < outside.length; i++) ...[
              if (i > 0) const Divider(),
              _OutsideRow(day: outside[i], metric: _metric, usual: data.usual!),
            ],
          ]),
        ),
      ],
      const SizedBox(height: AppSpace.xl),
      FilledButton.icon(
        onPressed: () => context.go(Uri(
          path: '/coach', queryParameters: {'q': _range.question},
        ).toString(), extra: DateTime.now().microsecondsSinceEpoch),
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('Ask the coach'),
      ),
    ];
  }
}

class _OutsideRow extends StatelessWidget {
  const _OutsideRow({required this.day, required this.metric, required this.usual});
  final TrendDay day;
  final TrendMetric metric;
  final double usual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delta = day.value! - usual;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(children: [
        Expanded(child: Text(DateFormat('EEE d MMM', 'en_US').format(day.date),
          style: theme.textTheme.bodyMedium)),
        Text(metric.valueLabel(day.value!),
          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: AppSpace.m),
        SizedBox(
          width: 84,
          child: Text('${delta < 0 ? '−' : '+'}${metric.differenceLabel(delta)}',
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}
