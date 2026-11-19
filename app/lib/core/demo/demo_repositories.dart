import 'dart:async';

import '../../data/auth_repository.dart';
import '../../data/coach_repository.dart';
import '../../data/daily_metrics.dart';
import '../../data/health_repository.dart';
import '../../data/profile_repository.dart';
import '../../features/workouts/data/motion_history_source.dart';
import '../../features/workouts/domain/activity_sample.dart';
import '../../features/workouts/domain/workout_session.dart';
import 'demo_data.dart';

const demoUser = AppUser(id: 'demo-user', email: 'Demo user');

class DemoAuthRepository implements AuthRepository {
  AppUser? _user = demoUser;
  final _changes = StreamController<AppUser?>.broadcast();

  @override
  AppUser? get currentUser => _user;

  @override
  Stream<AppUser?> get authStateChanges async* {
    yield _user;
    yield* _changes.stream;
  }

  @override
  Future<void> signInWithGoogle() async {
    _user = demoUser;
    _changes.add(_user);
  }

  @override
  Future<void> signOut() async {
    _user = null;
    _changes.add(null);
  }
}

class DemoProfileRepository implements ProfileRepository {
  @override
  Future<Profile> fetchProfile(String userId) async => Profile(
    userId: userId,
    timezone: 'UTC',
    displayName: 'Demo user',
    healthConsentAt: DateTime(2026, 1, 1),
    coachConsentAt: DateTime(2026, 1, 1),
  );

  @override
  Future<void> grantHealthConsent(String userId) async {}

  @override
  Future<void> grantCoachConsent(String userId) async {}
}

class DemoHealthRepository implements HealthRepository {
  @override
  Future<HealthConnection?> fetchConnection(String userId) async =>
      HealthConnection(
        status: ConnectionStatus.active,
        lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 12)),
      );

  @override
  Future<void> connect() async => throw const UserFacingException(
    'Connecting Google Health is not available in demo mode.',
  );

  @override
  Future<SyncResult> requestSync() async =>
      const SyncResult(processed: 0, failed: 0, remaining: 0);

  @override
  Future<List<DailyMetrics>> fetchDailyMetrics(
    String userId,
    DateTime today,
  ) async => demoRows(today);

  @override
  Future<List<DailyMetrics>> fetchRange(
    String userId,
    DateTime start,
    DateTime end,
  ) async => demoRows(end)
      .where((r) => !r.date.isBefore(start) && !r.date.isAfter(end))
      .toList();

  @override
  Future<String> exportData() async => throw const UserFacingException(
    'Export is not available in demo mode. Nothing here is your data.',
  );

  @override
  Future<void> deleteData({required bool account}) async =>
      throw const UserFacingException(
        'Deleting is not available in demo mode. There is nothing to delete.',
      );
}

class DemoCoachRepository implements CoachRepository {
  @override
  Future<CoachReply> ask(String question, {String? threadId}) async =>
      demoCoachReply(DateTime.now());

  @override
  Future<List<CoachMessage>> latestThread(String userId) async =>
      demoCoachHistory(DateTime.now());
}

/// Offers one recently finished walk as a "Did you walk…?" suggestion.
/// It only answers history queries; nothing is read from the device.
class DemoMotionHistory extends MotionHistorySource {
  DemoMotionHistory(this._now) : super(available: true);
  final DateTime Function() _now;
  final _state = <String, Map<String, dynamic>>{};

  /// A 35-minute walk that ended about an hour ago (never before midnight).
  DateTime get _start {
    final now = _now();
    final day = DateTime(now.year, now.month, now.day);
    final start = DateTime(now.year, now.month, now.day, now.hour, now.minute)
        .subtract(const Duration(minutes: 95));
    return start.isBefore(day) ? day : start;
  }

  @override
  void onOpen(void Function()? callback) {}

  @override
  Future<bool> takeOpenRequest() async => false;

  @override
  Future<Map<String, dynamic>> readState(String owner) async =>
      _state[owner] ?? {};

  @override
  Future<void> writeState(String owner, Map<String, dynamic> state) async {
    _state[owner] = state;
  }

  @override
  Future<void> configure({required bool enabled}) async {}

  @override
  Future<void> advanceRefreshCursor(DateTime through) async {}

  @override
  Future<void> setActiveWorkout(WorkoutSession? session) async {}

  @override
  Future<List<ActivitySample>> queryActivities(
    DateTime from,
    DateTime to,
  ) async {
    final rows = [
      ActivitySample(
        type: ActivityType.walking,
        confidence: 100,
        timestamp: _start,
      ),
      ActivitySample(
        type: ActivityType.still,
        confidence: 100,
        timestamp: _start.add(const Duration(minutes: 35)),
      ),
    ];
    return rows
        .where((s) => !s.timestamp.isBefore(from) && !s.timestamp.isAfter(to))
        .toList();
  }

  @override
  Future<HistorySteps> querySteps(DateTime from, DateTime to) async {
    final end = _start.add(const Duration(minutes: 35));
    final a = from.isBefore(_start) ? _start : from;
    final b = to.isAfter(end) ? end : to;
    return HistorySteps(b.isAfter(a) ? b.difference(a).inSeconds * 100 ~/ 60 : 0);
  }
}
