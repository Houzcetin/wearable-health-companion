import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wearable_companion/core/theme.dart';
import 'package:wearable_companion/data/providers.dart';
import 'package:wearable_companion/main.dart';

import 'fake_repositories.dart';

Future<ProviderContainer> startStage5(
  WidgetTester tester, {
  Widget? screen,
  FakeAuthRepository? auth,
  FakeProfileRepository? profile,
  FakeHealthRepository? health,
  FakeCoachRepository? coach,
  Future<void> Function(ShareParams)? share,
}) async {
  final authRepository = auth ?? FakeAuthRepository();
  addTearDown(authRepository.close);
  final container = ProviderContainer(overrides: [
    backendConfiguredProvider.overrideWithValue(true),
    authRepositoryProvider.overrideWithValue(authRepository),
    profileRepositoryProvider.overrideWithValue(
      profile ?? FakeProfileRepository(coachConsented: true)),
    healthRepositoryProvider.overrideWithValue(
      health ?? FakeHealthRepository(rows: history(nights: 28))),
    coachRepositoryProvider.overrideWithValue(coach ?? FakeCoachRepository()),
    todayDateProvider.overrideWithValue(testToday),
    exportShareProvider.overrideWithValue(share ?? (_) async {}),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: screen == null ? const HealthCompanionApp() : MaterialApp(
      theme: buildTheme(Brightness.light), home: screen),
  ));
  await tester.pumpAndSettle();
  return container;
}
