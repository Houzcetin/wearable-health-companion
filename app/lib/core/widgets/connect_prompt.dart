import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/health_repository.dart';
import '../theme.dart';
import 'app_card.dart';

/// Shown when Google Health is not connected, revoked or needs attention.
class ConnectPrompt extends StatelessWidget {
  const ConnectPrompt({super.key, this.status, this.footer});
  final ConnectionStatus? status;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final revoked = status == ConnectionStatus.revoked;
    final error = status == ConnectionStatus.error;
    return AppCard(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MetricIcon(
            icon: Icons.watch_outlined,
            color: theme.colorScheme.primary,
            tint: theme.colorScheme.primaryContainer,
            size: 44,
          ),
          const SizedBox(height: AppSpace.l),
          Text(
            revoked
                ? 'Google Health connection revoked'
                : error
                ? 'Your Google Health connection needs attention'
                : 'Connect Google Health to see your daily summary.',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpace.s),
          Text(
            'See sleep, heart rate and activity compared with your usual.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpace.xl),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => context.go('/connect'),
              child: Text(revoked || error
                  ? 'Reconnect Google Health'
                  : 'Connect Google Health'),
            ),
          ),
          if (footer != null) ...[
            const SizedBox(height: AppSpace.m),
            footer!,
          ],
        ],
      ),
    );
  }
}

/// The "Demo data" chip shown above sample rows.
class DemoDataChip extends StatelessWidget {
  const DemoDataChip({super.key});
  @override
  Widget build(BuildContext context) => const Align(
    alignment: Alignment.centerLeft,
    child: Chip(
      avatar: Icon(Icons.science_outlined, size: 18),
      label: Text('Demo data'),
    ),
  );
}
