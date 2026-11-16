import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/workout_notification_bridge.dart';

class LocalWorkoutNotifications implements WorkoutNotificationSink {
  final _plugin = FlutterLocalNotificationsPlugin();
  static const _id = 7101;
  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  Future<void> initialize(void Function(String, String?) onAction) async {
    if (!_supported) return;
    // All actions open the main isolate so they reach the same in-memory
    // notifier used by sheets; a background isolate would have different state.
    final categories = [
      DarwinNotificationCategory(
        'workout_start',
        actions: [
          DarwinNotificationAction.plain(
            'start',
            'Start',
            options: {DarwinNotificationActionOption.foreground},
          ),
          DarwinNotificationAction.plain(
            'not_now',
            'Not now',
            options: {DarwinNotificationActionOption.foreground},
          ),
        ],
      ),
      DarwinNotificationCategory(
        'workout_stop',
        actions: [
          DarwinNotificationAction.plain(
            'stop',
            'Stop',
            options: {DarwinNotificationActionOption.foreground},
          ),
          DarwinNotificationAction.plain(
            'keep_going',
            'Keep going',
            options: {DarwinNotificationActionOption.foreground},
          ),
        ],
      ),
    ];
    void response(NotificationResponse response) =>
        onAction(response.actionId ?? '', response.payload);
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('ic_workout_notification'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: categories,
        ),
      ),
      onDidReceiveNotificationResponse: response,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true &&
        launch?.notificationResponse != null) {
      response(launch!.notificationResponse!);
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true, badge: false) ??
          false;
    }
    return await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission() ??
        false;
  }

  @override
  Future<void> show(WorkoutPromptNotification prompt) async {
    if (!_supported) return;
    await _plugin.show(
      id: _id,
      title: prompt.title,
      body: 'Tap to review your workout.',
      payload: prompt.key,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'workout_prompts',
          'Workout prompts',
          channelDescription: 'Start and stop detected workouts',
          importance: Importance.high,
          priority: Priority.high,
          timeoutAfter: prompt.remaining.inMilliseconds.clamp(1, 1 << 31),
          actions: prompt.isStart
              ? const [
                  AndroidNotificationAction(
                    'start',
                    'Start',
                    showsUserInterface: true,
                  ),
                  AndroidNotificationAction(
                    'not_now',
                    'Not now',
                    showsUserInterface: true,
                  ),
                ]
              : const [
                  AndroidNotificationAction(
                    'stop',
                    'Stop',
                    showsUserInterface: true,
                  ),
                  AndroidNotificationAction(
                    'keep_going',
                    'Keep going',
                    showsUserInterface: true,
                  ),
                ],
        ),
        iOS: DarwinNotificationDetails(
          categoryIdentifier: prompt.isStart ? 'workout_start' : 'workout_stop',
          presentAlert: false,
          presentBanner: false,
          presentList: false,
        ),
      ),
    );
  }

  @override
  Future<void> cancel() async {
    if (_supported) await _plugin.cancel(id: _id);
  }
}
