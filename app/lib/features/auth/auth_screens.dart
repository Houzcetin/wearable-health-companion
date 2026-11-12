import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/auth_repository.dart';
import '../../data/providers.dart';

const healthDisclosure =
    'We read sleep, heart rate and activity from Google Health to show your '
    'daily summary, trends and coach insights. Only daily summaries are stored, '
    'never raw readings. This is for general wellness and is not medical advice. '
    'Your data can be exported and deleted.';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context) => _AuthPage(
    title: 'See what changed from your usual',
    icon: Icons.wb_sunny_outlined,
    children: [
      const Text(
        'A calmer way to check your sleep, heart and activity each day.',
      ),
      const SizedBox(height: 24),
      Text(
        'Your health data, your choice',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      const Text(healthDisclosure),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: () => context.go('/sign-in'),
        child: const Text('Continue'),
      ),
    ],
  );
}

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).signInWithGoogle();
      if (mounted) context.go('/consent');
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = _message(error, 'Could not sign in. Please try again.'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthPage(
    title: 'Sign in',
    icon: Icons.person_outline,
    children: [
      const Text(
        'Use your Google account. This step only shares your basic identity, '
        'such as your name and email. You choose whether to connect health data next.',
      ),
      const SizedBox(height: 24),
      if (_error != null) _ErrorText(_error!),
      if (_busy) const _Progress('Signing in…'),
      FilledButton.icon(
        onPressed: _busy ? null : _signIn,
        icon: const Icon(Icons.login),
        label: const Text('Sign in with Google'),
      ),
      TextButton(
        onPressed: _busy ? null : () => context.go('/welcome'),
        child: const Text('Read the disclosure'),
      ),
    ],
  );
}

class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key});
  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _agree() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(profileRepositoryProvider).grantHealthConsent(user.id);
      // Read the trigger-owned timestamp back; never set consent locally.
      ref.invalidate(profileProvider);
      final profile = await ref.read(profileProvider.future);
      if (profile?.hasHealthConsent != true) {
        throw const UserFacingException(
          'Consent has not been saved yet. Please try again.',
        );
      }
      if (mounted) context.go('/connect');
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = _message(
            error,
            'Could not save your consent. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    return _AuthPage(
      title: 'Your health-data consent',
      icon: Icons.privacy_tip_outlined,
      children: [
        const Text(healthDisclosure),
        const SizedBox(height: 16),
        const Text(
          'By choosing “I agree”, you allow us to process these daily health '
          'summaries. Connecting Google Health is a separate step. '
          'You can choose “Not now” and use the app without connecting.',
        ),
        const SizedBox(height: 24),
        if (profile.isLoading) const _Progress('Loading your account…'),
        if (profile.hasError) ...[
          const _ErrorText(
            'Could not load your account or update its timezone. Please try again.',
          ),
          OutlinedButton(
            onPressed: () => ref.invalidate(profileProvider),
            child: const Text('Retry'),
          ),
        ],
        if (_error != null) _ErrorText(_error!),
        if (_busy) const _Progress('Saving your consent…'),
        FilledButton(
          onPressed: _busy || !profile.hasValue || profile.hasError
              ? null
              : _agree,
          child: const Text('I agree'),
        ),
        TextButton(
          onPressed: _busy || !profile.hasValue || profile.hasError
              ? null
              : () {
                  ref.read(consentDeferredProvider.notifier).defer();
                  ref.read(connectionDeferredProvider.notifier).defer();
                  context.go('/today');
                },
          child: const Text('Not now'),
        ),
      ],
    );
  }
}

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});
  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  bool _busy = false;
  String? _error;
  String _progress = 'Opening Google Health…';

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = 'Opening Google Health…';
    });
    try {
      await ref.read(healthRepositoryProvider).connect();
      if (!mounted) return;
      setState(() => _progress = 'Checking your connection…');
      // The server owns status; a browser callback alone is not enough.
      ref.invalidate(connectionProvider);
      final connection = await ref.read(connectionProvider.future);
      if (connection?.isActive != true) {
        throw const UserFacingException(
          'Your connection is not active yet. Please try again.',
        );
      }
      ref.invalidate(todayDataProvider);
      if (mounted) context.go('/today');
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = _message(
            error,
            'Could not connect Google Health. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    return _AuthPage(
      title: 'Connect Google Health',
      icon: Icons.watch_outlined,
      children: [
        const Text(
          'Allow read access to your sleep, heart rate and activity. '
          'Google will ask you to approve access in a secure browser window.',
        ),
        const SizedBox(height: 12),
        const Text(
          'After connecting, use “Sync now” on Today to fetch your first daily summary.',
        ),
        const SizedBox(height: 24),
        if (connection.isLoading && !_busy)
          const _Progress('Checking your connection…'),
        if (connection.hasError) ...[
          const _ErrorText('Could not check your connection.'),
          OutlinedButton(
            onPressed: () => ref.invalidate(connectionProvider),
            child: const Text('Retry status'),
          ),
        ],
        if (_error != null) _ErrorText(_error!),
        if (_busy) _Progress(_progress),
        FilledButton.icon(
          onPressed: _busy ? null : _connect,
          icon: const Icon(Icons.link),
          label: Text(_error == null ? 'Connect Google Health' : 'Try again'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  ref.read(connectionDeferredProvider.notifier).defer();
                  context.go('/today');
                },
          child: const Text('Skip for now'),
        ),
      ],
    );
  }
}

String _message(Object error, String fallback) =>
    error is UserFacingException ? error.message : fallback;

class _AuthPage extends StatelessWidget {
  const _AuthPage({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(
                    icon,
                    size: 40,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 24),
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 16),
                ...children,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Progress extends StatelessWidget {
  const _Progress(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    ),
  );
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Semantics(
      liveRegion: true,
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    ),
  );
}
