import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/activity_sample.dart';
import '../workout_provider.dart';
import 'workout_sheets.dart';

class WorkoutSettingsSection extends ConsumerStatefulWidget {
  const WorkoutSettingsSection({super.key});

  @override
  ConsumerState<WorkoutSettingsSection> createState() =>
      _WorkoutSettingsSectionState();
}

class _WorkoutSettingsSectionState
    extends ConsumerState<WorkoutSettingsSection> {
  late final TextEditingController _weight;
  String? _weightError;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    final weight = ref.read(workoutProvider).weightKg;
    _weight = TextEditingController(
      text: weight == weight.roundToDouble()
          ? weight.toStringAsFixed(0)
          : '$weight',
    );
  }

  @override
  void dispose() {
    _weight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(workoutProvider);
    final notifier = ref.read(workoutProvider.notifier);
    return WorkoutPromptHost(
      child: Card(
        child: ExpansionTile(
          title: Text(
            'Workout detection',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto-start prompts'),
                    subtitle: const Text(
                      'Ask before starting a detected workout',
                    ),
                    value: state.autoStart,
                    onChanged: notifier.setAutoStart,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto-stop prompts'),
                    subtitle: const Text(
                      'Ask after 5 minutes without movement',
                    ),
                    value: state.autoStop,
                    onChanged: notifier.setAutoStop,
                  ),
                  TextField(
                    key: const Key('workout-weight'),
                    controller: _weight,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Weight (kg)',
                      helperText:
                          'Used for calorie estimates in your next workout',
                      errorText: _weightError,
                    ),
                    onChanged: (value) {
                      final weight = double.tryParse(
                        value.replaceAll(',', '.'),
                      );
                      final valid =
                          weight != null && notifier.setWeight(weight);
                      setState(
                        () => _weightError = valid
                            ? null
                            : 'Enter a weight from 20 to 400 kg',
                      );
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Workout simulator'),
                    subtitle: Text(
                      state.session != null
                          ? 'Finish your workout before changing sources'
                          : '20× speed · ten-minute walk prompt in about 30 seconds',
                    ),
                    value: state.simulator,
                    onChanged: _switching || state.session != null
                        ? null
                        : (enabled) async {
                            setState(() => _switching = true);
                            try {
                              await notifier.setSimulator(enabled);
                            } finally {
                              if (mounted) setState(() => _switching = false);
                            }
                          },
                  ),
                  if (state.simulator) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () =>
                              notifier.simulate(ActivityType.walking),
                          child: const Text('Simulate walk'),
                        ),
                        OutlinedButton(
                          onPressed: () =>
                              notifier.simulate(ActivityType.running),
                          child: const Text('Simulate run'),
                        ),
                        OutlinedButton(
                          onPressed: () =>
                              notifier.simulate(ActivityType.still),
                          child: const Text('Stop moving'),
                        ),
                      ],
                    ),
                    const Text(
                      'Updates every 15 seconds. Use Start when prompted, then Stop moving to see the stop prompt.',
                    ),
                  ],
                  if (state.sensorNotice != null) Text(state.sensorNotice!),
                  const SizedBox(height: 8),
                  Text(
                    'Signed-in workouts sync with health consent. Other workouts and settings last for this app session. Detection works while the app is running.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
