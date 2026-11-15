import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../domain/activity_sample.dart';
import '../domain/workout_session.dart';
import '../workout_provider.dart';

String workoutDuration(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 1 << 32);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String activityVerb(ExerciseType type) => switch (type) {
  ExerciseType.walk => 'walking',
  ExerciseType.run => 'running',
  ExerciseType.bike => 'cycling',
};

/// Owns only its own modal route; another dialog can safely appear above it.
/// Both Today and Settings host prompts, without adding application routes.
class WorkoutPromptHost extends ConsumerStatefulWidget {
  const WorkoutPromptHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<WorkoutPromptHost> createState() => _WorkoutPromptHostState();
}

class _WorkoutPromptHostState extends ConsumerState<WorkoutPromptHost> {
  ModalRoute<void>? _route;
  Object? _shown;
  bool _scheduled = false;
  bool _active = true;

  Object? _desired(WorkoutState state) =>
      state.startPrompt ?? state.stopPrompt ?? state.summary;

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _sync();
    });
  }

  void _sync() {
    final state = ref.read(workoutProvider);
    final desired = _active ? _desired(state) : null;
    if (identical(desired, _shown)) return;
    if (_route?.isActive == true) {
      _route!.navigator!.removeRoute(_route!);
    }
    _route = null;
    _shown = desired;
    if (desired == null) return;
    // TODO: Foreground sheets only; local push notifications are out of scope.
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: true,
      builder: (sheetContext) {
        _route = ModalRoute.of<void>(sheetContext);
        return _SheetBody(
          child: desired is WorkoutSession
              ? WorkoutSummary(session: desired)
              : const _WorkoutPrompt(),
        );
      },
    ).whenComplete(() {
      if (!mounted || !identical(_shown, desired)) return;
      _shown = null;
      _route = null;
      if (identical(_desired(ref.read(workoutProvider)), desired)) {
        final notifier = ref.read(workoutProvider.notifier);
        if (desired is WorkoutSession) {
          notifier.clearSummary();
        } else if (ref.read(workoutProvider).startPrompt != null) {
          notifier.dismissStart();
        } else {
          notifier.dismissStop();
        }
      }
      _schedule();
    });
  }

  @override
  Widget build(BuildContext context) {
    _active = TickerMode.valuesOf(context).enabled;
    ref.listen(workoutProvider, (_, _) => _schedule());
    _schedule();
    return widget.child;
  }
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: child,
    ),
  );
}

class _WorkoutPrompt extends ConsumerWidget {
  const _WorkoutPrompt();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workoutProvider);
    final notifier = ref.read(workoutProvider.notifier);
    final start = state.startPrompt;
    final stop = state.stopPrompt;
    if (start == null && stop == null) return const SizedBox.shrink();
    final remaining = (start?.deadline ?? stop!.deadline).difference(state.now);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          start != null
              ? 'Start ${start.type.label.toLowerCase()}?'
              : 'Stop workout?',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(
          start != null
              ? 'Looks like you’re ${activityVerb(start.type)}. Your workout will include the time since ${DateFormat.Hm().format(start.activityStartedAt.toLocal())}.'
              : 'You’ve stopped moving. Finish this workout?',
        ),
        const SizedBox(height: 8),
        Text(
          '${start != null ? 'Prompt closes' : 'Ends at your last movement'} in ${workoutDuration(remaining)}',
        ),
        if (state.simulator) const Text('Countdown uses simulator time (20×).'),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: start != null
              ? () => notifier.acceptStart(start.type)
              : notifier.acceptStop,
          child: Text(
            start != null ? 'Start ${start.type.label}' : 'Finish workout',
          ),
        ),
        if (start != null)
          for (final alternative in start.alternatives)
            OutlinedButton(
              onPressed: () => notifier.acceptStart(alternative),
              child: Text('Start ${alternative.label} instead'),
            ),
        TextButton(
          onPressed: start != null
              ? notifier.dismissStart
              : notifier.dismissStop,
          child: Text(start != null ? 'Not now' : 'Keep going'),
        ),
      ],
    );
  }
}

Future<void> showWorkoutSummary(BuildContext context, WorkoutSession session) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SheetBody(child: WorkoutSummary(session: session)),
    );

class WorkoutSummary extends StatelessWidget {
  const WorkoutSummary({super.key, required this.session});
  final WorkoutSession session;

  @override
  Widget build(BuildContext context) {
    final time = DateFormat('MMM d, HH:mm');
    final pace = session.pace;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${session.type.label} summary',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Chip(
            label: Text(
              session.source == WorkoutSource.auto ? 'Auto-detected' : 'Manual',
            ),
          ),
        ),
        Text(
          '${time.format(session.startedAt.toLocal())} – ${time.format((session.endedAt ?? session.measuredAt).toLocal())}',
        ),
        const SizedBox(height: 16),
        Text('Duration: ${workoutDuration(session.duration)}'),
        Text('Steps: ${session.steps}'),
        Text(
          'Distance: ${(session.distanceMeters / 1000).toStringAsFixed(2)} km',
        ),
        Text('Calories: ${session.calories.toStringAsFixed(0)} kcal'),
        Text('Pace: ${pace == null ? '—' : '${workoutDuration(pace)} min/km'}'),
        const SizedBox(height: 8),
        Text(
          'Distance and calories are estimates based on steps, stride and weight.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
