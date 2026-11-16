import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_companion/features/workouts/data/local_workout_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var enabled = false;
  var provisional = false;

  setUp(() {
    calls.clear();
    enabled = provisional = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'initialize' => true,
        'getNotificationAppLaunchDetails' => {'notificationLaunchedApp': false},
        'checkPermissions' => {
          'isEnabled': enabled,
          'isProvisionalEnabled': provisional,
        },
        'areNotificationsEnabled' => enabled,
        'requestPermissions' || 'requestNotificationsPermission' => true,
        _ => null,
      };
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test(
      '$platform initialization and status checks never request permission',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        if (platform == TargetPlatform.iOS) {
          IOSFlutterLocalNotificationsPlugin.registerWith();
        } else {
          AndroidFlutterLocalNotificationsPlugin.registerWith();
        }
        final sink = LocalWorkoutNotifications();
        await sink.initialize((_, _) {});
        if (platform == TargetPlatform.iOS) {
          final settings =
              calls.firstWhere((call) => call.method == 'initialize').arguments
                  as Map;
          expect(settings['requestAlertPermission'], isFalse);
          expect(settings['requestSoundPermission'], isFalse);
          expect(settings['requestBadgePermission'], isFalse);
        }
        expect(await sink.checkPermission(), isFalse);
        enabled = true;
        expect(await sink.checkPermission(), isTrue);
        expect(
          calls.where((call) => call.method.startsWith('request')),
          isEmpty,
        );
        expect(
          calls.where(
            (call) =>
                call.method ==
                (platform == TargetPlatform.iOS
                    ? 'checkPermissions'
                    : 'areNotificationsEnabled'),
          ),
          hasLength(2),
        );
        expect(await sink.requestPermission(), isTrue);
        expect(
          calls.last.method,
          platform == TargetPlatform.iOS
              ? 'requestPermissions'
              : 'requestNotificationsPermission',
        );
      },
    );
  }

  test('iOS provisional authorization permits a quiet notification', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
    provisional = true;
    expect(await LocalWorkoutNotifications().checkPermission(), isTrue);
    expect(calls.single.method, 'checkPermissions');
  });
}
