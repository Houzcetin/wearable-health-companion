import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../features/trends/domain/trends.dart';
import 'auth_repository.dart';
import 'coach_repository.dart';
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

final coachRepositoryProvider = Provider<CoachRepository>(
  (ref) => SupabaseCoachRepository(ref.watch(supabaseClientProvider)!),
);

/// The platform boundary is replaceable in widget tests.
final exportShareProvider = Provider<Future<void> Function(ShareParams)>((ref) {
  return (params) async {
    await SharePlus.instance.share(params);
  };
});

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
  final profile = await ref.watch(profileProvider.future);
  if (profile?.hasHealthConsent != true) return TodayData(today: today);
  final connection = await ref.watch(connectionProvider.future);
  // With consent, fetch even when not connected: demo rows may exist before
  // a device does.
  final rows = await repository.fetchDailyMetrics(userId, today);
  return TodayData(today: today, connection: connection, rows: rows);
});

final trendsDataProvider = FutureProvider.family<TrendsData,
    (TrendMetric, TrendRange)>((ref, selection) async {
  final (metric, range) = selection;
  final end = civilDate(ref.watch(todayDateProvider));
  TrendsData empty() => TrendsData(metric: metric, range: range, end: end);
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  if (!ref.watch(backendConfiguredProvider) || userId == null) return empty();
  final repository = ref.watch(healthRepositoryProvider);
  final profile = await ref.watch(profileProvider.future);
  if (profile?.hasHealthConsent != true) return empty();
  final connection = await ref.watch(connectionProvider.future);
  final periodStart = end.subtract(Duration(days: range.days - 1));
  final baselineStart = end.subtract(const Duration(days: 28));
  final rows = await repository.fetchRange(
    userId, periodStart.isBefore(baselineStart) ? periodStart : baselineStart, end,
  );
  return TrendsData(
    metric: metric, range: range, end: end, connection: connection, rows: rows,
  );
});

class CoachThread {
  const CoachThread({
    this.messages = const [],
    this.threadId,
    this.sending = false,
    this.error,
    this.failedQuestion,
  });
  final List<CoachMessage> messages;
  final String? threadId, failedQuestion;
  final bool sending;
  final CoachException? error;
}

class CoachThreadNotifier extends AsyncNotifier<CoachThread> {
  int _version = 0;

  @override
  Future<CoachThread> build() async {
    _version++;
    final userId = ref.watch(currentUserProvider.select((user) => user?.id));
    if (!ref.watch(backendConfiguredProvider) || userId == null) {
      return const CoachThread();
    }
    final profile = await ref.watch(profileProvider.future);
    if (profile?.coachConsentAt == null) return const CoachThread();
    final messages = await ref.watch(coachRepositoryProvider).latestThread(userId);
    return CoachThread(
      messages: messages,
      threadId: messages.isEmpty ? null : messages.last.threadId,
    );
  }

  void newChat() {
    if (state.isLoading || state.value?.sending == true) return;
    _version++;
    state = const AsyncData(CoachThread());
  }

  Future<void> send(String question) => _ask(question.trim());

  Future<void> retry() async {
    final question = state.value?.failedQuestion;
    if (question != null) await _ask(question, retry: true);
  }

  Future<void> _ask(String question, {bool retry = false}) async {
    final current = state.asData?.value;
    if (current == null || current.sending || question.isEmpty ||
        question.length > 500) {
      return;
    }
    final version = _version;
    final messages = [
      ...current.messages,
      if (!retry) CoachMessage(
        threadId: current.threadId ?? '', role: 'user', content: question,
      ),
    ];
    state = AsyncData(CoachThread(
      messages: messages, threadId: current.threadId, sending: true,
    ));
    try {
      final reply = await ref.read(coachRepositoryProvider).ask(
        question, threadId: current.threadId,
      );
      if (!ref.mounted || version != _version) return;
      state = AsyncData(CoachThread(
        threadId: reply.threadId,
        messages: [
          ...messages,
          CoachMessage(
            threadId: reply.threadId, role: 'assistant', content: reply.answer,
            facts: reply.facts, isDemo: reply.isDemo,
          ),
        ],
      ));
    } catch (error) {
      if (!ref.mounted || version != _version) return;
      state = AsyncData(CoachThread(
        messages: messages, threadId: current.threadId,
        error: mapCoachError(error), failedQuestion: question,
      ));
    }
  }
}

final coachThreadProvider = AsyncNotifierProvider<CoachThreadNotifier, CoachThread>(
  CoachThreadNotifier.new,
);

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
