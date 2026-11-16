import '../domain/auto_workout_detector.dart';
import '../domain/workout_backfill.dart';
import '../domain/workout_session.dart';
import 'motion_history_source.dart';
import 'workout_repository.dart';
import 'workout_row.dart';

/// Serializes resume checks and review decisions, persisting the cursor together
/// with suggestions so a process restart cannot silently lose a review.
class WorkoutHistoryReview {
  WorkoutHistoryReview({
    required this.source,
    required this.repository,
    required this.owner,
    required this.clock,
    required this.config,
  });
  final MotionHistorySource source;
  final WorkoutRepository repository;
  final String owner;
  final WorkoutClock clock;
  final DetectorConfig config;
  static const maxStepQueriesPerCheck = 48;
  final List<WorkoutSession> candidates = [];
  DateTime? _checkpoint;
  bool _loaded = false;
  Future<void> _queue = Future.value();

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> check({
    required bool enabled,
    required double weightKg,
    WorkoutSession? active,
  }) => _enqueue(() async {
    if (!source.available) return;
    if (!_loaded) {
      final saved = await source.readState(owner);
      _checkpoint = DateTime.tryParse(saved['checkpoint'] as String? ?? '');
      for (final row in (saved['candidates'] as List? ?? [])) {
        candidates.add(workoutFromRow(Map<String, dynamic>.from(row as Map)));
      }
      _loaded = true;
    }
    final to = clock();
    final earliest = to.subtract(const Duration(hours: 24));
    final cursor = _checkpoint ?? earliest;
    final from = cursor.isBefore(earliest) || cursor.isAfter(to)
        ? earliest
        : cursor;
    if (!enabled) {
      candidates.clear();
      _checkpoint = to;
      await _persist();
      return;
    }
    // loadRange filters by start time; workouts last at most 24 hours, so this
    // also includes any saved workout crossing the review window's boundary.
    await repository.loadRange(from.subtract(const Duration(hours: 24)), to);
    if (repository.loadError != null) {
      return; // Retry before advancing the cursor.
    }
    candidates.removeWhere(
      (c) => repository.sessions.any((s) => workoutsOverlap(s, c)),
    );
    if (!from.isBefore(to)) {
      await _persist();
      return;
    }
    final activities = await source.queryActivities(from, to)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // Motion alone determines eligible bouts. Query pedometer totals only at
    // their boundaries, never for idle/uncertain records or saved overlaps.
    final result = WorkoutBackfill(config: config).replay(
      activities: activities,
      steps: const [],
      from: from,
      to: to,
      existing: [
        ...repository.sessions,
        ...candidates,
        if (active != null && active.isFreshActiveAt(to)) active,
      ],
      weightKg: weightKg,
    );
    final measured = <WorkoutSession>[];
    for (final bout in result.candidates.take(maxStepQueriesPerCheck)) {
      final steps = await source.querySteps(bout.startedAt, bout.endedAt!);
      measured.add(
        WorkoutSession(
          id: bout.id,
          type: bout.type,
          startedAt: bout.startedAt,
          endedAt: bout.endedAt,
          measuredAt: bout.measuredAt,
          steps: steps.steps,
          source: bout.source,
          weightKg: bout.weightKg,
          strideMeters: bout.strideMeters,
        ),
      );
    }
    candidates.addAll(measured);
    // Keep unqueried bouts available for the next resume if a noisy day hits
    // the bound. Queries are sequential so only one native request is in flight.
    _checkpoint = result.candidates.length > maxStepQueriesPerCheck
        ? result.candidates[maxStepQueriesPerCheck].startedAt
        : result.checkedThrough;
    await _persist();
  });

  Future<void> resolve(WorkoutSession candidate, {required bool save}) =>
      _enqueue(() async {
        if (!candidates.any((c) => c.id == candidate.id)) return;
        if (save &&
            !repository.sessions.any((s) => workoutsOverlap(s, candidate))) {
          await repository.save(candidate);
          await source.advanceRefreshCursor(candidate.endedAt!);
        }
        candidates.removeWhere((c) => c.id == candidate.id);
        await _persist();
      });

  Future<void> _persist() => source.writeState(owner, {
    'checkpoint': _checkpoint?.toIso8601String(),
    'candidates': candidates.map((c) => workoutToRow(c, owner)).toList(),
  });
}
