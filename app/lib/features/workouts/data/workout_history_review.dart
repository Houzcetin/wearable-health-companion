import '../domain/activity_sample.dart';
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
    // loadRange filters by START time. Include earlier starts as well, so even
    // an overnight/manual workout crossing our query boundary excludes a bout.
    await repository.loadRange(DateTime.fromMillisecondsSinceEpoch(0), to);
    if (repository.lastError != null) {
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
    final boundaries = <DateTime>{
      from,
      to,
      ...activities
          .map((a) => a.timestamp)
          .where((t) => t.isAfter(from) && t.isBefore(to)),
    }.toList()..sort();
    final steps = <StepSample>[StepSample(count: 0, timestamp: from)];
    var count = 0;
    for (var i = 1; i < boundaries.length; i++) {
      count += (await source.querySteps(
        boundaries[i - 1],
        boundaries[i],
      )).steps;
      steps.add(StepSample(count: count, timestamp: boundaries[i]));
    }
    final result = WorkoutBackfill(config: config).replay(
      activities: activities,
      steps: steps,
      from: from,
      to: to,
      existing: [...repository.sessions, ...candidates, ?active],
      weightKg: weightKg,
    );
    candidates.addAll(result.candidates);
    _checkpoint = result.checkedThrough;
    await _persist();
  });

  Future<void> resolve(WorkoutSession candidate, {required bool save}) =>
      _enqueue(() async {
        if (!candidates.any((c) => c.id == candidate.id)) return;
        if (save &&
            !repository.sessions.any((s) => workoutsOverlap(s, candidate))) {
          await repository.save(candidate);
        }
        candidates.removeWhere((c) => c.id == candidate.id);
        await _persist();
      });

  Future<void> _persist() => source.writeState(owner, {
    'checkpoint': _checkpoint?.toIso8601String(),
    'candidates': candidates.map((c) => workoutToRow(c, owner)).toList(),
  });
}
