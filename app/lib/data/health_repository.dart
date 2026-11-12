import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';
import 'daily_metrics.dart';

enum ConnectionStatus { active, revoked, error }

class HealthConnection {
  const HealthConnection({required this.status, this.lastSyncedAt});
  factory HealthConnection.fromJson(Map<String, dynamic> json) =>
      HealthConnection(
        status: ConnectionStatus.values.byName(json['status'] as String),
        lastSyncedAt: json['last_synced_at'] == null
            ? null
            : DateTime.parse(json['last_synced_at'] as String),
      );
  final ConnectionStatus status;
  final DateTime? lastSyncedAt;
  bool get isActive => status == ConnectionStatus.active;
}

class SyncResult {
  const SyncResult({
    required this.processed,
    required this.failed,
    required this.remaining,
  });
  factory SyncResult.fromJson(Map<String, dynamic> json) => SyncResult(
    processed: (json['processed'] as num).toInt(),
    failed: (json['failed'] as num).toInt(),
    remaining: (json['remaining'] as num).toInt(),
  );
  final int processed, failed, remaining;
}

abstract class HealthRepository {
  Future<HealthConnection?> fetchConnection(String userId);
  Future<void> connect();
  Future<SyncResult> requestSync();
  Future<List<DailyMetrics>> fetchDailyMetrics(String userId, DateTime today);
}

class SupabaseHealthRepository implements HealthRepository {
  SupabaseHealthRepository(
    this._client, {
    Future<String> Function(String url)? authenticate,
  }) : _authenticate = authenticate ?? _openBrowser;
  final SupabaseClient _client;
  final Future<String> Function(String url) _authenticate;

  static Future<String> _openBrowser(String url) =>
      FlutterWebAuth2.authenticate(
        url: url,
        callbackUrlScheme: 'wearablecompanion',
      );

  @override
  Future<HealthConnection?> fetchConnection(String userId) async {
    final row = await _client
        .from('health_connections')
        .select('status,last_synced_at')
        .eq('user_id', userId)
        .maybeSingle();
    return row == null ? null : HealthConnection.fromJson(row);
  }

  @override
  Future<void> connect() async {
    final response = await _client.functions.invoke('health-oauth-start');
    final url = (response.data as Map<String, dynamic>)['url'] as String?;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const UserFacingException(
        'Could not start the connection. Please try again.',
      );
    }
    try {
      validateHealthCallback(await _authenticate(url!));
    } on PlatformException catch (error) {
      if (error.code.toUpperCase() == 'CANCELED' ||
          error.code.toUpperCase() == 'CANCELLED') {
        throw const UserFacingException(
          'Connection was cancelled. You can try again when ready.',
        );
      }
      throw const UserFacingException(
        'Could not open Google Health. Please try again.',
      );
    }
  }

  @override
  Future<SyncResult> requestSync() async {
    await _client.rpc('request_sync', params: {'days_back': 1});
    final response = await _client.functions.invoke('sync-worker');
    return SyncResult.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<List<DailyMetrics>> fetchDailyMetrics(
    String userId,
    DateTime today,
  ) async {
    final end = civilDate(today);
    final rows = await _client
        .from('daily_metrics')
        .select(
          'date,sleep_minutes,sleep_efficiency,deep_min,rem_min,light_min,awake_min,'
          'bedtime,wake_time,resting_hr,hrv_ms,spo2_avg,steps,active_zone_min,'
          'active_min,total_calories,exercise_count,is_demo,updated_at',
        )
        .eq('user_id', userId)
        .gte('date', dateKey(end.subtract(const Duration(days: 28))))
        .lte('date', dateKey(end))
        .order('date');
    return rows.map(DailyMetrics.fromJson).toList();
  }
}

void validateHealthCallback(String callback) {
  final uri = Uri.tryParse(callback);
  if (uri == null ||
      uri.scheme != 'wearablecompanion' ||
      uri.host != 'connected' ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const UserFacingException(
      'Unexpected connection response. Please try again.',
    );
  }
  if (uri.queryParameters['status'] == 'ok') return;
  final message = switch (uri.queryParameters['reason']) {
    'denied' =>
      'Google Health access was declined. You can try again when ready.',
    'bad_state' => 'The connection request expired. Please try again.',
    'no_refresh_token' =>
      'Google did not grant ongoing access. Please reconnect and allow access.',
    'exchange_failed' =>
      'Could not complete Google authorization. Please try again.',
    'identity_failed' =>
      'Could not identify your Google Health account. Please try again.',
    'store_failed' => 'Could not save your connection. Please try again.',
    _ => 'Could not connect Google Health. Please try again.',
  };
  throw UserFacingException(message);
}
