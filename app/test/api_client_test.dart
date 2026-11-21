import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noteit/core/api/noteit_api_client.dart';
import 'package:noteit/core/config/app_settings.dart';

void main() {
  test('attaches Bearer token and parses meetings & chat responses', () async {
    final settings = AppSettings(store: InMemoryKeyValueStore());
    await settings.save(
      serverUrl: 'https://noteit.example.com/',
      authToken: 'secret-token-123456789012345',
      sttProvider: 'auto',
    );

    final mockClient = MockClient((request) async {
      expect(
        request.headers['Authorization'],
        'Bearer secret-token-123456789012345',
      );

      if (request.url.path == '/api/meetings' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'meetings': [
              {
                'id': 'm-1',
                'client_id': 'c-1',
                'title': 'Sprint Sync',
                'status': 'completed',
                'manual_notes': 'check velocity',
                'summary': '## Overview\n\nAll good.',
                'stt_provider': 'auto',
                'has_audio': false,
                'created_at': '2026-11-21T10:00:00Z',
                'updated_at': '2026-11-21T10:05:00Z',
              }
            ],
            'total': 1,
          }),
          200,
        );
      }

      if (request.url.path == '/api/meetings/m-1/chat' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'user_message': {
              'id': 1,
              'meeting_id': 'm-1',
              'role': 'user',
              'content': 'Summary?',
              'created_at': '2026-11-21T10:06:00Z',
            },
            'assistant_message': {
              'id': 2,
              'meeting_id': 'm-1',
              'role': 'assistant',
              'content': 'All good.',
              'created_at': '2026-11-21T10:06:01Z',
            },
          }),
          200,
        );
      }

      return http.Response(jsonEncode({'detail': 'Not found'}), 404);
    });

    final api = NoteItApiClient(settings: settings, httpClient: mockClient);
    final meetings = await api.listMeetings();
    expect(meetings.length, 1);
    expect(meetings.first.title, 'Sprint Sync');

    final reply = await api.sendChat('m-1', 'Summary?');
    expect(reply.role, 'assistant');
    expect(reply.content, 'All good.');
  });

  test('throws ApiException with isUnauthorized on 401', () async {
    final settings = AppSettings(store: InMemoryKeyValueStore());
    await settings.save(
      serverUrl: 'https://noteit.example.com',
      authToken: 'bad-token',
      sttProvider: 'auto',
    );

    final mockClient = MockClient(
      (_) async => http.Response(
        jsonEncode({'detail': 'Authentication required'}),
        401,
      ),
    );

    final api = NoteItApiClient(settings: settings, httpClient: mockClient);
    expect(
      () => api.listMeetings(),
      throwsA(
        isA<ApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', true),
      ),
    );
  });
}
