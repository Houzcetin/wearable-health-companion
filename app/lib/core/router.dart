import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../features/auth/auth_screens.dart';
import '../features/coach/coach_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/today/today_screen.dart';
import '../features/trends/trends_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  String? accountId;
  bool hasEnteredShell = false;
  void changed() => refresh.value++;
  ref.listen(currentUserProvider, (_, _) => changed());
  ref.listen(profileProvider, (_, _) => changed());
  ref.listen(connectionProvider, (_, _) => changed());
  ref.listen(consentDeferredProvider, (_, _) => changed());
  ref.listen(connectionDeferredProvider, (_, _) => changed());

  final router = GoRouter(
    initialLocation: '/today',
    refreshListenable: refresh,
    redirect: (context, state) {
      if (!ref.read(backendConfiguredProvider)) return null;
      final path = state.uri.path;
      final user = ref.read(currentUserProvider);
      if (accountId != user?.id) {
        accountId = user?.id;
        hasEnteredShell = false;
      }
      if (user == null) {
        return path == '/welcome' || path == '/sign-in' ? null : '/welcome';
      }
      final profile = ref.read(profileProvider);
      if (profile.hasError || profile.value?.userId != user.id) {
        return path == '/consent' ? null : '/consent';
      }
      if (!profile.value!.hasHealthConsent) {
        if (path == '/consent') return null;
        if (!ref.read(consentDeferredProvider) || path == '/connect') {
          return '/consent';
        }
        return path == '/welcome' || path == '/sign-in' ? '/today' : null;
      }
      final connection = ref.read(connectionProvider);
      if (connection.asData?.value?.isActive == true) {
        hasEnteredShell = true;
      }
      if (connection.isLoading ||
          connection.hasError ||
          connection.value?.isActive != true) {
        if (path == '/connect' || path == '/settings') return null;
        if ((!hasEnteredShell && !ref.read(connectionDeferredProvider)) ||
            path == '/welcome' ||
            path == '/sign-in' ||
            path == '/consent') {
          return '/connect';
        }
        return null;
      }
      return ['/welcome', '/sign-in', '/consent', '/connect'].contains(path)
          ? '/today'
          : null;
    },
    routes: [
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomeScreen()),
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      GoRoute(path: '/consent', builder: (_, _) => const ConsentScreen()),
      GoRoute(path: '/connect', builder: (_, _) => const ConnectScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _Shell(shell: shell),
        branches: [
          _branch('/today', const TodayScreen()),
          StatefulShellBranch(routes: [GoRoute(
            path: '/trends',
            builder: (_, state) => TrendsScreen(
              initialMetric: state.uri.queryParameters['metric'],
              launchId: state.extra,
            ),
          )]),
          StatefulShellBranch(routes: [GoRoute(
            path: '/coach',
            builder: (_, state) => CoachScreen(
              initialQuestion: state.uri.queryParameters['q'],
              launchId: state.extra,
            ),
          )]),
          _branch('/settings', const SettingsScreen()),
        ],
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});

StatefulShellBranch _branch(String path, Widget screen) => StatefulShellBranch(
  routes: [GoRoute(path: path, builder: (_, _) => screen)],
);

class _Shell extends StatelessWidget {
  const _Shell({required this.shell});
  final StatefulNavigationShell shell;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: shell,
    // Play (points, streaks, challenges) stays out of the bar until it has
    // real content; an empty tab only costs a tap.
    bottomNavigationBar: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (i) =>
            shell.goBranch(i, initialLocation: i == shell.currentIndex),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.wb_sunny_outlined),
            selectedIcon: Icon(Icons.wb_sunny),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.show_chart),
            selectedIcon: Icon(Icons.insights),
            label: 'Trends',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Coach',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    ),
  );
}
