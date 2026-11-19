import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class Profile {
  const Profile({
    required this.userId,
    required this.timezone,
    this.displayName,
    this.healthConsentAt,
    this.coachConsentAt,
  });
  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    userId: json['user_id'] as String,
    timezone: json['timezone'] as String,
    displayName: json['display_name'] as String?,
    healthConsentAt: json['health_consent_at'] == null
        ? null
        : DateTime.parse(json['health_consent_at'] as String),
    coachConsentAt: json['coach_consent_at'] == null
        ? null
        : DateTime.parse(json['coach_consent_at'] as String),
  );
  final String userId;
  final String timezone;
  final String? displayName;
  final DateTime? healthConsentAt, coachConsentAt;
  bool get hasHealthConsent => healthConsentAt != null;
}

abstract class ProfileRepository {
  /// Reads the trigger-created row and updates only timezone, if needed.
  Future<Profile> fetchProfile(String userId);
  Future<void> grantHealthConsent(String userId);
  Future<void> grantCoachConsent(String userId);
}

class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(
    this._client, {
    Future<String> Function()? deviceTimezone,
  }) : _deviceTimezone = deviceTimezone ?? _localTimezone;
  final SupabaseClient _client;
  final Future<String> Function() _deviceTimezone;

  static Future<String> _localTimezone() async =>
      (await FlutterTimezone.getLocalTimezone()).identifier;

  @override
  Future<Profile> fetchProfile(String userId) async {
    final row = await _client
        .from('profiles')
        .select(
          'user_id,display_name,timezone,health_consent_at,coach_consent_at',
        )
        .eq('user_id', userId)
        .single();
    final timezone = await _deviceTimezone();
    if (timezone.isNotEmpty && timezone != row['timezone']) {
      try {
        await _client
            .from('profiles')
            .update({'timezone': timezone})
            .eq('user_id', userId);
        row['timezone'] = timezone;
      } catch (_) {
        // Keep the stored timezone and allow onboarding to continue.
      }
    }
    return Profile.fromJson(row);
  }

  @override
  Future<void> grantHealthConsent(String userId) => _client
      .from('consent_events')
      .insert({'user_id': userId, 'kind': 'health_data', 'granted': true});

  @override
  Future<void> grantCoachConsent(String userId) => _client
      .from('consent_events')
      .insert({'user_id': userId, 'kind': 'ai_coach', 'granted': true});
}
