import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/health_repository.dart';
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
      appBar: AppBar(title: const Text('Trends')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<TrendRange>(
                    segments: [
                      for (final range in TrendRange.values)
                        ButtonSegment(value: range, label: Text(range.label)),
                    ],
                    selected: {_range},
                    onSelectionChanged: (value) => setState(() => _range = value.first),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final metric in TrendMetric.values)
                        ChoiceChip(
                          label: Text(metric.label),
                          selected: _metric == metric,
                          onSelected: (_) => setState(() => _metric = metric),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (!ref.watch(backendConfiguredProvider))
                    const Text('Backend not configured')
                  else ...data.when(
                    skipLoadingOnRefresh: false,
                    data: _content,
                    loading: () => [
                      const Center(child: CircularProgressIndicator()),
                      const Text('Loading your trends…'),
                    ],
                    error: (_, _) => [
                      const Text('Could not load your trends. Please try again.'),
                      OutlinedButton(onPressed: _retry, child: const Text('Retry')),
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
      final status = data.connection?.status;
      final reconnect = status == ConnectionStatus.revoked || status == ConnectionStatus.error;
      return [
        Icon(Icons.watch_outlined, size: 48,
          color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          status == ConnectionStatus.revoked
              ? 'Google Health connection revoked'
              : status == ConnectionStatus.error
              ? 'Your Google Health connection needs attention'
              : 'Connect Google Health to see your daily summary.',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text('See sleep, heart rate and activity compared with your usual.'),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => context.go('/connect'),
          child: Text(reconnect ? 'Reconnect Google Health' : 'Connect Google Health'),
        ),
      ];
    }
    return [
      Text(data.summary, key: const Key('trends-summary'),
        style: Theme.of(context).textTheme.titleMedium),
      if (data.isDemo)
        const Align(
          alignment: Alignment.centerLeft,
          child: Chip(avatar: Icon(Icons.science_outlined, size: 18),
            label: Text('Demo data')),
        ),
      if (data.learning) ...[
        const SizedBox(height: 8),
        const Text('Still learning your usual'),
      ],
      const SizedBox(height: 16),
      TrendsChart(key: ValueKey((_metric, _range)), data: data),
      const SizedBox(height: 16),
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
