import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../core/widgets/app_card.dart';
import '../../data/auth_repository.dart';
import '../../data/health_repository.dart';
import '../../data/providers.dart';
import '../auth/auth_screens.dart' show healthDisclosure;
import '../workouts/ui/workout_settings_section.dart';
import 'export_file.dart';
import 'widgets/delete_data_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _working, _error;
  bool get _busy => _working != null;

  Future<void> _signOut() async {
    setState(() { _working = 'Signing out…'; _error = null; });
    try {
      await ref.read(authRepositoryProvider).signOut();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not sign out. Please try again.');
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  Future<void> _export(BuildContext originContext) async {
    if (_busy) return;
    final box = originContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() { _working = 'Exporting your data…'; _error = null; });
    try {
      final json = await ref.read(healthRepositoryProvider).exportData();
      if (!mounted) return;
      await ref.read(exportShareProvider)(
        exportShareParams(json, ref.read(todayDateProvider), origin: origin),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is UserFacingException
            ? error.message : 'Could not share your export. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  Future<void> _delete({required bool account}) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => DeleteDataDialog(account: account),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _working = account ? 'Deleting your account…' : 'Deleting your health data…';
      _error = null;
    });
    try {
      await ref.read(healthRepositoryProvider).deleteData(account: account);
      if (!mounted) return;
      if (account) {
        // The server has removed the account; clear this device's session.
        await ref.read(authRepositoryProvider).signOut();
      } else {
        // Health consent is withdrawn by the server. Keep Settings open.
        ref.read(consentDeferredProvider.notifier).defer();
        ref.read(connectionDeferredProvider.notifier).defer();
        ref.invalidate(profileProvider);
        ref.invalidate(connectionProvider);
        ref.invalidate(todayDataProvider);
        ref.invalidate(trendsDataProvider);
        ref.invalidate(coachThreadProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Your health data and coach history were deleted.')),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is UserFacingException
            ? error.message : account
            ? 'Could not finish deleting your account. Please try again.'
            : 'Could not delete your health data. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  void _showPrivacyNotice() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Privacy notice'),
      content: const SingleChildScrollView(child: Text(healthDisclosure)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final configured = ref.watch(backendConfiguredProvider);
    final user = ref.watch(currentUserProvider);
    final connection = ref.watch(connectionProvider);
    final canAct = configured && user != null && !_busy;
    final active = connection.value?.isActive == true;
    final email = user?.email;
    final status = !configured ? 'Backend not configured' : connection.when(
      data: (value) => switch (value?.status) {
        ConnectionStatus.active => 'Connected',
        ConnectionStatus.revoked => 'Connection revoked',
        ConnectionStatus.error => 'Connection needs attention',
        null => 'Not connected',
      },
      loading: () => 'Checking connection…',
      error: (_, _) => 'Could not check connection',
    );
    final lastSynced = connection.value?.lastSyncedAt;
    final danger = scheme.error;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: AppSpace.page,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppCard(
                    padding: const EdgeInsets.fromLTRB(AppSpace.l, 14, 14, 14),
                    child: Row(children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: scheme.primaryContainer,
                        foregroundColor: scheme.primary,
                        child: email == null || email.isEmpty
                            ? const Icon(Icons.person_outline)
                            : Text(email.characters.first.toUpperCase(),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: scheme.primary)),
                      ),
                      const SizedBox(width: AppSpace.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Account', style: theme.textTheme.titleSmall),
                            Text(
                              email ?? (configured ? 'Not signed in' : 'Backend not configured'),
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      if (configured && user != null)
                        OutlinedButton(
                          onPressed: _busy ? null : _signOut,
                          child: Text(_working == 'Signing out…' ? 'Signing out…' : 'Sign out'),
                        ),
                    ]),
                  ),
                  const SizedBox(height: AppSpace.m),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          MetricIcon(
                            icon: Icons.watch_outlined,
                            color: scheme.onSurface,
                            tint: scheme.surfaceContainer,
                          ),
                          const SizedBox(width: AppSpace.m),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Google Health', style: theme.textTheme.titleSmall),
                                Text(
                                  lastSynced == null
                                      ? 'Not synced yet'
                                      : 'Synced ${DateFormat('MMM d, h:mm a', 'en_US').format(lastSynced.toLocal())}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          _StatusPill(label: status, ok: active),
                        ]),
                        if (configured && user != null) ...[
                          const SizedBox(height: AppSpace.l),
                          if (active)
                            OutlinedButton(
                              onPressed: _busy ? null : () => context.go('/connect'),
                              child: const Text('Manage connection'),
                            )
                          else
                            FilledButton(
                              onPressed: _busy ? null : () => context.go('/connect'),
                              child: const Text('Connect'),
                            ),
                        ],
                        if (connection.hasError)
                          TextButton(
                            onPressed: _busy ? null : () => ref.invalidate(connectionProvider),
                            child: const Text('Retry connection status'),
                          ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpace.m),
                    Semantics(
                      liveRegion: true,
                      child: Text(_error!, style: TextStyle(color: danger)),
                    ),
                  ],
                  if (_busy) ...[
                    const SizedBox(height: AppSpace.m),
                    const LinearProgressIndicator(),
                    const SizedBox(height: AppSpace.xs),
                    Semantics(liveRegion: true, child: Text(_working!)),
                  ],
                  const SizedBox(height: AppSpace.xl),
                  const SectionHeader('Workouts'),
                  const WorkoutSettingsSection(),
                  const SizedBox(height: AppSpace.xl),
                  const SectionHeader('Your data'),
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      Builder(builder: (originContext) => ListTile(
                        leading: const Icon(Icons.ios_share),
                        title: const Text('Export my data'),
                        subtitle: const Text('Daily summaries and coach history as a JSON file'),
                        trailing: const Icon(Icons.chevron_right),
                        enabled: canAct,
                        onTap: canAct ? () => _export(originContext) : null,
                      )),
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.shield_outlined),
                        title: const Text('Privacy notice'),
                        subtitle: const Text('Only daily summaries are stored, never raw readings'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _showPrivacyNotice,
                      ),
                    ]),
                  ),
                  const SizedBox(height: AppSpace.xl),
                  const SectionHeader('Delete'),
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [
                      ListTile(
                        leading: Icon(Icons.delete_outline, color: canAct ? danger : null),
                        title: Text('Delete health data',
                          style: TextStyle(color: canAct ? danger : null)),
                        subtitle: const Text('Disconnects Google Health. Your account stays.'),
                        enabled: canAct,
                        onTap: canAct ? () => _delete(account: false) : null,
                      ),
                      const Divider(),
                      ListTile(
                        leading: Icon(Icons.person_remove_outlined, color: canAct ? danger : null),
                        title: Text('Delete account',
                          style: TextStyle(color: canAct ? danger : null)),
                        subtitle: const Text('Permanently removes your account and all data'),
                        enabled: canAct,
                        onTap: canAct ? () => _delete(account: true) : null,
                      ),
                    ]),
                  ),
                  const SizedBox(height: AppSpace.xl),
                  Text(
                    'For general wellness, not medical advice.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.ok});
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: ok ? scheme.primaryContainer : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 6, height: 6,
          decoration: BoxDecoration(
            color: ok ? scheme.primary : scheme.onSurfaceVariant,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: ok ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        )),
      ]),
    );
  }
}
