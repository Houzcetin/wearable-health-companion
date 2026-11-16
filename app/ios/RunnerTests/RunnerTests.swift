import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testMotionHistoryGolden() throws {
    // The test bundle copies the same file that the Dart golden test reads.
    let url = try XCTUnwrap(Bundle(for: RunnerTests.self).url(
      forResource: "workout_motion_history", withExtension: "json"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: Double(seconds)) }
    for item in cases {
      let name = try XCTUnwrap(item["name"] as? String)
      let activities = try XCTUnwrap(item["activities"] as? [[Any]])
      let rows: [[String: Any]] = try activities.map { activity in
        let seconds = try XCTUnwrap(activity[0] as? Int)
        let type = try XCTUnwrap(activity[1] as? String)
        let confidence = try XCTUnwrap(activity[2] as? Int)
        return ["start": Double(seconds) * 1000, type: true, "confidence": confidence]
      }
      let result = WorkoutMotionHistory.replay(rows, from: at(0), to: at(try XCTUnwrap(item["to"] as? Int)))
      let expected = try XCTUnwrap(item["bouts"] as? [[Any]])
      XCTAssertEqual(result.bouts.count, expected.count, name)
      for (bout, row) in zip(result.bouts, expected) {
        let kind = ["walk": "walked", "run": "ran", "bike": "cycled"][try XCTUnwrap(row[0] as? String)]
        XCTAssertEqual(bout.kind, kind, name)
        XCTAssertEqual(bout.from, at(try XCTUnwrap(row[1] as? Int)), name)
        XCTAssertEqual(bout.to, at(try XCTUnwrap(row[2] as? Int)), name)
      }
      XCTAssertEqual(result.checkedThrough, at(try XCTUnwrap(item["checkedThrough"] as? Int)), name)
    }
  }

  private func history() -> (WorkoutMotionHistory, UserDefaults) {
    let suite = "workout-history-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return (WorkoutMotionHistory(defaults: defaults), defaults)
  }

  func testActiveMarkerExpiryAndLegacyMarker() {
    let (history, defaults) = history()
    let start = Date(timeIntervalSince1970: 100000)
    let through = start.addingTimeInterval(600)
    history.setActiveWorkout(from: start, through: through)
    XCTAssertEqual(defaults.dictionary(forKey: "workouts.refresh.active")?["through"] as? Date, through)
    XCTAssertEqual(history.activeWorkoutStart(at: through.addingTimeInterval(900)), start)
    XCTAssertNil(history.activeWorkoutStart(at: through.addingTimeInterval(900.001)))
    let cap = start.addingTimeInterval(86400)
    history.setActiveWorkout(from: start, through: cap)
    XCTAssertEqual(history.activeWorkoutStart(at: cap), start)
    history.setActiveWorkout(from: start, through: cap.addingTimeInterval(0.001))
    XCTAssertNil(history.activeWorkoutStart(at: cap.addingTimeInterval(0.001)))
    XCTAssertNil(history.activeWorkoutStart(at: start)) // Future measurement.
    history.setActiveWorkout(from: through, through: start)
    XCTAssertNil(history.activeWorkoutStart(at: through)) // Invalid range.
    defaults.set(start, forKey: "workouts.refresh.active") // Old onset-only format.
    XCTAssertNil(history.activeWorkoutStart(at: through))
  }

  func testExpiredMarkerAllowsBackgroundBout() {
    let (history, _) = history()
    let start = Date(timeIntervalSince1970: 0)
    history.setActiveWorkout(from: start, through: start.addingTimeInterval(600))
    let rows: [[String: Any]] = [
      ["start": 0.0, "walking": true, "confidence": 2],
      ["start": 1200000.0, "stationary": true, "confidence": 2]
    ]
    let fresh = start.addingTimeInterval(1500)
    XCTAssertTrue(WorkoutMotionHistory.replay(rows, from: start, to: fresh,
      active: history.activeWorkoutStart(at: fresh)).bouts.isEmpty)
    let expired = fresh.addingTimeInterval(0.001)
    XCTAssertEqual(WorkoutMotionHistory.replay(rows, from: start, to: expired,
      active: history.activeWorkoutStart(at: expired)).bouts.count, 1)
  }

  func testOnlyChangedMarkerOrAdvancedCursorInvalidatesReminders() {
    let (history, defaults) = history()
    let start = Date(timeIntervalSince1970: 100000)
    history.setActiveWorkout(from: nil, through: nil)
    XCTAssertEqual(history.workoutRevision, 0)
    history.setActiveWorkout(from: start, through: start)
    XCTAssertEqual(history.workoutRevision, 1) // Marker + cursor: one change.
    history.setActiveWorkout(from: start, through: start)
    XCTAssertEqual(history.workoutRevision, 1)
    XCTAssertFalse(history.advanceRefreshCursor(start))
    XCTAssertFalse(history.advanceRefreshCursor(start.addingTimeInterval(-1)))
    XCTAssertEqual(history.workoutRevision, 1)
    let next = start.addingTimeInterval(15)
    history.setActiveWorkout(from: start, through: next)
    XCTAssertEqual(history.workoutRevision, 2)
    history.setActiveWorkout(from: nil, through: nil)
    XCTAssertEqual(history.workoutRevision, 3)
    history.setActiveWorkout(from: nil, through: nil)
    XCTAssertEqual(history.workoutRevision, 3)
    XCTAssertTrue(history.advanceRefreshCursor(next.addingTimeInterval(15)))
    XCTAssertEqual(history.workoutRevision, 4)
    XCTAssertTrue(history.advanceRefreshCursor(next.addingTimeInterval(30), notify: false))
    XCTAssertEqual(history.workoutRevision, 4) // Refresh must not invalidate itself.
    XCTAssertEqual(defaults.object(forKey: "workouts.refresh.checked") as? Date, next.addingTimeInterval(30))
  }

}
