import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/core/router.dart';
import 'package:wearable_companion/data/auth_repository.dart';
import 'package:wearable_companion/data/health_repository.dart';
import 'package:wearable_companion/data/providers.dart';
import 'package:wearable_companion/main.dart';

import 'support/fake_repositories.dart';

void main() {
  Future<ProviderContainer> start(
    WidgetTester tester, {
    required FakeAuthRepository auth,
    required FakeProfileRepository profile,
    required FakeHealthRepository health,
  }) async {
    addTearDown(auth.close);
    final container = ProviderContainer(
      overrides: [
        backendConfiguredProvider.overrideWithValue(true),
        authRepositoryProvider.overrideWithValue(auth),
        profileRepositoryProvider.overrideWithValue(profile),
        healthRepositoryProvider.overrideWithValue(health),
        todayDateProvider.overrideWithValue(testToday),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HealthCompanionApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
    'signed out starts at disclosure, sign-in then consent and connect',
    (tester) async {
      final auth = FakeAuthRepository(user: null);
      final profile = FakeProfileRepository(consented: false);
      final health = FakeHealthRepository(connection: null);
      await start(tester, auth: auth, profile: profile, health: health);
      expect(find.text('See what changed from your usual'), findsOneWidget);
      expect(
        find.textContaining('Only daily summaries are stored'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Sign in with Google'));
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();
      expect(find.text('Your health-data consent'), findsOneWidget);
      expect(health.connections, 0);
      await tester.ensureVisible(find.text('I agree'));
      await tester.tap(find.text('I agree'));
      await tester.pumpAndSettle();
      expect(profile.grants, 1);
      expect(find.text('Connect Google Health'), findsWidgets);
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Connect Google Health'),
      );
      await tester.tap(
        find.widgetWithText(FilledButton, 'Connect Google Health'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
    },
  );

  testWidgets(
    'Not now permits shell without reading health; CTA returns to consent',
    (tester) async {
      final profile = FakeProfileRepository(consented: false);
      final health = FakeHealthRepository(connection: null);
      await start(
        tester,
        auth: FakeAuthRepository(),
        profile: profile,
        health: health,
      );
      await tester.ensureVisible(find.text('Not now'));
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(
        find.text('Connect Google Health to see your daily summary.'),
        findsOneWidget,
      );
      expect(health.connections, 0);
      expect(health.fetches, 0);
      expect(profile.grants, 0);
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Connect Google Health'),
      );
      await tester.tap(
        find.widgetWithText(FilledButton, 'Connect Google Health'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your health-data consent'), findsOneWidget);
    },
  );

  testWidgets('skip connection permits shell and can return to connect', (
    tester,
  ) async {
    await start(
      tester,
      auth: FakeAuthRepository(),
      profile: FakeProfileRepository(),
      health: FakeHealthRepository(connection: null),
    );
    await tester.ensureVisible(find.text('Skip for now'));
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(
      find.text('Connect Google Health to see your daily summary.'),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Connect Google Health'),
    );
    await tester.tap(
      find.widgetWithText(FilledButton, 'Connect Google Health'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Skip for now'), findsOneWidget);
  });

  testWidgets('auth stream signs out and resets account deferrals', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    final container = await start(
      tester,
      auth: auth,
      profile: FakeProfileRepository(),
      health: FakeHealthRepository(rows: history()),
    );
    expect(find.text('Sleep'), findsOneWidget);
    auth.emit(null);
    await tester.pumpAndSettle();
    expect(find.text('See what changed from your usual'), findsOneWidget);
    expect(container.read(consentDeferredProvider), isFalse);
    expect(container.read(connectionDeferredProvider), isFalse);
  });

  testWidgets('settings shows email, connection and signs out', (tester) async {
    await start(
      tester,
      auth: FakeAuthRepository(),
      profile: FakeProfileRepository(),
      health: FakeHealthRepository(rows: history()),
    );
    await tester.ensureVisible(find.byIcon(Icons.settings_outlined));
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('reader@example.com'), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);
    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('See what changed from your usual'), findsOneWidget);
  });

  testWidgets(
    'refresh keeps an existing account on Today when connection is revoked',
    (tester) async {
      final health = FakeHealthRepository(rows: history());
      final container = await start(
        tester,
        auth: FakeAuthRepository(),
        profile: FakeProfileRepository(),
        health: health,
      );
      health.connection = const HealthConnection(
        status: ConnectionStatus.revoked,
      );
      container.invalidate(connectionProvider);
      await tester.pumpAndSettle();
      expect(find.text('Google Health connection revoked'), findsOneWidget);
      expect(find.text('Reconnect Google Health'), findsOneWidget);
      expect(
        container.read(routerProvider).routeInformationProvider.value.uri.path,
        '/today',
      );
    },
  );

  testWidgets('cancelled sign-in is visible and retry remains available', (
    tester,
  ) async {
    final auth = FakeAuthRepository(user: null)
      ..signInError = const UserFacingException(
        'Sign-in was cancelled. You can try again when ready.',
      );
    await start(
      tester,
      auth: auth,
      profile: FakeProfileRepository(consented: false),
      health: FakeHealthRepository(connection: null),
    );
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign in with Google'));
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sign-in was cancelled.'), findsOneWidget);
    auth.signInError = null;
    await tester.ensureVisible(find.text('Sign in with Google'));
    await tester.tap(find.text('Sign in with Google'));
    await tester.pumpAndSettle();
    expect(find.text('Your health-data consent'), findsOneWidget);
  });

  testWidgets('connection error is visible and retry completes', (
    tester,
  ) async {
    final health = FakeHealthRepository(connection: null)
      ..connectError = const UserFacingException(
        'Google Health access was declined. You can try again when ready.',
      );
    await start(
      tester,
      auth: FakeAuthRepository(),
      profile: FakeProfileRepository(),
      health: health,
    );
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Connect Google Health'),
    );
    await tester.tap(
      find.widgetWithText(FilledButton, 'Connect Google Health'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('access was declined'), findsOneWidget);
    health.connectError = null;
    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Sleep'), findsOneWidget);
  });

  testWidgets('same-account session refresh preserves the selected tab', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    final profile = FakeProfileRepository();
    final health = FakeHealthRepository(rows: history());
    await start(tester, auth: auth, profile: profile, health: health);
    await tester.tap(find.byIcon(Icons.show_chart));
    await tester.pumpAndSettle();
    final profileFetches = profile.fetches;
    final healthFetches = health.fetches;
    auth.emit(const AppUser(id: 'user-a', email: 'reader@example.com'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This week you averaged'), findsOneWidget);
    expect(profile.fetches, profileFetches);
    expect(health.fetches, healthFetches);
  });

  testWidgets('switching accounts requires the new account consent', (
    tester,
  ) async {
    final auth = FakeAuthRepository();
    final container = await start(
      tester,
      auth: auth,
      profile: FakeProfileRepository(consented: false),
      health: FakeHealthRepository(connection: null),
    );
    await tester.ensureVisible(find.text('Not now'));
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(
      find.text('Connect Google Health to see your daily summary.'),
      findsOneWidget,
    );
    auth.emit(const AppUser(id: 'user-b', email: 'another@example.com'));
    await tester.pumpAndSettle();
    expect(find.text('Your health-data consent'), findsOneWidget);
    expect(container.read(consentDeferredProvider), isFalse);
    expect(container.read(connectionDeferredProvider), isFalse);
  });
}
