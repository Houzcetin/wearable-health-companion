import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wearable_companion/data/profile_repository.dart';

void main() {
  const userId = '00000000-0000-4000-8000-000000000001';
  late SupabaseClient client;
  late Map<String, dynamic> storedRow;
  late List<Map<String, dynamic>> timezoneUpdates;
  late bool failTimezoneUpdate;

  setUp(() async {
    storedRow = {
      'user_id': userId,
      'display_name': 'Pip',
      'timezone': 'Europe/Istanbul',
      'health_consent_at': null,
      'coach_consent_at': null,
    };
    timezoneUpdates = [];
    failTimezoneUpdate = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/rest/v1/profiles');
      expect(request.uri.queryParameters['user_id'], 'eq.$userId');
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET') {
        request.response.write(jsonEncode(storedRow));
      } else {
        expect(request.method, 'PATCH');
        final update =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        timezoneUpdates.add(update);
        if (failTimezoneUpdate) {
          // Make the Supabase client throw on the timezone write, as in QA.
          request.response.statusCode = 400;
          request.response.write(
            jsonEncode({'code': '22023', 'message': 'invalid timezone'}),
          );
        } else {
          storedRow.addAll(update);
          request.response.statusCode = 204;
        }
      }
      await request.response.close();
    });
    client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'synthetic-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
  });

  test(
    'fetchProfile returns the stored profile when the timezone write throws',
    () async {
      failTimezoneUpdate = true;
      final repository = SupabaseProfileRepository(
        client,
        deviceTimezone: () async => 'Europe/Kiev',
      );

      final profile = await repository.fetchProfile(userId);

      expect(profile, isA<Profile>());
      expect(profile.userId, userId);
      expect(profile.displayName, 'Pip');
      expect(profile.timezone, 'Europe/Istanbul');
      expect(profile.hasHealthConsent, isFalse);
      expect(storedRow['timezone'], 'Europe/Istanbul');
      expect(timezoneUpdates, [
        {'timezone': 'Europe/Kiev'},
      ]);
    },
  );

  test(
    'fetchProfile uses the device timezone after a successful write',
    () async {
      final repository = SupabaseProfileRepository(
        client,
        deviceTimezone: () async => 'Asia/Kolkata',
      );

      final profile = await repository.fetchProfile(userId);

      expect(profile.timezone, 'Asia/Kolkata');
      expect(storedRow['timezone'], 'Asia/Kolkata');
      expect(timezoneUpdates, [
        {'timezone': 'Asia/Kolkata'},
      ]);
    },
  );

  test(
    'fetchProfile skips a timezone write when it is already current',
    () async {
      final repository = SupabaseProfileRepository(
        client,
        deviceTimezone: () async => 'Europe/Istanbul',
      );

      final profile = await repository.fetchProfile(userId);

      expect(profile.timezone, 'Europe/Istanbul');
      expect(timezoneUpdates, isEmpty);
    },
  );
}
