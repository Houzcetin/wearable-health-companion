import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../core/widgets/connect_prompt.dart';
import '../../../data/coach_repository.dart';
import 'numbers_used.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});
  final CoachMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = message.isUser;
    const r = Radius.circular(AppRadius.card);
    const tail = Radius.circular(6);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: user ? 360 : 460,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: user ? scheme.primaryContainer : scheme.surfaceContainerLowest,
            border: user ? null : Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.only(
              topLeft: r, topRight: r,
              bottomLeft: user ? r : tail,
              bottomRight: user ? tail : r,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                label: user ? 'You' : 'Coach',
                child: Text(
                  message.content,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    height: 1.45,
                    color: user ? scheme.onPrimaryContainer : scheme.onSurface,
                  ),
                ),
              ),
              if (!user) ...[
                if (message.isDemo) ...[
                  const SizedBox(height: AppSpace.s),
                  const DemoDataChip(),
                ],
                const SizedBox(height: AppSpace.m),
                NumbersUsed(facts: message.facts),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
