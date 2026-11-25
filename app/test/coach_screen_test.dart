import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/data/coach_repository.dart';
import 'package:wearable_companion/features/coach/coach_screen.dart';

import 'support/fake_repositories.dart';
import 'support/stage5_harness.dart';

void main() {
  Future<void> send(WidgetTester tester, [String text = 'How was my sleep?']) async {
    await tester.enterText(find.byKey(const Key('coach-input')), text);
    await tester.pump();
    await tester.tap(find.byKey(const Key('coach-send')));
    await tester.pumpAndSettle();
  }

  testWidgets('consent explains Anthropic and grants before loading history', (tester) async {
    final profile = FakeProfileRepository(coachConsented: false);
    final coach = FakeCoachRepository();
    await startStage5(tester, screen: const CoachScreen(), profile: profile, coach: coach);
    expect(find.text('Your coach consent'), findsOneWidget);
    expect(find.textContaining('Claude, an AI model from Anthropic'), findsOneWidget);
    expect(find.textContaining('Raw readings are not sent.'), findsOneWidget);
    expect(find.textContaining('deleting your health data in Settings'), findsOneWidget);
    expect(coach.historyFetches, 0);
    expect(find.byKey(const Key('coach-input')), findsNothing);
    await tester.tap(find.text('Allow coach'));
    await tester.pumpAndSettle();
    expect(profile.coachGrants, 1);
    expect(coach.historyFetches, greaterThan(0));
    expect(find.byKey(const Key('coach-input')), findsOneWidget);
  });

  testWidgets('failed consent stays gated and can be retried', (tester) async {
    final profile = FakeProfileRepository()
      ..grantError = Exception('offline');
    final coach = FakeCoachRepository();
    await startStage5(tester, screen: const CoachScreen(), profile: profile, coach: coach);
    await tester.tap(find.text('Allow coach'));
    await tester.pumpAndSettle();
    expect(find.text('Could not save your consent. Please try again.'), findsOneWidget);
    expect(coach.historyFetches, 0);
    profile.grantError = null;
    await tester.tap(find.text('Allow coach'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('coach-input')), findsOneWidget);
  });

  testWidgets('send shows answer, demo provenance and readable Numbers used', (tester) async {
    final coach = FakeCoachRepository()
      ..reply = const CoachReply(
        threadId: 'thread-a', answer: 'You slept less on November 10.',
        isDemo: true,
        facts: {'tools': [{
          'name': 'get_daily_metrics',
          'input': {'start_date': '2026-11-06', 'end_date': '2026-11-12'},
          'result': {'days': [{'date': '2026-11-10', 'sleep_minutes': 390}]},
        }]},
      );
    await startStage5(tester, screen: const CoachScreen(), coach: coach);
    await send(tester);
    expect(find.text('How was my sleep?'), findsOneWidget);
    expect(find.text(coach.reply.answer), findsOneWidget);
    expect(find.text('Demo data'), findsOneWidget);
    expect(find.text('Numbers used'), findsOneWidget);
    await tester.tap(find.text('Numbers used'));
    await tester.pumpAndSettle();
    expect(find.text('Daily summaries: 2026-11-06 – 2026-11-12'), findsOneWidget);
    expect(find.text('1 day with data'), findsOneWidget);
    expect(find.text('Not medical advice.'), findsOneWidget);
    expect(coach.questions, ['How was my sleep?']);
  });

  testWidgets('comparison facts include both periods and contributor values', (tester) async {
    final coach = FakeCoachRepository()
      ..reply = const CoachReply(
        threadId: 'thread-a', answer: 'November 10 was the shortest night.',
        facts: {'tools': [{
          'name': 'compare_periods',
          'input': {
            'metric': 'sleep_minutes',
            'a_start': '2026-11-06', 'a_end': '2026-11-12',
            'b_start': '2026-10-09', 'b_end': '2026-11-05',
          },
          'result': {
            'a': {'mean': 420, 'missing_dates': ['2026-11-09']},
            'b': {'mean': 450, 'missing_dates': []},
            'top_contributors': [{'date': '2026-11-10', 'value': 390}],
          },
        }]},
      );
    await startStage5(tester, screen: const CoachScreen(), coach: coach);
    await send(tester);
    await tester.tap(find.text('Numbers used'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Top contributor dates'));
    expect(find.text('Period A: 2026-11-06 – 2026-11-12'), findsOneWidget);
    expect(find.text('Period B: 2026-10-09 – 2026-11-05'), findsOneWidget);
    expect(find.text('Mean: 7 h 00 min'), findsOneWidget);
    expect(find.text('Mean: 7 h 30 min'), findsOneWidget);
    expect(find.text('Missing days: 1'), findsOneWidget);
    expect(find.text('Missing days: 0'), findsOneWidget);
    expect(find.text('2026-11-10: 6 h 30 min'), findsOneWidget);
  });

  const errors = {
    'daily_limit': "You've reached the coach limit for the last 24 hours. Try again later.",
    'coach_busy': 'The coach is busy right now (shared limit for the last 24 hours). Please try again later.',
    'busy': 'The coach is busy. Try again in a minute.',
    'unavailable': "The coach couldn't answer right now. Try again.",
    'network': 'Check your connection and try again.',
  };
  for (final entry in errors.entries) {
    testWidgets('${entry.key} shows its inline message', (tester) async {
      final coach = FakeCoachRepository()..askError = CoachException(entry.key);
      await startStage5(tester, screen: const CoachScreen(), coach: coach);
      await send(tester);
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('Retry'),
        entry.key == 'daily_limit' || entry.key == 'coach_busy'
            ? findsNothing : findsOneWidget);
    });
  }

  testWidgets('consent_required returns to the consent card', (tester) async {
    final coach = FakeCoachRepository()
      ..askError = const CoachException('consent_required');
    await startStage5(tester, screen: const CoachScreen(), coach: coach);
    await send(tester);
    expect(find.text('Your coach consent'), findsOneWidget);
    expect(find.text('Allow coach'), findsOneWidget);
    expect(find.byKey(const Key('coach-input')), findsNothing);
  });

  testWidgets('retry resends a failed question without duplicating its bubble', (tester) async {
    final coach = FakeCoachRepository()..askError = const CoachException('busy');
    await startStage5(tester, screen: const CoachScreen(), coach: coach);
    await send(tester);
    coach.askError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(coach.asks, 2);
    expect(find.text('How was my sleep?'), findsOneWidget);
    expect(find.text(coach.reply.answer), findsOneWidget);
  });

  testWidgets('suggested chips fill the input without sending', (tester) async {
    final coach = FakeCoachRepository();
    await startStage5(tester, screen: const CoachScreen(), coach: coach);
    for (final question in suggestedQuestions) {
      await tester.tap(find.widgetWithText(ActionChip, question));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const Key('coach-input'))).controller!.text,
        question);
    }
    expect(coach.asks, 0);
  });

  testWidgets('prefilled question is editable and never auto-sends', (tester) async {
    final coach = FakeCoachRepository();
    await startStage5(tester,
      screen: const CoachScreen(initialQuestion: 'Why was this week different from my usual?'),
      coach: coach);
    expect(tester.widget<TextField>(find.byKey(const Key('coach-input'))).controller!.text,
      'Why was this week different from my usual?');
    expect(coach.asks, 0);
  });

  testWidgets('sending is disabled while a request is in flight', (tester) async {
    final coach = FakeCoachRepository()..askCompleter = Completer<CoachReply>();
    await startStage5(tester, screen: const CoachScreen(), coach: coach);
    await tester.enterText(find.byKey(const Key('coach-input')), 'How was my sleep?');
    await tester.pump();
    await tester.tap(find.byKey(const Key('coach-send')));
    await tester.pump();
    expect(find.text('Thinking…'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('coach-input')), 'Another question');
    expect(tester.widget<IconButton>(find.byKey(const Key('coach-send'))).onPressed, isNull);
    expect(coach.asks, 1);
    coach.askCompleter!.complete(coach.reply);
    await tester.pumpAndSettle();
    expect(find.text('Thinking…'), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(const Key('coach-send'))).onPressed, isNotNull);
  });

  testWidgets('input limits questions to 500 characters', (tester) async {
    final coach = FakeCoachRepository();
    await startStage5(tester, screen: const CoachScreen(), coach: coach);
    await tester.enterText(find.byKey(const Key('coach-input')), 'x' * 501);
    await tester.pump();
    await tester.tap(find.byKey(const Key('coach-send')));
    await tester.pumpAndSettle();
    expect(coach.questions.single.length, 500);
  });

  testWidgets('latest thread continues its ID and New chat clears locally', (tester) async {
    final coach = FakeCoachRepository()
      ..messages = const [
        CoachMessage(threadId: 'old-thread', role: 'user', content: 'My earlier question'),
        CoachMessage(threadId: 'old-thread', role: 'assistant', content: 'My earlier answer'),
      ];
    await startStage5(tester, screen: const CoachScreen(), coach: coach);
    expect(find.text('My earlier answer'), findsOneWidget);
    await send(tester);
    expect(coach.threadIds.first, 'old-thread');
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    expect(find.text('My earlier answer'), findsNothing);
    expect(find.widgetWithText(ActionChip, suggestedQuestions.first), findsOneWidget);
    await send(tester, 'Start again');
    expect(coach.threadIds.last, isNull);
    expect(coach.historyFetches, 1);
  });

  testWidgets('history loading error has a working retry', (tester) async {
    final coach = FakeCoachRepository()..historyError = const CoachException('network');
    await startStage5(tester, screen: const CoachScreen(), coach: coach);
    expect(find.text('Check your connection and try again.'), findsOneWidget);
    coach.historyError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('coach-input')), findsOneWidget);
  });
}
