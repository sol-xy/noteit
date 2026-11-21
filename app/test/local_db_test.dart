import 'package:flutter_test/flutter_test.dart';
import 'package:noteit/core/models/meeting.dart';
import 'package:noteit/core/storage/local_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late LocalDb db;

  setUp(() async {
    db = LocalDb(
      factory: databaseFactoryFfi,
      dbPathOverride: inMemoryDatabasePath,
    );
    await db.database;
  });

  tearDown(() async {
    await db.close();
  });

  test('saves local meeting, reconciles server ID, and preserves search', () async {
    const localId = 'local-uuid-1';
    final draft = Meeting(
      id: localId,
      clientId: localId,
      title: 'Product Kickoff',
      status: 'created',
      manualNotes: '- Agree on Q4 roadmap',
      createdAt: '2026-11-21T10:00:00Z',
      updatedAt: '2026-11-21T10:00:00Z',
      localAudioPath: '/tmp/local-uuid-1.m4a',
      uploadState: 'pending_upload',
    );
    await db.saveLocalMeeting(draft);

    final pending = await db.listPendingUploads();
    expect(pending.length, 1);
    expect(pending.first.id, localId);

    const serverMeeting = Meeting(
      id: 'server-uuid-99',
      clientId: localId,
      title: 'Product Kickoff',
      status: 'queued',
      manualNotes: '- Agree on Q4 roadmap',
      createdAt: '2026-11-21T10:00:00Z',
      updatedAt: '2026-11-21T10:01:00Z',
    );
    await db.reconcileServerId(localId, serverMeeting);

    expect(await db.getMeeting(localId), isNull);
    final reconciled = await db.getMeeting('server-uuid-99');
    expect(reconciled, isNotNull);
    expect(reconciled!.localAudioPath, '/tmp/local-uuid-1.m4a');
    expect(reconciled.uploadState, 'pending_upload');

    final completedServer = serverMeeting.copyWith(
      status: 'completed',
      summary: '## Overview\n\nAligned on launch dates.',
      segments: const [
        TranscriptSegment(
          seq: 0,
          startSec: 0,
          endSec: 4,
          text: 'Let us finalize the Q4 roadmap today.',
        ),
      ],
    );
    await db.upsertFromServer(completedServer, includeSegments: true);
    await db.updateUploadTracking(
      'server-uuid-99',
      uploadState: 'uploaded',
      clearLocalAudioPath: true,
    );

    final matches = await db.listMeetings(query: 'roadmap');
    expect(matches.length, 1);
    expect(matches.first.id, 'server-uuid-99');

    final detail = await db.getMeeting('server-uuid-99');
    expect(detail!.segments.length, 1);
    expect(detail.localAudioPath, isNull);
  });

  test('stores and replaces per-meeting chat messages', () async {
    const meeting = Meeting(
      id: 'm1',
      title: 'Design Review',
      status: 'completed',
      createdAt: '2026-11-21T10:00:00Z',
      updatedAt: '2026-11-21T10:00:00Z',
    );
    await db.saveLocalMeeting(meeting);

    await db.replaceChatMessages('m1', const [
      ChatMessage(
        id: 1,
        meetingId: 'm1',
        role: 'user',
        content: 'What did we decide?',
        createdAt: '2026-11-21T10:05:00Z',
      ),
      ChatMessage(
        id: 2,
        meetingId: 'm1',
        role: 'assistant',
        content: 'Ship dark mode first.',
        createdAt: '2026-11-21T10:05:02Z',
      ),
    ]);

    final chat = await db.listChatMessages('m1');
    expect(chat.length, 2);
    expect(chat.last.content, 'Ship dark mode first.');
  });
}
