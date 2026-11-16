import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme.dart';
import '../../../core/widgets/app_card.dart';
import '../workout_provider.dart';
import 'workout_sheets.dart';

class WorkoutTodayCard extends ConsumerStatefulWidget {
  const WorkoutTodayCard({super.key});

  @override
  ConsumerState<WorkoutTodayCard> createState() => _WorkoutTodayCardState();
}

class _WorkoutTodayCardState extends ConsumerState<WorkoutTodayCard> {
  Timer? _liveTimer;

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }

  /// The detector only ticks every 15 s; refresh once a second while a
  /// workout runs so the elapsed time reads as a live clock.
  void _syncLiveTimer(bool active) {
    if (active && _liveTimer == null) {
      _liveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) ref.read(workoutProvider.notifier).refresh();
      });
    } else if (!active && _liveTimer != null) {
      _liveTimer!.cancel();
      _liveTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(workoutProvider);
    final session = state.session;
    _syncLiveTimer(session != null && !state.simulator);
    final candidate = state.candidateType;
    final theme = Theme.of(context);
    final palette = MetricColors.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final body = theme.textTheme.bodyMedium;
    final note = theme.textTheme.bodySmall?.copyWith(color: muted);
    return WorkoutPromptHost(
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Row(
              children: [
                MetricIcon(
                  icon: Icons.directions_run,
                  color: palette.activity,
                  tint: palette.activityTint,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Auto-detect workouts',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (session != null) ...[
              Text(
                '${session.type.label} · ${workoutDuration(session.duration)}',
                style: theme.textTheme.titleLarge,
              ),
              Text(
                '${_steps(session.steps)} steps · ${(session.distanceMeters / 1000).toStringAsFixed(2)} km',
                style: body?.copyWith(color: muted),
              ),
              FilledButton.tonal(
                onPressed: ref.read(workoutProvider.notifier).acceptStop,
                child: const Text('Stop'),
              ),
            ] else if (candidate != null && state.activityStartedAt != null)
              Text(
                "Looks like you're ${activityVerb(candidate)} (${state.now.difference(state.activityStartedAt!).inMinutes} min)",
                style: body,
              )
            else
              Text(
                state.autoStart ? 'Watching' : 'Auto-start prompts off',
                style: body?.copyWith(color: muted),
              ),
            if (state.sensorNotice != null) Text(state.sensorNotice!, style: note),
            if (state.simulator) Text('Simulator · 20× speed', style: note),
            if (state.historyNotice != null)
              Text(state.historyNotice!, style: note),
            for (final review in state.historyCandidates) ...[
              const Divider(height: 24),
              Text(
                'Did you ${review.type.name == 'bike' ? 'cycle' : review.type.name} '
                '${DateFormat.Hm().format(review.startedAt.toLocal())}–'
                '${DateFormat.Hm().format(review.endedAt!.toLocal())}? '
                '${review.steps > 0 ? '${NumberFormat.decimalPattern().format(review.steps)} steps' : 'Steps unavailable'}',
                style: body?.copyWith(fontWeight: FontWeight.w600),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: () => ref
                        .read(workoutProvider.notifier)
                        .reviewHistory(review, save: true),
                    child: const Text('Save'),
                  ),
                  TextButton(
                    onPressed: () => ref
                        .read(workoutProvider.notifier)
                        .reviewHistory(review, save: false),
                    child: const Text('Discard'),
                  ),
                ],
              ),
            ],
            if (state.todaySessions.isNotEmpty) ...[
              const Divider(height: 24),
              Text("Today's workouts", style: theme.textTheme.titleSmall),
              for (final workout in state.todaySessions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(workout.type.label),
                  subtitle: Text(
                    '${DateFormat.Hm().format(workout.startedAt.toLocal())} · ${_minutes(workout.duration)} · ${_steps(workout.steps)} steps',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showWorkoutSummary(context, workout),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

String _steps(int steps) => NumberFormat.decimalPattern('en').format(steps);

/// A finished workout's length: "30 min", or "1 h 05 min" from an hour up.
/// Deliberately unlike the live clock above ([workoutDuration], mm:ss): a
/// running workout reads as a stopwatch, a finished one as a duration.
String _minutes(Duration duration) {
  final minutes = duration.inMinutes;
  return minutes < 60
      ? '$minutes min'
      : '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')} min';
}
