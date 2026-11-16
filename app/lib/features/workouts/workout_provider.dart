import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../core/router.dart' show routerProvider;
import 'data/activity_sources.dart';
import 'data/pending_workout_queue.dart';
import 'data/local_workout_notifications.dart';
import 'data/motion_history_source.dart';
import 'data/simulated_sources.dart';
import 'data/workout_repository.dart';
import 'data/workout_history_review.dart';
import 'domain/activity_sample.dart';
import 'domain/auto_workout_detector.dart';
import 'domain/workout_session.dart';
import 'domain/workout_notification_bridge.dart';

final motionHistorySourceProvider = Provider<MotionHistorySource>(
  (ref) => MotionHistorySource(),
);
final workoutNotificationSinkProvider = Provider<WorkoutNotificationSink>(
  (ref) => LocalWorkoutNotifications(),
);

WidgetsBinding? _workoutBinding() {
  try {
    return WidgetsBinding.instance;
  } catch (_) {
    return null;
  }
}

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
final workoutStoreProvider = Provider<WorkoutStore?>((ref) {
  try {
    final client = ref.watch(supabaseClientProvider);
    return client == null ? null : SupabaseWorkoutStore(client);
  } catch (_) {
    // Widget tests can configure fake auth/profile repositories without
    // initializing the Supabase singleton.
    return null;
  }
});
// Kept separate from the repository so these listeners survive auth/consent
// rebuilds, including the transition to an in-memory repository.
final workoutQueuePrivacyProvider = Provider<void>((ref) {
  final consentByUser = <String, bool>{};
  void clear(String userId) {
    unawaited(
      PendingWorkoutQueue(userId).clear().catchError((Object _) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: 'Pending workouts could not be cleared.',
          ),
        );
      }),
    );
  }

  ref.listen(currentUserProvider.select((user) => user?.id), (previous, next) {
    if (previous != null && next == null) clear(previous);
  });
  ref.listen(profileProvider, (_, next) {
    final profile = next.asData?.value;
    final userId = ref.read(currentUserProvider)?.id;
    if (profile == null || profile.userId != userId) return;
    final hadConsent = consentByUser[profile.userId];
    consentByUser[profile.userId] = profile.hasHealthConsent;
    // An actual withdrawal clears health data. Starting with consent off keeps
    // RLS-paused rows available for a later grant.
    if (hadConsent == true && !profile.hasHealthConsent) {
      clear(profile.userId);
    }
  }, fireImmediately: true);
});

final workoutRepositoryProvider = Provider<WorkoutRepository>((ref) {
  ref.watch(workoutQueuePrivacyProvider);
  final configured = ref.watch(backendConfiguredProvider);
  final userId = ref.watch(currentUserProvider.select((user) => user?.id));
  WorkoutStore? store;
  if (configured && userId != null) {
    // Matching the profile's owner also guards against stale async profile data
    // during an account switch. Refreshing the same consent keeps the queue.
    final consent = ref.watch(
      profileProvider.select(
        (profile) => (profile.value?.userId, profile.value?.hasHealthConsent),
      ),
    );
    if (consent.$1 == userId && consent.$2 == true) {
      store = ref.watch(workoutStoreProvider);
    }
  }
  final WorkoutRepository repository = store == null
      ? InMemoryWorkoutRepository()
      : SupabaseWorkoutRepository(
          store: store,
          userId: userId!,
          clock: ref.read(workoutClockProvider),
        );
  ref.onDispose(repository.dispose);
  if (repository is SupabaseWorkoutRepository) {
    ref.listen(profileProvider, (_, next) {
      final profile = next.asData?.value;
      if (profile?.userId == userId && profile?.hasHealthConsent == true) {
        unawaited(repository.resumeConsentPaused());
      }
    });
  }
  return repository;
});

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
    this.resumed = true,
    this.historyCandidates = const [],
    this.historyNotice,
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
  final bool resumed;
  final List<WorkoutSession> historyCandidates;
  final String? historyNotice;
}

final workoutProvider = NotifierProvider<WorkoutNotifier, WorkoutState>(
  WorkoutNotifier.new,
);

class WorkoutNotifier extends Notifier<WorkoutState>
    implements WorkoutPromptActions {
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
  int _buildVersion = 0;
  DateTime? _loadedDay, _lastRetryAt;
  late WorkoutNotificationBridge _notifications;
  late WorkoutHistoryReview _history;
  bool _resumed = true;
  String? _historyNotice;
  DateTime? _lastDetectorAdvance;
  DateTime? _nativeCursor, _nativeActiveStart, _nativeActiveThrough;
  bool _nativeActiveInitialized = false;
  WorkoutSession? _historyActive;

  @override
  WorkoutState build() {
    final version = ++_buildVersion;
    _realClock = ref.read(workoutClockProvider);
    _repository = ref.watch(workoutRepositoryProvider);
    _summary = null;
    _streamError = null;
    _simulationClock = null;
    _simulatedActivity = null;
    _simulatedSteps = null;
    _timer = null;
    _loadedDay = null;
    _lastRetryAt = null;
    _activitySource = ref.read(activitySourceProvider);
    _stepSource = ref.read(stepSourceProvider);
    _tickInterval = ref.read(workoutTickIntervalProvider);
    _detector = AutoWorkoutDetector(
      clock: () => _simulationClock?.now() ?? _realClock(),
      config: ref.read(detectorConfigProvider),
    );
    final binding = _workoutBinding();
    _resumed =
        binding?.lifecycleState == null ||
        binding?.lifecycleState == AppLifecycleState.resumed;
    _historyNotice = null;
    _lastDetectorAdvance = _realClock();
    _nativeCursor = _nativeActiveStart = _nativeActiveThrough = null;
    _nativeActiveInitialized = false;
    _historyActive = null;
    _notifications = WorkoutNotificationBridge(
      sink: ref.read(workoutNotificationSinkProvider),
      actions: this,
      onOpen: _openWorkouts,
    );
    _history = WorkoutHistoryReview(
      source: ref.read(motionHistorySourceProvider),
      repository: _repository,
      owner: ref.read(currentUserProvider)?.id ?? 'local',
      clock: _realClock,
      config: ref.read(detectorConfigProvider),
    );
    _history.source.onOpen(() => unawaited(_takeHistoryOpen(version)));
    final lifecycle = binding == null
        ? null
        : AppLifecycleListener(
            onStateChange: (value) {
              if (!ref.mounted || version != _buildVersion) return;
              _resumed = value == AppLifecycleState.resumed;
              // A cached movement state cannot prove that activity continued
              // while Dart was suspended. Let history handle that missing period.
              if (_detector.phase == DetectorPhase.candidate &&
                  _realClock().difference(_lastDetectorAdvance!) >
                      const Duration(minutes: 1)) {
                _detector =
                    AutoWorkoutDetector(
                        clock: _detector.clock,
                        config: _detector.config,
                      )
                      ..autoStartPrompts = _detector.autoStartPrompts
                      ..autoStopPrompts = _detector.autoStopPrompts
                      ..weightKg = _detector.weightKg;
              }
              _lastDetectorAdvance = _realClock();
              _detector.tick();
              _publish();
              if (_resumed) unawaited(checkHistory());
            },
          );
    final repositorySubscription = _repository.changes.listen((_) {
      if (ref.mounted && version == _buildVersion) _publish();
    });
    // Start listening after build so even synchronous fake streams are safe.
    Future.microtask(() {
      if (ref.mounted && version == _buildVersion) {
        _subscribe();
        _ensureTimer();
        _publish();
        _loadToday();
        unawaited(_takeHistoryOpen(version));
        unawaited(checkHistory());
      }
    });
    ref.onDispose(() {
      lifecycle?.dispose();
      _history.source.onOpen(null);
      _notifications.dispose();
      _buildVersion++;
      _generation++;
      _timer?.cancel();
      unawaited(_activitySubscription?.cancel());
      unawaited(_stepSubscription?.cancel());
      unawaited(repositorySubscription.cancel());
      unawaited(_simulatedActivity?.dispose());
      unawaited(_simulatedSteps?.dispose());
    });
    return WorkoutState(now: _realClock());
  }

  void _subscribe() {
    final generation = ++_generation;
    void changed({bool detectorChanged = false}) {
      if (!ref.mounted || generation != _generation) return;
      _ensureTimer();
      _publish(detectorChanged: detectorChanged);
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
        _lastDetectorAdvance = _realClock();
        changed(detectorChanged: true);
      },
      onError: failed,
      onDone: changed,
    );
    _stepSubscription = _stepSource.samples.listen(
      (sample) {
        if (!ref.mounted || generation != _generation) return;
        _detector.addSteps(sample);
        changed(detectorChanged: true);
      },
      onError: failed,
      onDone: changed,
    );
  }

  void _ensureTimer() {
    // Remote sync needs ticks even without sensors. Keep the memory fallback
    // inert in desktop/widget tests without platform mocks.
    if (_timer == null &&
        _tickInterval != null &&
        (_repository is SupabaseWorkoutRepository ||
            _simulationClock != null ||
            _detector.phase != DetectorPhase.idle)) {
      _timer = Timer.periodic(_tickInterval!, (_) => tick());
    }
  }

  void tick() {
    _lastDetectorAdvance = _realClock();
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
    _publish(detectorChanged: true);
    _loadToday();
    final now = _realClock();
    if (_lastRetryAt == null ||
        now.difference(_lastRetryAt!) >= const Duration(minutes: 1)) {
      _lastRetryAt = now;
      unawaited(_repository.retryPending());
    }
  }

  void _loadToday() {
    final now = _detector.clock().toLocal();
    final day = DateTime(now.year, now.month, now.day);
    if (_loadedDay == day) return;
    _loadedDay = day;
    _lastRetryAt = _realClock();
    unawaited(
      _repository.loadRange(day, DateTime(day.year, day.month, day.day + 1)),
    );
  }

  void _publish({bool detectorChanged = false}) {
    for (final event in _detector.takeEvents()) {
      if (event is WorkoutFinished) {
        unawaited(_repository.save(event.session));
        _summary = event.session;
      }
    }
    final now = _detector.clock();
    final active = _detector.currentSession;
    // UI clocks and repository/notice changes do not measure a workout. Keep
    // the last detector snapshot so these publishes neither renew its lease
    // nor write to the native channel every second.
    if (detectorChanged || active == null || _historyActive == null) {
      _historyActive = active;
    }
    _syncNativeWorkouts(
      _historyActive?.isFreshActiveAt(_realClock()) == true
          ? _historyActive
          : null,
    );
    final today = _repository.sessions.where((session) {
      final date = session.startedAt.toLocal();
      final localNow = now.toLocal();
      return date.year == localNow.year &&
          date.month == localNow.month &&
          date.day == localNow.day;
    }).toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    state = WorkoutState(
      now: now,
      phase: _detector.phase,
      candidateType: _detector.candidateType,
      activityStartedAt: _detector.activityStartedAt,
      startPrompt: _detector.startPrompt,
      stopPrompt: _detector.stopPrompt,
      session: active,
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
      resumed: _resumed,
      historyCandidates: _detector.autoStartPrompts
          ? List.unmodifiable(_history.candidates)
          : const [],
      historyNotice: _historyNotice,
    );
    unawaited(
      _notifications.update(
        resumed: _resumed,
        autoStart: state.autoStart,
        autoStop: state.autoStop,
        now: now,
        start: state.startPrompt,
        stop: state.stopPrompt,
      ),
    );
  }

  Future<void> requestNotificationPermission() async {
    var granted = false;
    try {
      await _notifications.initialize();
      granted = await ref
          .read(workoutNotificationSinkProvider)
          .requestPermission();
    } catch (_) {
      // Unavailable plugins use the same settings notice as a denial.
    }
    if (!ref.mounted) return;
    _historyNotice = granted
        ? 'Workout notifications enabled.'
        : 'Notifications unavailable or denied. You can enable them in your phone settings.';
    _publish();
  }

  void _syncNativeWorkouts(WorkoutSession? active) {
    final source = _history.source;
    if (!source.available) return;
    // Simulator time can run ahead of wall time; it must not consume real
    // motion history or leave a native active-workout marker behind.
    if (_simulationClock != null) active = null;
    if (!_nativeActiveInitialized ||
        _nativeActiveStart != active?.startedAt ||
        _nativeActiveThrough != active?.measuredAt) {
      _nativeActiveInitialized = true;
      _nativeActiveStart = active?.startedAt;
      _nativeActiveThrough = active?.measuredAt;
      unawaited(source.setActiveWorkout(active).catchError((Object _) {}));
      // setActiveWorkout also advances the cursor; avoid a second channel call
      // for the same measurement.
      final measuredAt = active?.measuredAt;
      if (measuredAt != null &&
          (_nativeCursor == null || measuredAt.isAfter(_nativeCursor!))) {
        _nativeCursor = measuredAt;
      }
    }
    if (_simulationClock != null) return;
    DateTime? through = active?.measuredAt;
    for (final session in [..._repository.sessions, ?_summary]) {
      final end = session.endedAt;
      if (end != null && (through == null || end.isAfter(through))) {
        through = end;
      }
    }
    if (through != null &&
        (_nativeCursor == null || through.isAfter(_nativeCursor!))) {
      _nativeCursor = through;
      unawaited(source.advanceRefreshCursor(through).catchError((Object _) {}));
    }
  }

  void _openWorkouts() {
    if (ref.mounted) ref.read(routerProvider).go('/today');
  }

  Future<void> _takeHistoryOpen(int version) async {
    try {
      final opened = await _history.source.takeOpenRequest();
      if (opened && ref.mounted && version == _buildVersion) {
        _openWorkouts();
        unawaited(checkHistory());
      }
    } catch (_) {
      // A missing native channel must not interfere with live detection.
    }
  }

  Future<void> checkHistory() async {
    final version = _buildVersion;
    final history = _history;
    try {
      await history.source.configure(
        enabled: _detector.autoStartPrompts && _simulationClock == null,
      );
      if (!ref.mounted || version != _buildVersion) return;
      await history.check(
        enabled: _detector.autoStartPrompts && _simulationClock == null,
        weightKg: _detector.weightKg,
        active: _historyActive,
      );
      if (!ref.mounted || version != _buildVersion) return;
      _historyNotice = null;
      _publish();
    } catch (_) {
      if (!ref.mounted || version != _buildVersion) return;
      _historyNotice =
          'Motion history unavailable. We’ll try again when you return.';
      _publish();
    }
  }

  Future<void> reviewHistory(
    WorkoutSession candidate, {
    required bool save,
  }) async {
    final version = _buildVersion;
    try {
      await _history.resolve(candidate, save: save);
      if (!ref.mounted || version != _buildVersion) return;
      _historyNotice = null;
      _publish();
    } catch (_) {
      if (!ref.mounted || version != _buildVersion) return;
      _historyNotice = 'Could not update this suggestion. Please try again.';
      _publish();
    }
  }

  void setAutoStart(bool enabled) {
    _detector.autoStartPrompts = enabled;
    _detector.tick();
    _publish(detectorChanged: true);
    unawaited(checkHistory());
  }

  void setAutoStop(bool enabled) {
    _detector.autoStopPrompts = enabled;
    _detector.tick();
    _publish(detectorChanged: true);
  }

  bool setWeight(double weight) {
    if (!weight.isFinite || weight < 20 || weight > 400) return false;
    _detector.weightKg = weight;
    _publish();
    return true;
  }

  @override
  void acceptStart(ExerciseType type) {
    _detector.acceptStart(type);
    _ensureTimer();
    _publish(detectorChanged: true);
  }

  @override
  void dismissStart() {
    _detector.dismissStart();
    _publish(detectorChanged: true);
  }

  @override
  void acceptStop() {
    _detector.acceptStop();
    _publish(detectorChanged: true);
  }

  @override
  void dismissStop() {
    _detector.dismissStop();
    _publish(detectorChanged: true);
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
    _publish(detectorChanged: true);
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
