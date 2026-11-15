import '../domain/workout_session.dart';

abstract interface class WorkoutRepository {
  List<WorkoutSession> get sessions;
  void save(WorkoutSession session);
}

class InMemoryWorkoutRepository implements WorkoutRepository {
  final List<WorkoutSession> _sessions = [];
  @override
  List<WorkoutSession> get sessions => List.unmodifiable(_sessions);

  @override
  void save(WorkoutSession session) => _sessions.add(session);
}
