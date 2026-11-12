import 'package:flutter/material.dart';

const coachDisclosure =
    'The coach uses Claude, an AI model from Anthropic. '
    'When you ask a question, your question and your daily summaries '
    '(sleep, heart rate and activity) are sent to Anthropic to write the answer. '
    'Raw readings are not sent. '
    'Answers describe patterns and are not medical advice. '
    'You can delete your coach history any time by deleting your health data in Settings.';

class CoachConsentCard extends StatelessWidget {
  const CoachConsentCard({
    super.key, required this.busy, required this.onAllow,
    required this.onNotNow, this.error,
  });
  final bool busy;
  final VoidCallback onAllow, onNotNow;
  final String? error;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Your coach consent', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(coachDisclosure),
          const SizedBox(height: 16),
          if (error != null)
            Semantics(liveRegion: true, child: Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (busy) const LinearProgressIndicator(),
          FilledButton(onPressed: busy ? null : onAllow,
            child: const Text('Allow coach')),
          TextButton(onPressed: busy ? null : onNotNow,
            child: const Text('Not now')),
        ],
      ),
    ),
  );
}
