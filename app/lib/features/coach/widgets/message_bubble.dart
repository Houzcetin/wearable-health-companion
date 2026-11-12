import 'package:flutter/material.dart';

import '../../../data/coach_repository.dart';
import 'numbers_used.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});
  final CoachMessage message;
  @override
  Widget build(BuildContext context) => Align(
    alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Card(
        color: message.isUser ? Theme.of(context).colorScheme.primaryContainer : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                label: message.isUser ? 'You' : 'Coach',
                child: Text(message.content),
              ),
              if (!message.isUser) ...[
                if (message.isDemo)
                  const Chip(
                    avatar: Icon(Icons.science_outlined, size: 18),
                    label: Text('Demo data'),
                  ),
                NumbersUsed(facts: message.facts),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
