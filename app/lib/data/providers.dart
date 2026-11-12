import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import 'auth_repository.dart';
import 'daily_metrics.dart';
import 'health_repository.dart';
import 'profile_repository.dart';

final backendConfiguredProvider = Provider<bool>((ref) => Env.hasBackend);
final supabaseClientProvider = Provider<SupabaseClient?>(
  (ref) =>
      ref.watch(backendConfiguredProvider) ? Supabase.instance.client : null,
);
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => SupabaseAuthRepository(ref.watch(supabaseClientProvider)),
);
final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => SupabaseProfileRepository(ref.watch(supabaseClientProvider)!),
);
final healthRepositoryProvider = Provider<HealthRepository>(
  (ref) => SupabaseHealthRepository(ref.watch(supabaseClientProvider)!),
);

final authUserProvider = StreamProvider<AppUser?>(
  (ref) => ref.watch(authRepositoryProvider).authStateChanges,
);
final currentUserProvider = Provider<AppUser?>((ref) {
  final auth = ref.watch(authUserProvider);
  return auth.isLoading
      ? ref.watch(authRepositoryProvider).currentUser
      : auth.value;
});

final profileProvider = FutureProvider<Profile?>((ref) async {
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  if (!ref.watch(backendConfiguredProvider) || userId == null) return null;
  return ref.watch(profileRepositoryProvider).fetchProfile(userId);
});

final connectionProvider = FutureProvider<HealthConnection?>((ref) async {
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  if (!ref.watch(backendConfiguredProvider) || userId == null) return null;
  final repository = ref.watch(healthRepositoryProvider);
  final profile = await ref.watch(profileProvider.future);
  if (profile?.hasHealthConsent != true) return null;
  return repository.fetchConnection(userId);
});

/// Overridable clock. Refreshing or resuming Today invalidates the local date.
final todayDateProvider = Provider<DateTime>((ref) => DateTime.now());

class TodayData {
  const TodayData({required this.today, this.connection, this.rows = const []});
  final DateTime today;
  final HealthConnection? connection;
  final List<DailyMetrics> rows;
}

final todayDataProvider = FutureProvider<TodayData>((ref) async {
  final today = ref.watch(todayDateProvider);
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  if (!ref.watch(backendConfiguredProvider) || userId == null) {
    return TodayData(today: today);
  }
  final repository = ref.watch(healthRepositoryProvider);
  final connection = await ref.watch(connectionProvider.future);
  if (connection?.isActive != true) {
    return TodayData(today: today, connection: connection);
  }
  final rows = await repository.fetchDailyMetrics(userId, today);
  return TodayData(today: today, connection: connection, rows: rows);
});

/// Deferrals last only for the current account in this app session.
class OnboardingDeferral extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(currentUserProvider.select((user) => user?.id));
    return false;
  }

  void defer() => state = true;
}

final consentDeferredProvider = NotifierProvider<OnboardingDeferral, bool>(
  OnboardingDeferral.new,
);
final connectionDeferredProvider = NotifierProvider<OnboardingDeferral, bool>(
  OnboardingDeferral.new,
);
