import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wearable_companion/data/auth_repository.dart';
import 'package:wearable_companion/data/health_repository.dart';

void main() {
  late SupabaseClient client;
  late List<String> requests;
  late int workerStatus;
  late Map<String, dynamic> workerBody;

  setUp(() async {
    requests = [];
    workerStatus = 200;
    workerBody = {'processed': 3.0, 'failed': 1, 'remaining': 14};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      expect(request.headers.value('authorization'), 'Bearer synthetic-user-jwt');
      final body = await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/rest/v1/rpc/request_sync') {
        expect(jsonDecode(body), {'days_back': 1});
        request.response.write('18');
      } else {
        expect(request.uri.path, '/functions/v1/sync-worker');
        request.response.statusCode = workerStatus;
        request.response.write(jsonEncode(workerBody));
      }
      await request.response.close();
    });
    client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'synthetic-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': 'synthetic-user-jwt',
        'token_type': 'bearer',
        'user': {
          'id': '00000000-0000-4000-8000-000000000001',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
          'aud': 'authenticated',
          'created_at': '2026-11-19T00:00:00Z',
        },
      }),
    );
  });

  test('manual sync queues then directly invokes the worker with the user JWT', () async {
    final result = await SupabaseHealthRepository(client).requestSync();

    expect(requests, [
      'POST /rest/v1/rpc/request_sync',
      'POST /functions/v1/sync-worker',
    ]);
    expect(result.processed, 3);
    expect(result.failed, 1);
    expect(result.remaining, 14);
  });

  test('worker 429 maps to a clear retry message', () async {
    workerStatus = 429;
    workerBody = {'error': 'sync_rate_limited'};

    await expectLater(
      SupabaseHealthRepository(client).requestSync(),
      throwsA(
        isA<UserFacingException>().having(
          (error) => error.message,
          'message',
          'Sync already in progress. Try again in a minute.',
        ),
      ),
    );
    expect(requests, [
      'POST /rest/v1/rpc/request_sync',
      'POST /functions/v1/sync-worker',
    ]);
  });

  for (final status in [401, 500]) {
    test('worker $status keeps its existing error behavior', () async {
      workerStatus = status;
      workerBody = {'error': 'test_error'};

      await expectLater(
        SupabaseHealthRepository(client).requestSync(),
        throwsA(
          isA<FunctionException>().having((error) => error.status, 'status', status),
        ),
      );
    });
  }
}
