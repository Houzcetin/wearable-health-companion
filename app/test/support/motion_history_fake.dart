import 'package:wearable_companion/features/workouts/data/motion_history_source.dart';
import 'package:wearable_companion/features/workouts/domain/activity_sample.dart';

class FakeMotionHistory extends MotionHistorySource {
  FakeMotionHistory(this.origin) : super(available: true);
  final DateTime origin;
  final stored = <String, Map<String, dynamic>>{};
  final ranges = <(DateTime, DateTime)>[];
  bool fail = false;
  @override
  void onOpen(void Function()? callback) {}
  @override
  Future<bool> takeOpenRequest() async => false;
  List<ActivitySample>? activities;
  @override
  Future<Map<String, dynamic>> readState(String owner) async =>
      stored[owner] ?? {};
  @override
  Future<void> writeState(String owner, Map<String, dynamic> state) async {
    stored[owner] = state;
  }

  @override
  Future<void> configure({required bool enabled}) async {}
  @override
  Future<List<ActivitySample>> queryActivities(
    DateTime from,
    DateTime to,
  ) async {
    if (fail) throw StateError('Motion permission denied');
    ranges.add((from, to));
    final rows =
        activities ??
        [
          ActivitySample(
            type: ActivityType.walking,
            confidence: 100,
            timestamp: origin,
          ),
          ActivitySample(
            type: ActivityType.still,
            confidence: 100,
            timestamp: origin.add(const Duration(minutes: 35)),
          ),
        ];
    return rows
        .where((s) => !s.timestamp.isBefore(from) && !s.timestamp.isAfter(to))
        .toList();
  }

  @override
  Future<HistorySteps> querySteps(DateTime from, DateTime to) async {
    final start = from.isBefore(origin) ? origin : from;
    final end = to.isAfter(origin.add(const Duration(minutes: 35)))
        ? origin.add(const Duration(minutes: 35))
        : to;
    return HistorySteps(
      end.isAfter(start) ? end.difference(start).inSeconds * 100 ~/ 60 : 0,
    );
  }
}
