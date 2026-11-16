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
  private let defaults = UserDefaults.standard
  private var channel: FlutterMethodChannel?

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
    queryActivities(from: from, to: to) { [weak self] rows, error in
      guard let self = self, !completed else { return }
      guard error == nil else { finish(false); return }
      // Mirror default detector minimums (walk 10m, run 3m, bike 5m),
      // only high confidence. State records persist until the next record.
      var kind: String?
      var start: Date?
      var end: Date?
      var found: (String, Int)?
      func collect() {
        guard let kind = kind, let start = start, let end = end else { return }
        let seconds = end.timeIntervalSince(start)
        let minimum: TimeInterval = kind == "walked" ? 600 : (kind == "ran" ? 180 : 300)
        if seconds >= minimum { found = (kind, Int(seconds / 60)) }
      }
      for row in rows {
        guard let ms = row["start"] as? Double else { continue }
        let at = max(Date(timeIntervalSince1970: ms / 1000), from)
        var next: String?
        if (row["confidence"] as? Int) == 2 && (row["automotive"] as? Bool) != true {
          if row["running"] as? Bool == true { next = "ran" }
          else if row["cycling"] as? Bool == true { next = "cycled" }
          else if row["walking"] as? Bool == true { next = "walked" }
        }
        if let next = next {
          if kind != next || (end != nil && at.timeIntervalSince(end!) > 60) {
            if kind != nil && end == nil { end = at }
            collect()
            start = at
            kind = next
          }
          end = nil
        } else if kind != nil && end == nil { end = at }
      }
      if let end = end, to.timeIntervalSince(end) > 60 { collect() }
      // Keep an ongoing tail for the next refresh. This cursor is separate
      // from Dart's review cursor: a reminder must never consume a suggestion.
      let tailOpen = end == nil || to.timeIntervalSince(end!) <= 60
      self.defaults.set(tailOpen ? (start ?? to) : to, forKey: "workouts.refresh.checked")
      guard let found = found else { finish(true); return }
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        DispatchQueue.main.async {
          guard !completed, self.defaults.bool(forKey: "workouts.refresh.enabled") else { finish(true); return }
          guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            finish(true); return // Never ask permission in a background task.
          }
          let content = UNMutableNotificationContent()
          content.title = "Looks like you \(found.0) \(found.1) min — tap to log it"
          content.body = "Review your recent workout in the app."
          content.sound = .default
          let request = UNNotificationRequest(identifier: "workouts.history", content: content, trigger: nil)
          UNUserNotificationCenter.current().add(request) { error in
            DispatchQueue.main.async { finish(error == nil) }
          }
        }
      }
    }
  }
}
