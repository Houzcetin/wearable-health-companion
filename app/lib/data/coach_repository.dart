import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';

class CoachException extends UserFacingException {
  const CoachException(this.code) : super(
    code == 'consent_required'
        ? 'Allow the coach to use your daily summaries first.'
        : code == 'daily_limit'
        ? "You've reached the coach limit for the last 24 hours. Try again later."
        : code == 'coach_busy'
        ? 'The coach is busy right now (shared limit for the last 24 hours). Please try again later.'
        : code == 'busy'
        ? 'The coach is busy. Try again in a minute.'
        : code == 'network'
        ? 'Check your connection and try again.'
        : "The coach couldn't answer right now. Try again.",
  );
  final String code;
}

/// Never expose Edge Function or model-provider error details in the UI.
CoachException mapCoachError(Object error) {
  if (error is CoachException) return error;
  if (error is FunctionException) {
    if (error.status == 0) return const CoachException('network');
    dynamic details = error.details;
    if (details is String) {
      try {
        details = jsonDecode(details);
      } catch (_) {
        details = null;
      }
    }
    final code = details is Map ? details['error'] : null;
    if (error.status == 403 && code == 'coach_consent_required') {
      return const CoachException('consent_required');
    }
    if (error.status == 429) {
      return CoachException(code == 'daily_limit' ? 'daily_limit' : 'busy');
    }
    if (error.status == 503 && code == 'coach_busy') {
      return const CoachException('coach_busy');
    }
    return const CoachException('unavailable');
  }
  if (error is FormatException || error is TypeError) {
    return const CoachException('unavailable');
  }
  return const CoachException('network');
}

class CoachReply {
  const CoachReply({
    required this.threadId,
    required this.answer,
    this.facts = const {},
    this.isDemo = false,
  });
  factory CoachReply.fromJson(Map<String, dynamic> json) => CoachReply(
    threadId: json['threadId'] as String,
    answer: json['answer'] as String,
    facts: Map<String, dynamic>.from(json['facts'] as Map),
    isDemo: json['isDemo'] as bool? ?? false,
  );
  final String threadId, answer;
  final Map<String, dynamic> facts;
  final bool isDemo;
}

class CoachMessage {
  const CoachMessage({
    required this.threadId,
    required this.role,
    required this.content,
    this.facts = const {},
    this.isDemo = false,
    this.createdAt,
  });
  factory CoachMessage.fromJson(Map<String, dynamic> json) {
    final facts = json['facts_json'] is Map
        ? Map<String, dynamic>.from(json['facts_json'] as Map)
        : <String, dynamic>{};
    return CoachMessage(
      threadId: json['thread_id'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
      facts: facts,
      // History stores the tool results, including their demo provenance.
      isDemo: _containsDemo(facts),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
  final String threadId, role, content;
  final Map<String, dynamic> facts;
  final bool isDemo;
  final DateTime? createdAt;
  bool get isUser => role == 'user';
}

bool _containsDemo(dynamic value) {
  if (value is Map) {
    return value['is_demo'] == true || value['isDemo'] == true ||
        value.values.any(_containsDemo);
  }
  return value is List && value.any(_containsDemo);
}

abstract class CoachRepository {
  Future<CoachReply> ask(String question, {String? threadId});
  Future<List<CoachMessage>> latestThread(String userId);
}

class SupabaseCoachRepository implements CoachRepository {
  SupabaseCoachRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<CoachReply> ask(String question, {String? threadId}) async {
    try {
      final response = await _client.functions.invoke('coach', body: {
        'question': question,
        'threadId': ?threadId,
      });
      if (response.status != 200) {
        throw FunctionException(status: response.status, details: response.data);
      }
      return CoachReply.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw mapCoachError(error);
    }
  }

  @override
  Future<List<CoachMessage>> latestThread(String userId) async {
    try {
      const columns = 'thread_id,role,content,facts_json,created_at';
      final latest = await _client.from('coach_messages').select(columns)
          .eq('user_id', userId).order('created_at', ascending: false)
          .limit(1).maybeSingle();
      if (latest == null) return [];
      final rows = await _client.from('coach_messages').select(columns)
          .eq('user_id', userId).eq('thread_id', latest['thread_id'] as String)
          // postgrest-dart sorts descending unless told otherwise.
          .order('created_at', ascending: true);
      return rows.map(CoachMessage.fromJson).toList();
    } catch (error) {
      throw mapCoachError(error);
    }
  }
}
