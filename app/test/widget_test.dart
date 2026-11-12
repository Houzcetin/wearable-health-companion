import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/main.dart';

void main() {
  testWidgets('shell shows Today and switches tabs', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: HealthCompanionApp()));
    await tester.pumpAndSettle();

    expect(find.text('Sleep'), findsOneWidget);
    expect(find.text('Backend not configured'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.emoji_events_outlined));
    await tester.pumpAndSettle();
    expect(find.textContaining('streaks'), findsOneWidget);
  });
}
