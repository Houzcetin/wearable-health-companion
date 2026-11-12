import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/health_repository.dart';
import '../../data/providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _signingOut = false;
  String? _error;

  Future<void> _signOut() async {
    setState(() {
      _signingOut = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).signOut();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not sign out. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(backendConfiguredProvider);
    final user = ref.watch(currentUserProvider);
    final connection = ref.watch(connectionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Account'),
            subtitle: Text(
              user?.email ??
                  (configured ? 'Not signed in' : 'Backend not configured'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.watch_outlined),
            title: const Text('Google Health'),
            subtitle: Text(
              !configured
                  ? 'Backend not configured'
                  : connection.when(
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
            trailing: !configured || user == null
                ? null
                : TextButton(
                    onPressed: () => context.go('/connect'),
                    child: Text(
                      connection.value?.isActive == true
                          ? 'Connected'
                          : 'Connect',
                    ),
                  ),
          ),
          if (connection.hasError)
            TextButton(
              onPressed: () => ref.invalidate(connectionProvider),
              child: const Text('Retry connection status'),
            ),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (configured && user != null)
            OutlinedButton.icon(
              onPressed: _signingOut ? null : _signOut,
              icon: const Icon(Icons.logout),
              label: Text(_signingOut ? 'Signing out…' : 'Sign out'),
            ),
          const SizedBox(height: 24),
          const ListTile(
            title: Text('Your data'),
            subtitle: Text(
              'Export, delete and sharing controls arrive in a later update.',
            ),
          ),
        ],
      ),
    );
  }
}
