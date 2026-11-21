import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/meeting.dart';

class LocalDb {
  LocalDb({this._factory, this._dbPathOverride});

  final DatabaseFactory? _factory;
  final String? _dbPathOverride;
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final factory = _factory ?? databaseFactory;
    final path = _dbPathOverride ?? p.join(await getDatabasesPath(), 'noteit_cache.db');
    _db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE meetings (
              id TEXT PRIMARY KEY,
              client_id TEXT,
              title TEXT NOT NULL,
              status TEXT NOT NULL,
              error_message TEXT,
              manual_notes TEXT NOT NULL DEFAULT '',
              summary TEXT NOT NULL DEFAULT '',
              transcript TEXT NOT NULL DEFAULT '',
              language TEXT,
              duration_seconds REAL,
              stt_provider TEXT NOT NULL DEFAULT 'auto',
              stt_used TEXT,
              has_audio INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              local_audio_path TEXT,
              upload_state TEXT NOT NULL DEFAULT 'none',
              upload_task_id TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE transcript_segments (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              seq INTEGER NOT NULL,
              start_sec REAL NOT NULL,
              end_sec REAL NOT NULL,
              text TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE chat_messages (
              id INTEGER PRIMARY KEY,
              meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
              role TEXT NOT NULL,
              content TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    return _db!;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('chat_messages');
      await txn.delete('transcript_segments');
      await txn.delete('meetings');
    });
  }

  Future<void> saveLocalMeeting(Meeting meeting) async {
    final db = await database;
    await db.insert(
      'meetings',
      meeting.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertFromServer(
    Meeting serverMeeting, {
    bool includeSegments = false,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'meetings',
        where: 'id = ? OR (client_id IS NOT NULL AND client_id = ?)',
        whereArgs: [serverMeeting.id, serverMeeting.clientId ?? ''],
      );

      String? localAudioPath;
      String uploadState = 'uploaded';
      String? uploadTaskId;
      String existingTranscript = '';

      if (existingRows.isNotEmpty) {
        final row = existingRows.first;
        localAudioPath = row['local_audio_path'] as String?;
        final existingState = (row['upload_state'] as String?) ?? 'none';
        if (existingState == 'pending_upload' || existingState == 'uploading') {
          uploadState = existingState;
        }
        uploadTaskId = row['upload_task_id'] as String?;
        existingTranscript = (row['transcript'] as String?) ?? '';

        final oldId = row['id'] as String;
        if (oldId != serverMeeting.id) {
          await txn.delete('meetings', where: 'id = ?', whereArgs: [oldId]);
        }
      }

      final merged = serverMeeting.copyWith(
        transcript: serverMeeting.transcript.isNotEmpty
            ? serverMeeting.transcript
            : existingTranscript,
        localAudioPath: localAudioPath,
        uploadState: uploadState,
        uploadTaskId: uploadTaskId,
      );

      await txn.insert(
        'meetings',
        merged.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      if (includeSegments) {
        await txn.delete(
          'transcript_segments',
          where: 'meeting_id = ?',
          whereArgs: [serverMeeting.id],
        );
        for (final seg in serverMeeting.segments) {
          await txn.insert(
            'transcript_segments',
            seg.toDbMap(serverMeeting.id),
          );
        }
      }
    });
  }

  Future<void> upsertMeetingsFromServer(List<Meeting> meetings) async {
    for (final m in meetings) {
      await upsertFromServer(m);
    }
  }

  Future<void> reconcileServerId(String localId, Meeting serverMeeting) async {
    final db = await database;
    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'meetings',
        where: 'id = ?',
        whereArgs: [localId],
      );
      final existing = existingRows.isNotEmpty ? existingRows.first : null;
      final merged = serverMeeting.copyWith(
        localAudioPath: existing?['local_audio_path'] as String?,
        uploadState: (existing?['upload_state'] as String?) ?? 'pending_upload',
        uploadTaskId: existing?['upload_task_id'] as String?,
      );

      if (localId != serverMeeting.id) {
        await txn.delete('meetings', where: 'id = ?', whereArgs: [localId]);
      }
      await txn.insert(
        'meetings',
        merged.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<Meeting>> listMeetings({String? query}) async {
    final db = await database;
    final trimmed = query?.trim() ?? '';
    final List<Map<String, dynamic>> rows;
    if (trimmed.isEmpty) {
      rows = await db.query('meetings', orderBy: 'created_at DESC');
    } else {
      final like = '%$trimmed%';
      rows = await db.query(
        'meetings',
        where:
            'title LIKE ? OR manual_notes LIKE ? OR summary LIKE ? OR transcript LIKE ?',
        whereArgs: [like, like, like, like],
        orderBy: 'created_at DESC',
      );
    }
    return rows.map((r) => Meeting.fromDbMap(r)).toList();
  }

  Future<List<Meeting>> listPendingUploads() async {
    final db = await database;
    final rows = await db.query(
      'meetings',
      where:
          "local_audio_path IS NOT NULL AND local_audio_path != '' AND upload_state IN ('pending_upload', 'failed', 'uploading')",
      orderBy: 'created_at ASC',
    );
    return rows.map((r) => Meeting.fromDbMap(r)).toList();
  }

  Future<Meeting?> getMeeting(String id) async {
    final db = await database;
    final rows = await db.query('meetings', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;

    final segRows = await db.query(
      'transcript_segments',
      where: 'meeting_id = ?',
      whereArgs: [id],
      orderBy: 'seq ASC',
    );
    final segments = segRows
        .map(
          (r) => TranscriptSegment(
            seq: (r['seq'] as num).toInt(),
            startSec: (r['start_sec'] as num).toDouble(),
            endSec: (r['end_sec'] as num).toDouble(),
            text: r['text'] as String,
          ),
        )
        .toList();
    return Meeting.fromDbMap(rows.first, segments: segments);
  }

  Future<Meeting?> getMeetingByUploadTaskId(String taskId) async {
    final db = await database;
    final rows = await db.query(
      'meetings',
      where: 'upload_task_id = ?',
      whereArgs: [taskId],
    );
    if (rows.isEmpty) return null;
    return Meeting.fromDbMap(rows.first);
  }

  Future<void> updateUploadTracking(
    String meetingId, {
    String? uploadState,
    String? uploadTaskId,
    bool clearUploadTaskId = false,
    String? localAudioPath,
    bool clearLocalAudioPath = false,
    String? status,
    String? errorMessage,
    bool clearError = false,
  }) async {
    final db = await database;
    final values = <String, Object?>{
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (uploadState != null) values['upload_state'] = uploadState;
    if (clearUploadTaskId) {
      values['upload_task_id'] = null;
    } else if (uploadTaskId != null) {
      values['upload_task_id'] = uploadTaskId;
    }
    if (clearLocalAudioPath) {
      values['local_audio_path'] = null;
    } else if (localAudioPath != null) {
      values['local_audio_path'] = localAudioPath;
    }
    if (status != null) values['status'] = status;
    if (clearError) {
      values['error_message'] = null;
    } else if (errorMessage != null) {
      values['error_message'] = errorMessage;
    }
    await db.update(
      'meetings',
      values,
      where: 'id = ?',
      whereArgs: [meetingId],
    );
  }

  Future<void> deleteMeeting(String id) async {
    final db = await database;
    await db.delete('meetings', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<ChatMessage>> listChatMessages(String meetingId) async {
    final db = await database;
    final rows = await db.query(
      'chat_messages',
      where: 'meeting_id = ?',
      whereArgs: [meetingId],
      orderBy: 'id ASC',
    );
    return rows.map((r) => ChatMessage.fromJson(r)).toList();
  }

  Future<void> replaceChatMessages(
    String meetingId,
    List<ChatMessage> messages,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'chat_messages',
        where: 'meeting_id = ?',
        whereArgs: [meetingId],
      );
      for (final msg in messages) {
        await txn.insert(
          'chat_messages',
          msg.toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }
}
