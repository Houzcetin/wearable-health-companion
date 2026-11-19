import 'package:flutter_riverpod/misc.dart' show Override;

import '../../data/providers.dart';
import 'demo_mode.dart';
import '../../features/workouts/data/workout_repository.dart';
import '../../features/workouts/domain/activity_sample.dart';
import '../../features/workouts/domain/workout_session.dart';
import '../../features/workouts/workout_provider.dart';
import 'demo_repositories.dart';

/// Replaces the backend with built-in sample data. No request leaves the app.
/// Used only when `Env.demoMode` is true; nothing else changes.
List<Override> demoOverrides() {
  final auth = DemoAuthRepository();
  final history = DemoMotionHistory(DateTime.now);
  return [
    demoModeProvider.overrideWithValue(true),
    backendConfiguredProvider.overrideWithValue(true),
    supabaseClientProvider.overrideWithValue(null),
    authRepositoryProvider.overrideWithValue(auth),
    profileRepositoryProvider.overrideWithValue(DemoProfileRepository()),
    healthRepositoryProvider.overrideWithValue(DemoHealthRepository()),
    coachRepositoryProvider.overrideWithValue(DemoCoachRepository()),
    motionHistorySourceProvider.overrideWithValue(history),
    workoutRepositoryProvider.overrideWith((ref) {
      final repository = InMemoryWorkoutRepository();
      ref.onDispose(repository.dispose);
      // One workout from earlier today, so "Today's workouts" is not empty.
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      var start = now.subtract(const Duration(hours: 6));
      if (start.isBefore(day)) start = day;
      final end = start.add(const Duration(minutes: 30));
      repository.save(
        WorkoutSession(
          type: ExerciseType.walk,
          source: WorkoutSource.auto,
          startedAt: start,
          measuredAt: end,
          endedAt: end,
          steps: 3600,
        ),
      );
      return repository;
    }),
  ];
}
