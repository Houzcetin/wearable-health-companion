import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/activity_sources.dart';
import 'data/simulated_sources.dart';
import 'data/workout_repository.dart';
import 'domain/activity_sample.dart';
import 'domain/auto_workout_detector.dart';
import 'domain/workout_session.dart';

final workoutClockProvider = Provider<WorkoutClock>((ref) => DateTime.now);
final detectorConfigProvider = Provider<DetectorConfig>(
  (ref) => const DetectorConfig(),
);
final motionPermissionProvider = Provider<MotionPermission>(
  (ref) => MotionPermission(),
);
final activitySourceProvider = Provider<ActivitySource>((ref) {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
    return UnavailableActivitySource();
  }
  return PhoneActivitySource(
    clock: ref.watch(workoutClockProvider),
    requestPermission: ref.watch(motionPermissionProvider).request,
  );
});
final stepSourceProvider = Provider<StepSource>((ref) {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
    return UnavailableStepSource();
  }
  return PhoneStepSource(
    requestPermission: ref.watch(motionPermissionProvider).request,
  );
});
final workoutRepositoryProvider = Provider<WorkoutRepository>(
  (ref) => InMemoryWorkoutRepository(),
);

/// Null disables scheduling for tests; the domain still advances via tick().
final workoutTickIntervalProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 15),
);

class WorkoutState {
  const WorkoutState({
    required this.now,
    this.phase = DetectorPhase.idle,
    this.candidateType,
    this.activityStartedAt,
    this.startPrompt,
    this.stopPrompt,
    this.session,
    this.summary,
    this.todaySessions = const [],
    this.autoStart = true,
    this.autoStop = true,
    this.simulator = false,
    this.weightKg = 70,
    this.sensorNotice,
  });

  final DateTime now;
  final DetectorPhase phase;
  final ExerciseType? candidateType;
  final DateTime? activityStartedAt;
  final StartPrompt? startPrompt;
  final StopPrompt? stopPrompt;
  final WorkoutSession? session, summary;
  final List<WorkoutSession> todaySessions;
  final bool autoStart, autoStop, simulator;
  final double weightKg;
  final String? sensorNotice;
}

final workoutProvider = NotifierProvider<WorkoutNotifier, WorkoutState>(
  WorkoutNotifier.new,
);

class WorkoutNotifier extends Notifier<WorkoutState> {
  late AutoWorkoutDetector _detector;
  late WorkoutClock _realClock;
  late WorkoutRepository _repository;
  late ActivitySource _activitySource;
  late StepSource _stepSource;
  StreamSubscription<ActivitySample>? _activitySubscription;
  StreamSubscription<StepSample>? _stepSubscription;
  Timer? _timer;
  Duration? _tickInterval;
  SimulationClock? _simulationClock;
  SimulatedActivitySource? _simulatedActivity;
  SimulatedStepSource? _simulatedSteps;
  WorkoutSession? _summary;
  String? _streamError;
  int _generation = 0;

  @override
  WorkoutState build() {
    _realClock = ref.read(workoutClockProvider);
    _repository = ref.read(workoutRepositoryProvider);
    _activitySource = ref.read(activitySourceProvider);
    _stepSource = ref.read(stepSourceProvider);
    _tickInterval = ref.read(workoutTickIntervalProvider);
    _detector = AutoWorkoutDetector(
      clock: () => _simulationClock?.now() ?? _realClock(),
      config: ref.read(detectorConfigProvider),
    );
    // Start listening after build so even synchronous fake streams are safe.
    Future.microtask(() {
      if (ref.mounted) {
        _subscribe();
        _publish();
      }
    });
    ref.onDispose(() {
      _generation++;
      _timer?.cancel();
      unawaited(_activitySubscription?.cancel());
      unawaited(_stepSubscription?.cancel());
      unawaited(_simulatedActivity?.dispose());
      unawaited(_simulatedSteps?.dispose());
    });
    return WorkoutState(now: _realClock());
  }

  void _subscribe() {
    final generation = ++_generation;
    void changed() {
      if (!ref.mounted || generation != _generation) return;
      _ensureTimer();
      _publish();
    }

    void failed(Object error) {
      if (!ref.mounted || generation != _generation) return;
      _streamError =
          'Phone sensors unavailable. Try the simulator in Settings.';
      _publish();
    }

    _activitySubscription = _activitySource.samples.listen(
      (sample) {
        if (!ref.mounted || generation != _generation) return;
        _detector.addActivity(sample);
        changed();
      },
      onError: failed,
      onDone: changed,
    );
    _stepSubscription = _stepSource.samples.listen(
      (sample) {
        if (!ref.mounted || generation != _generation) return;
        _detector.addSteps(sample);
        changed();
      },
      onError: failed,
      onDone: changed,
    );
  }

  void _ensureTimer() {
    // An unavailable plugin has no samples to advance. This also keeps the
    // default provider inert in desktop/widget tests without platform mocks.
    if (_timer == null &&
        _tickInterval != null &&
        (_simulationClock != null || _detector.phase != DetectorPhase.idle)) {
      _timer = Timer.periodic(_tickInterval!, (_) => tick());
    }
  }

  void tick() {
    final simulation = _simulationClock;
    if (simulation != null) {
      final elapsed = _tickInterval ?? const Duration(seconds: 15);
      simulation.advance(elapsed);
      _simulatedSteps!.advance(
        _simulatedActivity!.type,
        elapsed * simulation.timeAcceleration,
      );
    }
    _detector.tick();
    _publish();
  }

  void _publish() {
    for (final event in _detector.takeEvents()) {
      if (event is WorkoutFinished) {
        _repository.save(event.session);
        _summary = event.session;
      }
    }
    final now = _detector.clock();
    final today = _repository.sessions
        .where((session) {
          final date = session.startedAt.toLocal();
          final localNow = now.toLocal();
          return date.year == localNow.year &&
              date.month == localNow.month &&
              date.day == localNow.day;
        })
        .toList()
        .reversed
        .toList();
    state = WorkoutState(
      now: now,
      phase: _detector.phase,
      candidateType: _detector.candidateType,
      activityStartedAt: _detector.activityStartedAt,
      startPrompt: _detector.startPrompt,
      stopPrompt: _detector.stopPrompt,
      session: _detector.currentSession,
      summary: _summary,
      todaySessions: List.unmodifiable(today),
      autoStart: _detector.autoStartPrompts,
      autoStop: _detector.autoStopPrompts,
      simulator: _simulationClock != null,
      weightKg: _detector.weightKg,
      sensorNotice:
          _streamError ??
          _activitySource.unavailableReason ??
          _stepSource.unavailableReason,
    );
  }

  void setAutoStart(bool enabled) {
    _detector.autoStartPrompts = enabled;
    _detector.tick();
    _publish();
  }

  void setAutoStop(bool enabled) {
    _detector.autoStopPrompts = enabled;
    _detector.tick();
    _publish();
  }

  bool setWeight(double weight) {
    if (!weight.isFinite || weight < 20 || weight > 400) return false;
    _detector.weightKg = weight;
    _publish();
    return true;
  }

  void acceptStart(ExerciseType type) {
    _detector.acceptStart(type);
    _ensureTimer();
    _publish();
  }

  void dismissStart() {
    _detector.dismissStart();
    _publish();
  }

  void acceptStop() {
    _detector.acceptStop();
    _publish();
  }

  void dismissStop() {
    _detector.dismissStop();
    _publish();
  }

  /// Re-reads the detector without advancing it, e.g. for a live elapsed timer.
  void refresh() => _publish();

  void clearSummary() {
    _summary = null;
    _publish();
  }

  void manualStart(ExerciseType type) {
    _detector.manualStart(type);
    _ensureTimer();
    _publish();
  }

  Future<void> setSimulator(bool enabled) async {
    if (enabled == state.simulator || state.session != null) return;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = null;
    await _activitySubscription?.cancel();
    await _stepSubscription?.cancel();
    if (!ref.mounted || generation != _generation) return;
    await _simulatedActivity?.dispose();
    await _simulatedSteps?.dispose();
    if (!ref.mounted || generation != _generation) return;
    _simulationClock = enabled
        ? SimulationClock(startedAt: _realClock())
        : null;
    _simulatedActivity = enabled
        ? SimulatedActivitySource(clock: _simulationClock!.now)
        : null;
    _simulatedSteps = enabled
        ? SimulatedStepSource(clock: _simulationClock!.now)
        : null;
    _activitySource = _simulatedActivity ?? ref.read(activitySourceProvider);
    _stepSource = _simulatedSteps ?? ref.read(stepSourceProvider);
    _streamError = null;
    // Never mix counters or clock domains when changing sensor sources.
    _detector =
        AutoWorkoutDetector(
            clock: () => _simulationClock?.now() ?? _realClock(),
            config: ref.read(detectorConfigProvider),
          )
          ..autoStartPrompts = state.autoStart
          ..autoStopPrompts = state.autoStop
          ..weightKg = state.weightKg;
    _summary = null;
    _subscribe();
    _simulatedSteps?.emit(0);
    _ensureTimer();
    _publish();
  }

  void simulate(ActivityType type) => _simulatedActivity?.emit(type);
}
