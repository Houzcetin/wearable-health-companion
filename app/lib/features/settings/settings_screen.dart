import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/auth_repository.dart';
import '../../data/health_repository.dart';
import '../../data/providers.dart';
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

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(backendConfiguredProvider);
    final user = ref.watch(currentUserProvider);
    final connection = ref.watch(connectionProvider);
    final canAct = configured && user != null && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Account'),
            subtitle: Text(user?.email ??
              (configured ? 'Not signed in' : 'Backend not configured')),
          ),
          ListTile(
            leading: const Icon(Icons.watch_outlined),
            title: const Text('Google Health'),
            subtitle: Text(
              !configured ? 'Backend not configured' : connection.when(
                data: (value) => switch (value?.status) {
                  ConnectionStatus.active => 'Connected',
                  ConnectionStatus.revoked => 'Connection revoked',
                  ConnectionStatus.error => 'Connection needs attention',
                  null => 'Not connected',
                },
                loading: () => 'Checking connection…',
                error: (_, _) => 'Could not check connection',
              ),
            ),
            trailing: !configured || user == null ? null : TextButton(
              onPressed: _busy ? null : () => context.go('/connect'),
              child: Text(connection.value?.isActive == true ? 'Connected' : 'Connect'),
            ),
          ),
          if (connection.hasError)
            TextButton(
              onPressed: _busy ? null : () => ref.invalidate(connectionProvider),
              child: const Text('Retry connection status'),
            ),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (_busy) ...[
            const LinearProgressIndicator(),
            Semantics(liveRegion: true, child: Text(_working!)),
          ],
          if (configured && user != null)
            OutlinedButton.icon(
              onPressed: _busy ? null : _signOut,
              icon: const Icon(Icons.logout),
              label: Text(_working == 'Signing out…' ? 'Signing out…' : 'Sign out'),
            ),
          const SizedBox(height: 24),
          Text('Your data', style: Theme.of(context).textTheme.titleMedium),
          Builder(builder: (originContext) => ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('Export my data'),
            enabled: canAct,
            onTap: canAct ? () => _export(originContext) : null,
          )),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete health data'),
            enabled: canAct,
            onTap: canAct ? () => _delete(account: false) : null,
          ),
          ListTile(
            leading: const Icon(Icons.person_remove_outlined),
            title: const Text('Delete account'),
            enabled: canAct,
            onTap: canAct ? () => _delete(account: true) : null,
          ),
          const WorkoutSettingsSection(),
        ],
      ),
    );
  }
}
