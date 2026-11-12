import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/data/auth_repository.dart';
import 'package:wearable_companion/data/daily_metrics.dart';
import 'package:wearable_companion/data/health_repository.dart';
import 'package:wearable_companion/data/profile_repository.dart';

void main() {
  test('daily aggregates parse numeric values and timestamps', () {
    final row = DailyMetrics.fromJson({
      'date': '2026-11-12',
      'sleep_minutes': 425,
      'sleep_efficiency': 92,
      'deep_min': 70,
      'rem_min': 90,
      'light_min': 240,
      'awake_min': 25,
      'bedtime': '2026-11-11T21:30:00Z',
      'wake_time': '2026-11-12T05:00:00Z',
      'resting_hr': 60.5,
      'hrv_ms': 42,
      'spo2_avg': 97.5,
      'steps': 8000,
      'active_zone_min': 24,
      'active_min': 45,
      'total_calories': 2150,
      'exercise_count': 1,
      'is_demo': true,
      'updated_at': '2026-11-12T05:15:00Z',
    });
    expect(row.date, DateTime(2026, 11, 12));
    expect(row.sleepMinutes, 425);
    expect(row.sleepEfficiency, 92.0);
    expect(row.deepMin, 70);
    expect(row.remMin, 90);
    expect(row.lightMin, 240);
    expect(row.awakeMin, 25);
    expect(row.bedtime, DateTime.utc(2026, 11, 11, 21, 30));
    expect(row.wakeTime, DateTime.utc(2026, 11, 12, 5));
    expect(row.restingHr, 60.5);
    expect(row.hrvMs, 42.0);
    expect(row.spo2Avg, 97.5);
    expect(row.steps, 8000);
    expect(row.activeZoneMin, 24);
    expect(row.activeMin, 45);
    expect(row.totalCalories, 2150.0);
    expect(row.exerciseCount, 1);
    expect(row.isDemo, isTrue);
    expect(row.updatedAt, DateTime.utc(2026, 11, 12, 5, 15));
    expect(row.hasData, isTrue);
  });
  test('all metrics may be null and zero is data', () {
    final row = DailyMetrics.fromJson({
      'date': '2026-11-12',
      'sleep_minutes': null,
    });
    expect(row.sleepMinutes, isNull);
    expect(row.restingHr, isNull);
    expect(row.hrvMs, isNull);
    expect(row.steps, isNull);
    expect(row.updatedAt, isNull);
    expect(row.isDemo, isFalse);
    expect(row.hasData, isFalse);
    expect(
      DailyMetrics.fromJson({'date': '2026-11-12', 'steps': 0}).hasData,
      isTrue,
    );
  });
  test('consent comes only from the profile timestamp', () {
    expect(
      Profile.fromJson({
        'user_id': 'u',
        'timezone': 'UTC',
        'health_consent_at': null,
      }).hasHealthConsent,
      isFalse,
    );
    expect(
      Profile.fromJson({
        'user_id': 'u',
        'timezone': 'UTC',
        'health_consent_at': '2026-11-12T01:00:00Z',
      }).hasHealthConsent,
      isTrue,
    );
  });
  test('valid callback succeeds', () {
    expect(
      () => validateHealthCallback('wearablecompanion://connected?status=ok'),
      returnsNormally,
    );
  });
  const reasons = {
    'denied': 'access was declined',
    'bad_state': 'request expired',
    'no_refresh_token': 'ongoing access',
    'exchange_failed': 'complete Google authorization',
    'identity_failed': 'identify your Google Health account',
    'store_failed': 'save your connection',
  };
  for (final entry in reasons.entries) {
    test('connection callback maps ${entry.key} to a human message', () {
      expect(
        () => validateHealthCallback(
          'wearablecompanion://connected?status=error&reason=${entry.key}',
        ),
        throwsA(
          isA<UserFacingException>().having(
            (e) => e.message,
            'message',
            contains(entry.value),
          ),
        ),
      );
    });
  }
  test('unexpected callbacks never mark an account connected', () {
    for (final callback in [
      'https://connected?status=ok',
      'wearablecompanion://other?status=ok',
      'wearablecompanion://connected/other?status=ok',
      'wearablecompanion://connected',
      'wearablecompanion://connected?status=error&reason=unknown',
    ]) {
      expect(
        () => validateHealthCallback(callback),
        throwsA(isA<UserFacingException>()),
      );
    }
  });
  test('connection and sync result parse the backend response', () {
    final connection = HealthConnection.fromJson({
      'status': 'revoked',
      'last_synced_at': '2026-11-12T06:00:00Z',
    });
    expect(connection.isActive, isFalse);
    expect(connection.lastSyncedAt, DateTime.utc(2026, 11, 12, 6));
    final sync = SyncResult.fromJson({
      'processed': 2,
      'failed': 1,
      'remaining': 6,
    });
    expect([sync.processed, sync.failed, sync.remaining], [2, 1, 6]);
  });
}
