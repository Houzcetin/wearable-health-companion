import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../core/widgets/app_card.dart';
import '../../core/demo/demo_mode.dart';
import '../../core/widgets/connect_prompt.dart';
import '../../core/widgets/usual_range_bar.dart';
import '../../data/daily_metrics.dart';
import '../../data/providers.dart';
import '../workouts/ui/workout_today_card.dart';
import 'domain/usual.dart';

/// Bumped when the selected Today tab is tapped again.
final todayScrollToTopProvider = NotifierProvider<ScrollToTopRequest, int>(
  ScrollToTopRequest.new,
);

class ScrollToTopRequest extends Notifier<int> {
  @override
  int build() => 0;
  void request() => state++;
}

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
  final _scroll = ScrollController();

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
    _scroll.dispose();
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
              : ref.read(demoModeProvider)
              ? 'Demo mode: nothing was synced.'
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
    // Tapping the selected Today tab scrolls to the top; nothing else changes.
    ref.listen(todayScrollToTopProvider, (_, _) {
      if (_scroll.hasClients) {
        unawaited(_scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ));
      }
    });
    final configured = ref.watch(backendConfiguredProvider);
    final data = ref.watch(todayDataProvider);
    final connected = configured && data.value?.connection?.isActive == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Today'),
        actions: [
          if (connected)
            Padding(
              padding: const EdgeInsets.only(right: AppSpace.s),
              child: TextButton.icon(
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
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: AppSpace.page,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...!configured
                        ? _offline()
                        : data.when(
                            skipLoadingOnRefresh: false,
                            data: _content,
                            loading: _loading,
                            error: (_, _) => [
                              const Text(
                                'Could not load your daily summary. Please try again.',
                              ),
                              const SizedBox(height: AppSpace.m),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: OutlinedButton(
                                  onPressed: _refresh,
                                  child: const Text('Retry'),
                                ),
                              ),
                            ],
                          ),
                    const SizedBox(height: AppSpace.xl),
                    const WorkoutTodayCard(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _loading() {
    final scheme = Theme.of(context).colorScheme;
    Widget block(double height) => Container(
      height: height,
      margin: const EdgeInsets.only(bottom: AppSpace.m),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    );
    return [
      Semantics(
        liveRegion: true,
        label: 'Loading your daily summary…',
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: AppSpace.l),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 0.8,
                child: block(64),
              ),
              const SizedBox(height: AppSpace.s),
              block(120),
              block(120),
              block(120),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _offline() {
    final palette = MetricColors.of(context);
    return [
      Text(
        'Backend not configured',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: AppSpace.s),
      Text(
        'Your daily summary will appear here when the backend is configured.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: AppSpace.xl),
      _MetricCard(
        icon: Icons.bedtime_outlined,
        color: palette.sleep,
        tint: palette.sleepTint,
        title: 'Sleep',
        value: '—',
        comparison: 'No data yet',
      ),
      const SizedBox(height: AppSpace.m),
      _MetricCard(
        icon: Icons.favorite_outline,
        color: palette.heart,
        tint: palette.heartTint,
        title: 'Heart',
        value: '—',
        comparison: 'No data yet',
      ),
      const SizedBox(height: AppSpace.m),
      _MetricCard(
        icon: Icons.directions_walk,
        color: palette.activity,
        tint: palette.activityTint,
        title: 'Activity',
        value: '—',
        comparison: 'No data yet',
      ),
    ];
  }

  List<Widget> _content(TodayData data) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final palette = MetricColors.of(context);
    final connection = data.connection;
    final connected = connection?.isActive == true;
    // Demo rows stand in for a device during development; show them even
    // before Google Health is connected, clearly labelled.
    if (!connected && !data.rows.any((row) => row.isDemo)) {
      return [
        ConnectPrompt(
          status: connection?.status,
          footer: connection?.lastSyncedAt == null ? null : Text(
            _lastSynced(connection!.lastSyncedAt),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
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
    final others = _othersLine(summary);
    return [
      if (rows.any((row) => row.isDemo)) ...[
        const DemoDataChip(),
        const SizedBox(height: AppSpace.s),
      ],
      _SleepInsight(sleep: summary.sleep),
      if (others != null) ...[
        const SizedBox(height: AppSpace.s),
        Text(others, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
      ],
      if (!rows.any((row) => row.hasData)) ...[
        const SizedBox(height: AppSpace.s),
        Text(
          'No data yet. Sync your device in Google Health, then tap Sync now.',
          style: theme.textTheme.bodyMedium?.copyWith(color: muted),
        ),
      ],
      const SizedBox(height: AppSpace.l),
      _MetricCard(
        icon: Icons.bedtime_outlined,
        color: palette.sleep,
        tint: palette.sleepTint,
        title: 'Sleep',
        value: current?.sleepMinutes == null
            ? '—'
            : _duration(current!.sleepMinutes!),
        comparison: _comparison(summary.sleep, 'min'),
        metric: summary.sleep,
        onTap: () => context.go('/trends?metric=sleep',
          extra: DateTime.now().microsecondsSinceEpoch),
      ),
      const SizedBox(height: AppSpace.m),
      _MetricCard(
        icon: Icons.favorite_outline,
        color: palette.heart,
        tint: palette.heartTint,
        title: 'Heart',
        value: current?.restingHr == null
            ? '—'
            : '${_number(current!.restingHr!)} bpm',
        secondary: current?.hrvMs == null
            ? 'Resting heart rate'
            : 'Resting heart rate · HRV ${_number(current!.hrvMs!)} ms',
        comparison: _comparison(summary.restingHeartRate, 'bpm'),
        metric: summary.restingHeartRate,
        onTap: () => context.go('/trends?metric=heart',
          extra: DateTime.now().microsecondsSinceEpoch),
      ),
      const SizedBox(height: AppSpace.m),
      _MetricCard(
        icon: Icons.directions_walk,
        color: palette.activity,
        tint: palette.activityTint,
        title: 'Activity',
        value: current?.steps == null
            ? '—'
            : '${NumberFormat.decimalPattern('en').format(current!.steps)} steps',
        secondary: current?.activeZoneMin == null
            ? null
            : '${current!.activeZoneMin} active zone min',
        comparison: _comparison(summary.steps, 'steps'),
        metric: summary.steps,
        onTap: () => context.go('/trends?metric=steps',
          extra: DateTime.now().microsecondsSinceEpoch),
      ),
      const SizedBox(height: AppSpace.s),
      if (!connected)
        Row(
          children: [
            Expanded(child: Text('Sample data, not from your device.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted))),
            TextButton(
              onPressed: () => context.go('/connect'),
              child: const Text('Connect Google Health'),
            ),
          ],
        )
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(4, AppSpace.xs, 4, 0),
          child: Text(
            _lastSynced(connection!.lastSyncedAt),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      if (_syncMessage != null)
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              _syncMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _syncError ? theme.colorScheme.error : muted,
              ),
            ),
          ),
        ),
    ];
  }
}

/// One line about heart rate and steps under the sleep insight, or null
/// while either is missing or still learning.
String? _othersLine(UsualSummary summary) {
  final heart = summary.restingHeartRate.status;
  final steps = summary.steps.status;
  bool known(UsualStatus s) => s == UsualStatus.steady || s == UsualStatus.changed;
  if (!known(heart) || !known(steps)) return null;
  // "also" only follows a lead sentence that itself reports a change.
  final also = summary.sleep.status == UsualStatus.changed ? 'also ' : '';
  return switch ((heart, steps)) {
    (UsualStatus.steady, UsualStatus.steady) =>
      'Heart rate and steps are within your usual range.',
    (UsualStatus.changed, UsualStatus.changed) =>
      'Heart rate and steps ${also}differ from usual.',
    (UsualStatus.changed, _) =>
      'Heart rate ${also}differs from usual; steps are within your usual range.',
    _ =>
      'Steps ${also}differ from usual; heart rate is within your usual range.',
  };
}

/// The lead sentence. When sleep changed, the difference is highlighted.
class _SleepInsight extends StatelessWidget {
  const _SleepInsight({required this.sleep});
  final MetricComparison sleep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.headlineSmall?.copyWith(fontSize: 28);
    if (sleep.status != UsualStatus.changed) {
      return Text(_sleepInsight(sleep), style: style);
    }
    final direction = sleep.delta! < 0 ? 'less' : 'more';
    return Text.rich(
      TextSpan(children: [
        const TextSpan(text: 'You slept '),
        TextSpan(
          text: '${_delta(sleep.delta!)} min $direction',
          style: TextStyle(color: theme.colorScheme.primary),
        ),
        const TextSpan(text: ' than typical.'),
      ]),
      style: style,
    );
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
    'Still learning your usual range (${sleep.sampleDays} of 7 nights).',
  UsualStatus.steady => 'Your sleep was within your usual range.',
  UsualStatus.changed =>
    'You slept ${_delta(sleep.delta!)} min ${sleep.delta! < 0 ? 'less' : 'more'} than typical.',
};
String _comparison(
  MetricComparison metric,
  String unit,
) => switch (metric.status) {
  UsualStatus.noData => 'No data today',
  UsualStatus.learning =>
    'Learning your usual range (${metric.sampleDays} of 7 days)',
  UsualStatus.steady => metric.delta!.round() == 0
      ? 'In your usual range'
      : 'In your usual range (${_delta(metric.delta!)} $unit '
            '${metric.delta! < 0 ? 'under' : 'over'} typical)',
  UsualStatus.changed => metric.delta! < 0
      ? 'Below your usual range (−${_delta(metric.delta!)} $unit)'
      : 'Above your usual range (+${_delta(metric.delta!)} $unit)',
};
String _lastSynced(DateTime? timestamp) => timestamp == null
    ? 'Last synced: never'
    : 'Last synced: ${DateFormat('MMM d, h:mm a', 'en_US').format(timestamp.toLocal())}';

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.color,
    required this.tint,
    required this.title,
    required this.value,
    required this.comparison,
    this.secondary,
    this.metric,
    this.onTap,
  });
  final IconData icon;
  final Color color, tint;
  final String title, value, comparison;
  final String? secondary;
  final MetricComparison? metric;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final m = metric;
    final delta = m?.delta;
    // Only a value outside the usual range gets a direction arrow.
    final arrow = m?.status == UsualStatus.changed && delta != null;
    final showRange = m != null && m.today != null && m.usual != null &&
        m.low != null && m.high != null;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(AppSpace.l, 14, AppSpace.l, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MetricIcon(icon: icon, color: color, tint: tint),
              const SizedBox(width: AppSpace.m),
              // The title keeps its natural width (capped), the value takes
              // the rest and sits flush right.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(title, style: theme.textTheme.titleSmall,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: Text(value, style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.end, maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          if (showRange) ...[
            const SizedBox(height: 10),
            UsualRangeBar(
              value: m.today!, usual: m.usual!, low: m.low!, high: m.high!,
              color: color,
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (arrow) ...[
                Icon(
                  delta < 0 ? Icons.arrow_downward : Icons.arrow_upward,
                  size: 14,
                  color: muted,
                ),
                const SizedBox(width: AppSpace.xs),
              ],
              Expanded(
                child: Text(comparison, style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (secondary != null) ...[
            const SizedBox(height: 2),
            Text(
              secondary!,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ],
      ),
    );
  }
}
