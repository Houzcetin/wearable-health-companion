import BackgroundTasks
import CoreMotion
import Flutter
import UserNotifications

/// Queries recorded motion only. No live detector, background location, or
/// database writes run here. All callbacks/state changes return to main.
final class WorkoutMotionHistory {
  static let refreshID = "com.wearablecompanion.workouts.refresh"
  private let activity = CMMotionActivityManager()
  private let pedometer = CMPedometer()
  private let defaults: UserDefaults
  private var channel: FlutterMethodChannel?
  private(set) var workoutRevision = 0

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  @discardableResult
  func advanceRefreshCursor(_ through: Date, notify: Bool = true) -> Bool {
    let existing = defaults.object(forKey: "workouts.refresh.checked") as? Date ?? .distantPast
    guard through > existing else { return false }
    defaults.set(through, forKey: "workouts.refresh.checked")
    if notify { workoutChanged() }
    return true
  }

  func setActiveWorkout(from: Date?, through: Date?) {
    let previous = defaults.dictionary(forKey: "workouts.refresh.active")
    let changed: Bool
    var advanced = false
    if let from = from, let through = through {
      changed = (previous?["from"] as? Date) != from || (previous?["through"] as? Date) != through
      if changed {
        defaults.set(["from": from, "through": through], forKey: "workouts.refresh.active")
      }
      advanced = advanceRefreshCursor(through, notify: false)
    } else {
      // Also remove a legacy onset-only marker, which has no expiry snapshot.
      changed = defaults.object(forKey: "workouts.refresh.active") != nil
      if changed { defaults.removeObject(forKey: "workouts.refresh.active") }
    }
    if changed || advanced { workoutChanged() }
  }

  func activeWorkoutStart(at now: Date) -> Date? {
    guard let marker = defaults.dictionary(forKey: "workouts.refresh.active"),
          let from = marker["from"] as? Date, let through = marker["through"] as? Date,
          from <= through, through <= now,
          now <= min(through.addingTimeInterval(15 * 60), from.addingTimeInterval(86400)) else { return nil }
    return from
  }

  private func workoutChanged() {
    workoutRevision += 1
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: ["workouts.history"])
    center.removeDeliveredNotifications(withIdentifiers: ["workouts.history"])
  }

  func openReview() {
    defaults.set(true, forKey: "workouts.history.open")
    channel?.invokeMethod("openHistory", arguments: nil)
  }

  func registerChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "workouts/motion_history", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "takeOpenRequest":
        let opened = self.defaults.bool(forKey: "workouts.history.open")
        self.defaults.removeObject(forKey: "workouts.history.open")
        result(opened)
      case "queryActivities", "querySteps":
        guard let fromMS = args["from"] as? NSNumber, let toMS = args["to"] as? NSNumber else {
          result(FlutterError(code: "invalid_range", message: "A time range is required.", details: nil))
          return
        }
        let to = min(Date(timeIntervalSince1970: toMS.doubleValue / 1000), Date())
        let from = max(Date(timeIntervalSince1970: fromMS.doubleValue / 1000), to.addingTimeInterval(-7 * 86400))
        guard from < to else { result(FlutterError(code: "invalid_range", message: "Invalid time range.", details: nil)); return }
        if call.method == "queryActivities" {
          self.queryActivities(from: from, to: to) { rows, error in
            if let error = error {
              result(FlutterError(code: "motion_unavailable", message: error.localizedDescription, details: nil))
            } else { result(rows) }
          }
        } else {
          self.querySteps(from: from, to: to) { data, error in
            if let error = error {
              result(FlutterError(code: "steps_unavailable", message: error.localizedDescription, details: nil))
            } else {
              var row: [String: Any] = ["steps": data?.numberOfSteps.intValue ?? 0]
              if let distance = data?.distance { row["distance"] = distance.doubleValue }
              result(row)
            }
          }
        }
      case "readState":
        let owner = args["owner"] as? String ?? "local"
        result(self.defaults.dictionary(forKey: "workouts.history.\(owner)") ?? [:])
      case "writeState":
        let owner = args["owner"] as? String ?? "local"
        // Flutter's null values are NSNull, which UserDefaults cannot store.
        if let state = args["state"] as? [String: Any] {
          self.defaults.set(state.filter { !($0.value is NSNull) }, forKey: "workouts.history.\(owner)")
        }
        result(nil)
      case "configure":
        let enabled = args["enabled"] as? Bool ?? false
        self.defaults.set(enabled, forKey: "workouts.refresh.enabled")
        if enabled { self.scheduleRefresh() }
        else {
          BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
          UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["workouts.history"])
        }
        result(nil)
      case "advanceRefreshCursor":
        if let ms = args["through"] as? NSNumber {
          self.advanceRefreshCursor(Date(timeIntervalSince1970: ms.doubleValue / 1000))
        }
        result(nil)
      case "setActiveWorkout":
        if let from = args["from"] as? NSNumber, let through = args["through"] as? NSNumber {
          self.setActiveWorkout(from: Date(timeIntervalSince1970: from.doubleValue / 1000),
                                through: Date(timeIntervalSince1970: through.doubleValue / 1000))
        } else {
          self.setActiveWorkout(from: nil, through: nil)
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func queryActivities(from: Date, to: Date,
                               completion: @escaping ([[String: Any]], Error?) -> Void) {
    guard CMMotionActivityManager.isActivityAvailable() else { completion([], nil); return }
    activity.queryActivityStarting(from: from, to: to, to: .main) { activities, error in
      let rows = (activities ?? []).map { a -> [String: Any] in
        ["start": a.startDate.timeIntervalSince1970 * 1000,
         "walking": a.walking, "running": a.running, "cycling": a.cycling,
         "stationary": a.stationary, "automotive": a.automotive, "unknown": a.unknown,
         "confidence": a.confidence.rawValue]
      }
      completion(rows, error)
    }
  }

  private func querySteps(from: Date, to: Date,
                          completion: @escaping (CMPedometerData?, Error?) -> Void) {
    guard CMPedometer.isStepCountingAvailable() else { completion(nil, nil); return }
    pedometer.queryPedometerData(from: from, to: to) { data, error in
      DispatchQueue.main.async { completion(data, error) }
    }
  }

  func registerRefresh() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: .main) { [weak self] task in
      guard let self = self, let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self.refresh(refresh)
    }
    if defaults.bool(forKey: "workouts.refresh.enabled") { scheduleRefresh() }
  }

  private func scheduleRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
    // iOS chooses whether/when to run it, including when Background App Refresh
    // is disabled. Failure leaves resume/cold-start history checks available.
    try? BGTaskScheduler.shared.submit(request)
  }

  /// Pure replay used by refresh and the shared Dart/Swift golden fixture.
  static func replay(_ rows: [[String: Any]], from: Date, to: Date, active: Date? = nil)
    -> (bouts: [(kind: String, from: Date, to: Date)], checkedThrough: Date) {
    // Mirror default detector minimums (walk 10m, run 3m, bike 5m),
    // only high confidence. State records persist until the next record.
    var kind: String?
    var start: Date?
    var end: Date?
    var found: [(kind: String, from: Date, to: Date)] = []
    var toleratedUncertainGap = false
    var awaitingUncertainReturn = false
    func collect() {
      guard let kind = kind, let start = start, let end = end else { return }
      let seconds = end.timeIntervalSince(start)
      let minimum: TimeInterval = kind == "walked" ? 600 : (kind == "ran" ? 180 : 300)
      if seconds >= minimum && (active == nil || end <= active!) {
        found.append((kind, start, end))
      }
    }
    func exercise(_ row: [String: Any]) -> String? {
      guard (row["confidence"] as? Int) == 2 && (row["automotive"] as? Bool) != true else { return nil }
      if row["running"] as? Bool == true { return "ran" }
      if row["cycling"] as? Bool == true { return "cycled" }
      if row["walking"] as? Bool == true { return "walked" }
      return nil
    }
    let ordered = rows.filter { ($0["start"] as? Double ?? 0) <= to.timeIntervalSince1970 * 1000 }.sorted { ($0["start"] as? Double ?? 0) < ($1["start"] as? Double ?? 0) }
    for (index, row) in ordered.enumerated() {
      guard let ms = row["start"] as? Double else { continue }
      let at = max(Date(timeIntervalSince1970: ms / 1000), from)
      // Match Dart: tolerate one medium/low record <= 2 minutes only when
      // followed immediately by high-confidence movement of the same type.
      if kind != nil && end == nil && !toleratedUncertainGap,
         (row["confidence"] as? Int ?? 0) < 2, index + 1 < ordered.count,
         let nextMS = ordered[index + 1]["start"] as? Double,
         exercise(ordered[index + 1]) == kind,
         max(Date(timeIntervalSince1970: nextMS / 1000), from).timeIntervalSince(at) <= 120 {
        toleratedUncertainGap = true
        continue
      }
      let next = exercise(row)
      if let next = next {
        if kind != next || (end != nil && at.timeIntervalSince(end!) > 60) {
          if kind != nil && end == nil { end = at }
          collect()
          start = at
          kind = next
          toleratedUncertainGap = false
        }
        end = nil
        awaitingUncertainReturn = false
      } else if kind != nil {
        awaitingUncertainReturn = end == nil && !toleratedUncertainGap && (row["confidence"] as? Int ?? 0) < 2
        if end == nil { end = at }
      }
    }
    let tailTolerance: TimeInterval = awaitingUncertainReturn ? 120 : 60
    if let end = end, to.timeIntervalSince(end) > tailTolerance { collect() }
    // Keep an ongoing tail for the next refresh. This cursor is separate
    // from Dart's review cursor: a reminder must never consume a suggestion.
    let tailOpen = end == nil || to.timeIntervalSince(end!) <= tailTolerance
    return (found, tailOpen ? (start ?? to) : to)
  }

  private func refresh(_ task: BGAppRefreshTask) {
    guard defaults.bool(forKey: "workouts.refresh.enabled"),
          CMMotionActivityManager.authorizationStatus() == .authorized else {
      task.setTaskCompleted(success: true)
      return
    }
    scheduleRefresh()
    var completed = false
    func finish(_ success: Bool) {
      guard !completed else { return }
      completed = true
      task.setTaskCompleted(success: success)
    }
    task.expirationHandler = { DispatchQueue.main.async { finish(false) } }
    let to = Date()
    let last = defaults.object(forKey: "workouts.refresh.checked") as? Date ?? to.addingTimeInterval(-86400)
    let from = max(last, to.addingTimeInterval(-86400))
    guard from < to else { finish(true); return }
    let revision = workoutRevision
    queryActivities(from: from, to: to) { [weak self] rows, error in
      guard let self = self, !completed else { return }
      guard revision == self.workoutRevision else { finish(true); return }
      guard error == nil else { finish(false); return }
      let replay = Self.replay(rows, from: from, to: to, active: self.activeWorkoutStart(at: to))
      let found = replay.bouts
      // This refresh's own cursor update must not invalidate its revision.
      self.advanceRefreshCursor(replay.checkedThrough, notify: false)
      guard !found.isEmpty else { finish(true); return }
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        DispatchQueue.main.async {
          guard !completed, revision == self.workoutRevision,
                self.defaults.bool(forKey: "workouts.refresh.enabled") else { finish(true); return }
          guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            finish(true); return // Never ask permission in a background task.
          }
          let content = UNMutableNotificationContent()
          content.title = found.count > 1
            ? "\(found.count) activities to review"
            : "Looks like you \(found[0].kind) \(Int(found[0].to.timeIntervalSince(found[0].from) / 60)) min — tap to log it"
          content.body = "Review your recent activities in the app."
          content.sound = .default
          let request = UNNotificationRequest(identifier: "workouts.history", content: content, trigger: nil)
          UNUserNotificationCenter.current().add(request) { error in
            DispatchQueue.main.async {
              if revision != self.workoutRevision {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["workouts.history"])
              }
              finish(error == nil)
            }
          }
        }
      }
    }
  }
}
