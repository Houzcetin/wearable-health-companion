import 'dart:async';

import 'package:wearable_companion/data/auth_repository.dart';
import 'package:wearable_companion/data/daily_metrics.dart';
import 'package:wearable_companion/data/health_repository.dart';
import 'package:wearable_companion/data/profile_repository.dart';

const testUser = AppUser(id: 'user-a', email: 'reader@example.com');
final testToday = DateTime(2026, 11, 12);

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this.user = testUser});
  AppUser? user;
  Object? signInError;
  final _changes = StreamController<AppUser?>.broadcast();
  @override
  AppUser? get currentUser => user;
  @override
  Stream<AppUser?> get authStateChanges async* {
    yield user;
    yield* _changes.stream;
  }

  void emit(AppUser? value) {
    user = value;
    _changes.add(value);
  }

  @override
  Future<void> signInWithGoogle() async {
    if (signInError != null) throw signInError!;
    emit(testUser);
  }

  @override
  Future<void> signOut() async => emit(null);
  Future<void> close() => _changes.close();
}

class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({this.consented = true});
  bool consented;
  int grants = 0;
  int fetches = 0;
  Object? fetchError, grantError;
  @override
  Future<Profile> fetchProfile(String userId) async {
    fetches++;
    if (fetchError != null) throw fetchError!;
    return Profile(
      userId: userId,
      timezone: 'Europe/Istanbul',
      healthConsentAt: consented ? DateTime(2026, 11, 1) : null,
    );
  }

  @override
  Future<void> grantHealthConsent(String userId) async {
    if (grantError != null) throw grantError!;
    grants++;
    consented = true;
  }
}

class FakeHealthRepository implements HealthRepository {
  FakeHealthRepository({
    this.connection = const HealthConnection(status: ConnectionStatus.active),
    this.rows = const [],
  });
  HealthConnection? connection;
  List<DailyMetrics> rows;
  Object? connectError, syncError, fetchError;
  Completer<SyncResult>? syncCompleter;
  SyncResult syncResult = const SyncResult(
    processed: 9,
    failed: 0,
    remaining: 0,
  );
  int fetches = 0, syncs = 0, connections = 0;
  @override
  Future<HealthConnection?> fetchConnection(String userId) async {
    connections++;
    return connection;
  }

  @override
  Future<void> connect() async {
    if (connectError != null) throw connectError!;
    connection = const HealthConnection(status: ConnectionStatus.active);
  }

  @override
  Future<SyncResult> requestSync() async {
    syncs++;
    if (syncError != null) throw syncError!;
    if (syncCompleter != null) return syncCompleter!.future;
    return syncResult;
  }

  @override
  Future<List<DailyMetrics>> fetchDailyMetrics(
    String userId,
    DateTime today,
  ) async {
    fetches++;
    if (fetchError != null) throw fetchError!;
    return rows;
  }
}

List<DailyMetrics> history({
  int nights = 7,
  int sleepToday = 398,
  bool demo = false,
}) => [
  for (var i = 1; i <= nights; i++)
    DailyMetrics(
      date: testToday.subtract(Duration(days: i)),
      sleepMinutes: 450,
      restingHr: 60,
      steps: 8000,
      isDemo: demo,
    ),
  DailyMetrics(
    date: testToday,
    sleepMinutes: sleepToday,
    restingHr: 64,
    hrvMs: 42,
    steps: 9000,
    activeZoneMin: 24,
    isDemo: demo,
  ),
];
