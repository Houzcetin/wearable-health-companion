import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wearable_companion/data/coach_repository.dart';
import 'package:wearable_companion/data/daily_metrics.dart';
import 'package:wearable_companion/data/profile_repository.dart';
import 'package:wearable_companion/features/settings/export_file.dart';
import 'package:wearable_companion/features/trends/domain/trends.dart';

void main() {
  test('coach consent parses the server-owned timestamp', () {
    final profile = Profile.fromJson({
      'user_id': 'u', 'timezone': 'UTC',
      'coach_consent_at': '2026-11-12T10:00:00Z',
    });
    expect(profile.coachConsentAt, DateTime.utc(2026, 11, 12, 10));
    expect(profile.hasHealthConsent, isFalse);
  });

  final cases = [
    (const FunctionException(status: 403, details: {'error': 'coach_consent_required'}),
      'consent_required'),
    (const FunctionException(status: 429, details: {'error': 'daily_limit'}), 'daily_limit'),
    (const FunctionException(status: 429, details: {'error': 'coach_busy'}), 'busy'),
    (const FunctionException(status: 503, details: {'error': 'coach_busy'}), 'coach_busy'),
    (const FunctionException(status: 503, details: {'error': 'private_backend_error'}),
      'unavailable'),
    (const FunctionException(status: 502, details: {'error': 'coach_unavailable'}),
      'unavailable'),
    (const FunctionException(status: 401), 'unavailable'),
    (const FunctionException(status: 400), 'unavailable'),
    (const FunctionException(status: 0), 'network'),
    (Exception('transport failed'), 'network'),
  ];
  for (final (error, code) in cases) {
    test('coach maps $error to $code without exposing backend details', () {
      expect(mapCoachError(error).code, code);
      expect(mapCoachError(error).message, isNot(contains('transport failed')));
      expect(mapCoachError(error).message, isNot(contains('coach_unavailable')));
    });
  }

  test('JSON string error bodies map the same way', () {
    expect(mapCoachError(const FunctionException(
      status: 429, details: '{"error":"daily_limit"}')).code, 'daily_limit');
    expect(mapCoachError(const FunctionException(
      status: 503, details: '{"error":"coach_busy"}')).message,
      "The coach has reached today's shared limit. Please try again tomorrow.");
    expect(mapCoachError(const FunctionException(
      status: 502, details: '<html>upstream failure</html>')).code, 'unavailable');
  });

  test('reply and persisted facts preserve demo provenance', () {
    final reply = CoachReply.fromJson({
      'threadId': 'thread-a', 'answer': 'A sample answer.', 'isDemo': true,
      'facts': {'tools': [{
        'name': 'get_daily_metrics', 'input': {},
        'result': {'is_demo': true, 'days': []},
      }]},
    });
    final message = CoachMessage.fromJson({
      'thread_id': reply.threadId, 'role': 'assistant',
      'content': reply.answer, 'facts_json': reply.facts,
      'created_at': '2026-11-12T10:00:00Z',
    });
    expect(message.isDemo, isTrue);
    expect(message.facts, reply.facts);
    expect(message.createdAt, DateTime.utc(2026, 11, 12, 10));
  });

  test('export filename is a zero-padded local civil date', () {
    expect(exportFileName(DateTime(2026, 1, 2, 23, 59)),
      'wearable-companion-export-2026-01-02.json');
  });

  test('export shares the original UTF-8 JSON with its filename and MIME type', () async {
    const json = '{"display_name":"Çağrı","daily_metrics":[]}';
    final params = exportShareParams(json, DateTime(2026, 11, 12));
    expect(params.fileNameOverrides, ['wearable-companion-export-2026-11-12.json']);
    expect(params.files!.single.mimeType, 'application/json');
    expect(utf8.decode(await params.files!.single.readAsBytes()), json);
  });

  test('trend averages ignore missing dates and preserve real zero', () {
    final data = TrendsData(metric: TrendMetric.steps, range: TrendRange.week,
      end: DateTime(2026, 11, 12), rows: [
        DailyMetrics(date: DateTime(2026, 11, 12), steps: 0),
        DailyMetrics(date: DateTime(2026, 11, 11), steps: 1000),
        DailyMetrics(date: DateTime(2026, 11, 10)),
      ]);
    expect(data.average, 500);
    expect(data.missingDays, 5);
    expect(data.learning, isTrue);
  });
}
