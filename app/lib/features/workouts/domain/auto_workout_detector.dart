import 'activity_sample.dart';
import 'workout_session.dart';

typedef WorkoutClock = DateTime Function();

enum DetectorPhase {
  idle,
  candidate,
  promptingStart,
  active,
  promptingStop,
  finished,
}

class DetectorConfig {
  const DetectorConfig({
    this.minConfidence = 75,
    this.walkStartAfter = const Duration(minutes: 10),
    this.runStartAfter = const Duration(minutes: 3),
    this.bikeStartAfter = const Duration(minutes: 5),
    this.promptTimeout = const Duration(minutes: 2),
    this.stopAfterStill = const Duration(minutes: 5),
    this.stopPromptTimeout = const Duration(minutes: 2),
    this.briefGapTolerance = const Duration(seconds: 60),
    this.dismissCooldown = const Duration(minutes: 30),
  });

  final int minConfidence;
  final Duration walkStartAfter;
  final Duration runStartAfter;
  final Duration bikeStartAfter;
  final Duration promptTimeout;
  final Duration stopAfterStill;
  final Duration stopPromptTimeout;
  final Duration briefGapTolerance;
  final Duration dismissCooldown;

  Duration startAfter(ExerciseType type) => switch (type) {
    ExerciseType.walk => walkStartAfter,
    ExerciseType.run => runStartAfter,
    ExerciseType.bike => bikeStartAfter,
  };
}

sealed class DetectorEvent {
  const DetectorEvent();
}

class StartPrompt extends DetectorEvent {
  const StartPrompt({
    required this.type,
    required this.activityStartedAt,
    required this.deadline,
  });

  final ExerciseType type;
  final DateTime activityStartedAt;
  final DateTime deadline;
  List<ExerciseType> get alternatives => type.alternatives;
}

class WorkoutStarted extends DetectorEvent {
  const WorkoutStarted(this.session);
  final WorkoutSession session;
}

class StopPrompt extends DetectorEvent {
  const StopPrompt({required this.deadline});
  final DateTime deadline;
}

class WorkoutFinished extends DetectorEvent {
  const WorkoutFinished(this.session);
  final WorkoutSession session;
}

/// Event-based activity remains current until the OS reports a change.
/// All time-dependent transitions happen through tick(), never through timers.
class AutoWorkoutDetector {
  AutoWorkoutDetector({
    required this.clock,
    this.config = const DetectorConfig(),
  });

  final WorkoutClock clock;
  final DetectorConfig config;
  DetectorPhase phase = DetectorPhase.idle;
  bool autoStartPrompts = true;
  bool autoStopPrompts = true;
  double weightKg = 70;
  ExerciseType? candidateType;
  DateTime? activityStartedAt;
  StartPrompt? startPrompt;
  StopPrompt? stopPrompt;
  WorkoutSession? finishedSession;

  ActivitySample? _latestActivity;
  DateTime? _lastActivityTimestamp;
  DateTime? _gapStartedAt;
  DateTime? _cooldownUntil;
  DateTime? _lastMovementAt;
  DateTime? _inactivitySince;
  DateTime? _startedAt;
  ExerciseType? _activeType;
  WorkoutSource _source = WorkoutSource.auto;
  double _sessionWeightKg = 70;
  final List<StepSample> _steps = [];
  final List<DetectorEvent> _events = [];
  int? _rawSteps;
  int _stepOffset = 0;

  bool get isActive =>
      phase == DetectorPhase.active || phase == DetectorPhase.promptingStop;

  WorkoutSession? get currentSession => isActive ? _session(clock()) : null;

  List<DetectorEvent> takeEvents() {
    final result = List<DetectorEvent>.of(_events);
    _events.clear();
    return result;
  }

  void addActivity(ActivitySample sample) {
    if (sample.confidence < config.minConfidence ||
        sample.timestamp.isAfter(clock()) ||
        (_lastActivityTimestamp != null &&
            sample.timestamp.isBefore(_lastActivityTimestamp!))) {
      return;
    }
    final wasMoving =
        _latestActivity != null &&
        ExerciseType.fromActivity(_latestActivity!.type) != null;
    _latestActivity = sample;
    _lastActivityTimestamp = sample.timestamp;
    final type = ExerciseType.fromActivity(sample.type);

    if (isActive) {
      if (type != null) {
        _movement(sample.timestamp);
      } else {
        // A change to still marks the end of the preceding moving interval.
        if (wasMoving) _lastMovementAt = sample.timestamp;
        _inactivitySince ??= sample.timestamp;
      }
      tick();
      return;
    }
    if (phase == DetectorPhase.promptingStart) {
      tick();
      return;
    }
    if (type == null) {
      if (phase == DetectorPhase.candidate) {
        _gapStartedAt ??= sample.timestamp;
      }
      tick();
      return;
    }
    if (!autoStartPrompts ||
        (_cooldownUntil != null && clock().isBefore(_cooldownUntil!))) {
      return;
    }

    if (phase != DetectorPhase.candidate ||
        candidateType != type ||
        (_gapStartedAt != null &&
            sample.timestamp.difference(_gapStartedAt!) >
                config.briefGapTolerance)) {
      candidateType = type;
      activityStartedAt = sample.timestamp;
      phase = DetectorPhase.candidate;
    }
    _gapStartedAt = null;
    tick();
  }

  void addSteps(StepSample sample) {
    if (sample.count < 0 ||
        sample.timestamp.isAfter(clock()) ||
        (_steps.isNotEmpty &&
            sample.timestamp.isBefore(_steps.last.timestamp))) {
      return;
    }
    if (_rawSteps != null && sample.count < _rawSteps!) {
      // Keep the logical counter monotonic when the device counter resets.
      _stepOffset += _rawSteps!;
    }
    final count = sample.count + _stepOffset;
    final moved = _rawSteps != null && count > _steps.last.count;
    _rawSteps = sample.count;
    _steps.add(StepSample(count: count, timestamp: sample.timestamp));
    if (moved && isActive) _movement(sample.timestamp);
    _pruneSteps();
  }

  void tick() {
    final now = clock();
    if (phase == DetectorPhase.candidate) {
      if (!autoStartPrompts ||
          (_gapStartedAt != null &&
              now.difference(_gapStartedAt!) > config.briefGapTolerance)) {
        _resetCandidate();
      } else if (_gapStartedAt == null &&
          now.difference(activityStartedAt!) >=
              config.startAfter(candidateType!)) {
        startPrompt = StartPrompt(
          type: candidateType!,
          activityStartedAt: activityStartedAt!,
          deadline: now.add(config.promptTimeout),
        );
        phase = DetectorPhase.promptingStart;
        _events.add(startPrompt!);
      }
    } else if (phase == DetectorPhase.promptingStart) {
      if (!autoStartPrompts || !now.isBefore(startPrompt!.deadline)) {
        dismissStart();
      }
    } else if (isActive) {
      if (!autoStopPrompts) {
        stopPrompt = null;
        phase = DetectorPhase.active;
        return;
      }
      if (phase == DetectorPhase.promptingStop) {
        if (!now.isBefore(stopPrompt!.deadline)) {
          _finish(_lastMovementAt ?? _startedAt!);
        }
      } else if (_inactivitySince != null &&
          now.difference(_inactivitySince!) >= config.stopAfterStill) {
        stopPrompt = StopPrompt(deadline: now.add(config.stopPromptTimeout));
        phase = DetectorPhase.promptingStop;
        _events.add(stopPrompt!);
      } else if (_inactivitySince == null) {
        _lastMovementAt = now;
      }
    }
    _pruneSteps();
  }

  void acceptStart(ExerciseType type) {
    tick();
    final prompt = startPrompt;
    if (phase != DetectorPhase.promptingStart ||
        prompt == null ||
        (type != prompt.type && !prompt.alternatives.contains(type))) {
      return;
    }
    _start(type, prompt.activityStartedAt, WorkoutSource.auto);
  }

  void dismissStart() {
    if (phase != DetectorPhase.promptingStart) return;
    _cooldownUntil = clock().add(config.dismissCooldown);
    _resetCandidate();
  }

  void acceptStop() {
    tick();
    if (isActive) _finish(clock());
  }

  void dismissStop() {
    if (phase != DetectorPhase.promptingStop) return;
    stopPrompt = null;
    phase = DetectorPhase.active;
    _inactivitySince = clock();
  }

  /// Foreground/screen-on is interaction, so restart the inactivity timer.
  void screenOn() {
    if (!isActive) return;
    stopPrompt = null;
    phase = DetectorPhase.active;
    if (_inactivitySince != null) _inactivitySince = clock();
  }

  void manualStart(ExerciseType type) {
    if (!isActive) _start(type, clock(), WorkoutSource.manual);
  }

  void manualStop() => acceptStop();

  void _start(ExerciseType type, DateTime start, WorkoutSource source) {
    _startedAt = start;
    _activeType = type;
    _source = source;
    _sessionWeightKg = weightKg;
    final moving =
        _latestActivity != null &&
        ExerciseType.fromActivity(_latestActivity!.type) != null;
    final stillSince = source == WorkoutSource.auto
        ? _latestActivity?.timestamp ?? clock()
        : clock();
    _lastMovementAt = moving ? clock() : stillSince;
    _inactivitySince = moving ? null : stillSince;
    startPrompt = null;
    stopPrompt = null;
    candidateType = null;
    activityStartedAt = null;
    _gapStartedAt = null;
    finishedSession = null;
    phase = DetectorPhase.active;
    _events.add(WorkoutStarted(_session(clock())));
  }

  void _movement(DateTime at) {
    _lastMovementAt = at;
    // Step events can arrive while activity recognition still says "still".
    // Restart that interval rather than assuming movement continues forever.
    _inactivitySince =
        _latestActivity == null ||
            ExerciseType.fromActivity(_latestActivity!.type) == null
        ? at
        : null;
    stopPrompt = null;
    phase = DetectorPhase.active;
  }

  void _finish(DateTime end) {
    final boundedEnd = end.isBefore(_startedAt!) ? _startedAt! : end;
    finishedSession = _session(boundedEnd, endedAt: boundedEnd);
    phase = DetectorPhase.finished;
    stopPrompt = null;
    _cooldownUntil = clock().add(config.dismissCooldown);
    _events.add(WorkoutFinished(finishedSession!));
  }

  WorkoutSession _session(DateTime at, {DateTime? endedAt}) => WorkoutSession(
    type: _activeType!,
    startedAt: _startedAt!,
    endedAt: endedAt,
    measuredAt: at,
    steps: (_countAt(at) - _countAt(_startedAt!)).clamp(0, 1 << 53),
    source: _source,
    weightKg: _sessionWeightKg,
  );

  int _countAt(DateTime at) {
    for (final sample in _steps.reversed) {
      if (!sample.timestamp.isAfter(at)) return sample.count;
    }
    // Without an earlier reading, the first reading is the baseline, not zero.
    return _steps.isEmpty ? 0 : _steps.first.count;
  }

  void _pruneSteps() {
    final earliest = isActive
        ? _startedAt!
        : activityStartedAt ?? clock().subtract(const Duration(hours: 1));
    // Keep one reading before the boundary for a cumulative-counter baseline.
    while (_steps.length > 1 && _steps[1].timestamp.isBefore(earliest)) {
      _steps.removeAt(0);
    }
  }

  void _resetCandidate() {
    phase = DetectorPhase.idle;
    candidateType = null;
    activityStartedAt = null;
    startPrompt = null;
    _gapStartedAt = null;
  }
}
