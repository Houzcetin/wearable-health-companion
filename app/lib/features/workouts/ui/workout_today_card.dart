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
    return WorkoutPromptHost(
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            const SizedBox(height: 12),
            if (session != null) ...[
              Text(
                '${session.type.label} · ${workoutDuration(session.duration)}',
                style: theme.textTheme.titleLarge,
              ),
              Text(
                '${session.steps} steps · ${(session.distanceMeters / 1000).toStringAsFixed(2)} km',
              ),
              FilledButton.tonal(
                onPressed: ref.read(workoutProvider.notifier).acceptStop,
                child: const Text('Stop'),
              ),
            ] else if (candidate != null && state.activityStartedAt != null)
              Text(
                "Looks like you're ${activityVerb(candidate)} (${state.now.difference(state.activityStartedAt!).inMinutes} min)",
              )
            else
              Text(state.autoStart ? 'Watching' : 'Auto-start prompts off'),
            if (state.sensorNotice != null)
              Text(state.sensorNotice!, style: theme.textTheme.bodySmall),
            if (state.simulator) const Text('Simulator · 20× speed'),
            if (state.todaySessions.isNotEmpty) ...[
              const Divider(),
              Text("Today's workouts", style: theme.textTheme.titleSmall),
              for (final workout in state.todaySessions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(workout.type.label),
                  subtitle: Text(
                    '${DateFormat.Hm().format(workout.startedAt.toLocal())} · ${workoutDuration(workout.duration)} · ${workout.steps} steps',
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
