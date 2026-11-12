import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/daily_metrics.dart';
import '../../data/health_repository.dart';
import '../../data/providers.dart';
import 'domain/usual.dart';

class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});
  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen>
    with WidgetsBindingObserver {
  bool _syncing = false;
  String? _syncMessage;
  bool _syncError = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(todayDateProvider);
    ref.invalidate(connectionProvider);
    ref.invalidate(todayDataProvider);
    try {
      await ref.read(todayDataProvider.future);
    } catch (_) {
      // The provider exposes a recoverable error state in the screen.
    }
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _syncMessage = null;
      _syncError = false;
    });
    try {
      final result = await ref.read(healthRepositoryProvider).requestSync();
      if (mounted) {
        setState(() {
          _syncError = result.failed > 0;
          _syncMessage = result.failed > 0
              ? 'Some data could not sync. Please try again.'
              : result.remaining > 0
              ? 'More data is waiting to sync. Tap Sync now again shortly.'
              : 'Sync finished.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _syncError = true;
          _syncMessage = 'Could not sync. Check your connection and try again.';
        });
      }
    } finally {
      // Refetch even after a partial failure: some rows may have arrived.
      if (mounted) {
        await _refresh();
        if (mounted) setState(() => _syncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(backendConfiguredProvider);
    final data = ref.watch(todayDataProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: !configured
                      ? _offline()
                      : data.when(
                          skipLoadingOnRefresh: false,
                          data: _content,
                          loading: () => [
                            const Padding(
                              padding: EdgeInsets.all(32),
                              child: Column(
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 16),
                                  Text('Loading your daily summary…'),
                                ],
                              ),
                            ),
                          ],
                          error: (_, _) => [
                            const Text(
                              'Could not load your daily summary. Please try again.',
                            ),
                            OutlinedButton(
                              onPressed: _refresh,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _offline() => [
    Text(
      'Backend not configured',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    const SizedBox(height: 8),
    const Text(
      'Your daily summary will appear here when the backend is configured.',
    ),
    const SizedBox(height: 12),
    const _MetricCard(
      icon: Icons.bedtime_outlined,
      color: AppColors.sleep,
      title: 'Sleep',
      value: '—',
      comparison: 'No data yet',
    ),
    const _MetricCard(
      icon: Icons.favorite_outline,
      color: AppColors.heart,
      title: 'Heart',
      value: '—',
      comparison: 'No data yet',
    ),
    const _MetricCard(
      icon: Icons.directions_walk,
      color: AppColors.activity,
      title: 'Activity',
      value: '—',
      comparison: 'No data yet',
    ),
  ];

  List<Widget> _content(TodayData data) {
    final connection = data.connection;
    final connected = connection?.isActive == true;
    // Demo rows stand in for a device during development; show them even
    // before Google Health is connected, clearly labelled.
    if (!connected && !data.rows.any((row) => row.isDemo)) {
      final revoked = connection?.status == ConnectionStatus.revoked;
      final error = connection?.status == ConnectionStatus.error;
      return [
        Icon(
          Icons.watch_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          revoked
              ? 'Google Health connection revoked'
              : error
              ? 'Your Google Health connection needs attention'
              : 'Connect Google Health to see your daily summary.',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'See sleep, heart rate and activity compared with your usual.',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => context.go('/connect'),
          child: Text(
            revoked || error
                ? 'Reconnect Google Health'
                : 'Connect Google Health',
          ),
        ),
        if (connection?.lastSyncedAt != null)
          Text(_lastSynced(connection!.lastSyncedAt)),
      ];
    }
    final today = civilDate(data.today);
    final start = today.subtract(const Duration(days: 28));
    final rows = data.rows
        .where(
          (row) =>
              !civilDate(row.date).isBefore(start) &&
              !civilDate(row.date).isAfter(today),
        )
        .toList();
    final summary = calculateUsual(rows, today);
    final current = rows
        .where((row) => civilDate(row.date) == today)
        .firstOrNull;
    return [
      Text(
        _sleepInsight(summary.sleep),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      if (rows.any((row) => row.isDemo))
        const Align(
          alignment: Alignment.centerLeft,
          child: Chip(
            avatar: Icon(Icons.science_outlined, size: 18),
            label: Text('Demo data'),
          ),
        ),
      if (!rows.any((row) => row.hasData)) ...[
        const SizedBox(height: 8),
        const Text(
          'No data yet. Sync your device in Google Health, then tap Sync now.',
        ),
      ],
      const SizedBox(height: 8),
      _MetricCard(
        icon: Icons.bedtime_outlined,
        color: AppColors.sleep,
        title: 'Sleep',
        value: current?.sleepMinutes == null
            ? '—'
            : _duration(current!.sleepMinutes!),
        comparison: _comparison(summary.sleep, 'min'),
        delta: summary.sleep.delta,
      ),
      _MetricCard(
        icon: Icons.favorite_outline,
        color: AppColors.heart,
        title: 'Heart',
        value: current?.restingHr == null
            ? '—'
            : '${_number(current!.restingHr!)} bpm',
        secondary: current?.hrvMs == null
            ? 'Resting heart rate'
            : 'Resting heart rate · HRV ${_number(current!.hrvMs!)} ms',
        comparison: _comparison(summary.restingHeartRate, 'bpm'),
        delta: summary.restingHeartRate.delta,
      ),
      _MetricCard(
        icon: Icons.directions_walk,
        color: AppColors.activity,
        title: 'Activity',
        value: current?.steps == null
            ? '—'
            : '${NumberFormat.decimalPattern('en').format(current!.steps)} steps',
        secondary: current?.activeZoneMin == null
            ? null
            : '${current!.activeZoneMin} active zone min',
        comparison: _comparison(summary.steps, 'steps'),
        delta: summary.steps.delta,
      ),
      const SizedBox(height: 4),
      if (!connected)
        Row(
          children: [
            const Expanded(child: Text('Sample data, not from your device.')),
            TextButton(
              onPressed: () => context.go('/connect'),
              child: const Text('Connect Google Health'),
            ),
          ],
        )
      else
        Row(
          children: [
            Expanded(
              child: Text(
                _lastSynced(connection!.lastSyncedAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton.icon(
              onPressed: _syncing ? null : _sync,
              icon: _syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(_syncing ? 'Syncing…' : 'Sync now'),
            ),
          ],
        ),
      if (_syncMessage != null)
        Semantics(
          liveRegion: true,
          child: Text(
            _syncMessage!,
            style: TextStyle(
              color: _syncError
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
  }
}

String _number(num value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(1);

/// Differences from a median can be x.5; show whole units, grouped.
String _delta(num value) =>
    NumberFormat.decimalPattern('en').format(value.abs().round());
String _duration(int minutes) =>
    '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')} min';
String _sleepInsight(MetricComparison sleep) => switch (sleep.status) {
  UsualStatus.noData => 'No sleep data for last night.',
  UsualStatus.learning =>
    'Still learning your usual (${sleep.sampleDays} of 7 nights).',
  UsualStatus.steady => 'Your sleep matched your usual.',
  UsualStatus.changed =>
    'You slept ${_delta(sleep.delta!)} min ${sleep.delta! < 0 ? 'less' : 'more'} than your usual.',
};
String _comparison(
  MetricComparison metric,
  String unit,
) => switch (metric.status) {
  UsualStatus.noData => 'No data today',
  UsualStatus.learning =>
    'Learning your usual (${metric.sampleDays} of 7 days)',
  UsualStatus.changed || UsualStatus.steady =>
    metric.delta!.abs().round() == 0
        ? 'Same as your usual'
        : '${_delta(metric.delta!)} $unit ${metric.delta! < 0 ? 'below' : 'above'} usual',
};
String _lastSynced(DateTime? timestamp) => timestamp == null
    ? 'Last synced: never'
    : 'Last synced: ${DateFormat('MMM d, h:mm a', 'en').format(timestamp.toLocal())}';

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.comparison,
    this.secondary,
    this.delta,
  });
  final IconData icon;
  final Color color;
  final String title, value, comparison;
  final String? secondary;
  final double? delta;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                Text(value, style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                if (delta != null && delta != 0) ...[
                  Icon(
                    delta! < 0 ? Icons.arrow_downward : Icons.arrow_upward,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(comparison, style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
            if (secondary != null)
              Text(
                secondary!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
