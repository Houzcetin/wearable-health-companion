import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wearable_companion/core/router.dart';
import 'package:wearable_companion/data/auth_repository.dart';
import 'package:wearable_companion/data/providers.dart';
import 'package:wearable_companion/features/settings/settings_screen.dart';
import 'package:wearable_companion/features/trends/domain/trends.dart';

import 'support/fake_repositories.dart';
import 'support/stage5_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> tapAction(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    // Lay out the scrolled list before tapping where the row now is.
    await tester.pump();
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets('export calls the repository and shares a named JSON file', (tester) async {
    final health = FakeHealthRepository();
    ShareParams? shared;
    await startStage5(tester, screen: const SettingsScreen(), health: health,
      share: (params) async { shared = params; });
    await tapAction(tester, 'Export my data');
    expect(health.exports, 1);
    expect(shared!.fileNameOverrides, ['wearable-companion-export-2026-11-12.json']);
    expect(shared!.files!.single.mimeType, 'application/json');
    expect(await shared!.files!.single.readAsString(), health.exportJson);
  });

  testWidgets('export shows progress and prevents duplicate requests', (tester) async {
    final health = FakeHealthRepository()..exportCompleter = Completer<String>();
    await startStage5(tester, screen: const SettingsScreen(), health: health);
    await tester.ensureVisible(find.text('Export my data'));
    await tester.tap(find.text('Export my data'));
    await tester.pump();
    expect(find.text('Exporting your data…'), findsOneWidget);
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Export my data')).enabled,
      isFalse);
    expect(health.exports, 1);
    health.exportCompleter!.complete(health.exportJson);
    await tester.pumpAndSettle();
    expect(find.text('Exporting your data…'), findsNothing);
  });

  testWidgets('export and sharing errors remain visible', (tester) async {
    final health = FakeHealthRepository()
      ..exportError = const UserFacingException('Could not export your data.');
    await startStage5(tester, screen: const SettingsScreen(), health: health);
    await tapAction(tester, 'Export my data');
    expect(find.text('Could not export your data.'), findsOneWidget);
    health.exportError = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await startStage5(tester, screen: const SettingsScreen(), health: health,
      share: (_) async { throw Exception('platform failure'); });
    await tapAction(tester, 'Export my data');
    expect(find.text('Could not share your export. Please try again.'), findsOneWidget);
  });

  for (final account in [false, true]) {
    testWidgets('cancelling ${account ? 'account' : 'health'} deletion does nothing', (tester) async {
      final health = FakeHealthRepository();
      final auth = FakeAuthRepository();
      await startStage5(tester, screen: const SettingsScreen(), health: health, auth: auth);
      await tapAction(tester, account ? 'Delete account' : 'Delete health data');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(health.deletions, isEmpty);
      expect(auth.signOuts, 0);
    });
  }

  testWidgets('health deletion confirms its scope and refreshes cached data', (tester) async {
    final profile = FakeProfileRepository(coachConsented: true);
    final health = FakeHealthRepository(rows: history());
    final coach = FakeCoachRepository();
    health.onDelete = (_) { profile.consented = false; coach.messages = []; };
    final container = await startStage5(tester, screen: const SettingsScreen(),
      profile: profile, health: health, coach: coach);
    await container.read(todayDataProvider.future);
    await container.read(trendsDataProvider((TrendMetric.sleep, TrendRange.week)).future);
    await container.read(coachThreadProvider.future);
    final profileFetches = profile.fetches;
    await tapAction(tester, 'Delete health data');
    expect(find.text('This disconnects Google Health and permanently deletes your '
      'synced data, demo data and coach history. Your account stays.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(health.deletions, [false]);
    expect(find.text('Your health data and coach history were deleted.'), findsOneWidget);
    expect(profile.fetches, greaterThan(profileFetches));
    expect((await container.read(todayDataProvider.future)).rows, isEmpty);
    expect((await container.read(trendsDataProvider(
      (TrendMetric.sleep, TrendRange.week)).future)).rows, isEmpty);
    expect((await container.read(coachThreadProvider.future)).messages, isEmpty);
    expect(container.read(connectionProvider).value, isNull);
    expect(container.read(currentUserProvider), isNotNull);
  });

  testWidgets('account deletion requires exact DELETE, uses account scope and signs out locally',
    (tester) async {
      final auth = FakeAuthRepository();
      final health = FakeHealthRepository();
      final container = await startStage5(tester, auth: auth, health: health);
      container.read(routerProvider).go('/settings');
      await tester.pumpAndSettle();
      await tapAction(tester, 'Delete account');
      FilledButton confirmation() => tester.widget<FilledButton>(
        find.byKey(const Key('confirm-delete')));
      expect(confirmation().onPressed, isNull);
      await tester.enterText(find.byKey(const Key('delete-account-confirmation')), 'delete');
      await tester.pump();
      expect(confirmation().onPressed, isNull);
      expect(health.deletions, isEmpty);
      await tester.enterText(find.byKey(const Key('delete-account-confirmation')), 'DELETE');
      await tester.pump();
      expect(confirmation().onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pumpAndSettle();
      expect(health.deletions, [true]);
      expect(auth.signOuts, 1);
      expect(container.read(routerProvider).routeInformationProvider.value.uri.path, '/welcome');
    });

  testWidgets('deletion failure does not sign out and shows an error', (tester) async {
    final health = FakeHealthRepository()..deleteError = Exception('offline');
    final auth = FakeAuthRepository();
    await startStage5(tester, screen: const SettingsScreen(), auth: auth, health: health);
    await tapAction(tester, 'Delete health data');
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Could not delete your health data. Please try again.'), findsOneWidget);
    expect(auth.signOuts, 0);
  });
}
