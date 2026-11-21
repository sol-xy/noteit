import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/api/noteit_api_client.dart';
import '../core/config/app_settings.dart';
import '../core/models/meeting.dart';
import '../core/storage/local_db.dart';

class UploadService {
  UploadService({
    required this._settings,
    required this._api,
    required this._db,
  });

  final AppSettings _settings;
  final NoteItApiClient _api;
  final LocalDb _db;

  final _updatedController = StreamController<String>.broadcast();
  StreamSubscription<TaskUpdate>? _updatesSub;
  bool _initialized = false;

  Stream<String> get onMeetingUpdated => _updatedController.stream;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (kIsWeb || !Platform.isIOS) return;

    await FileDownloader().start(autoCleanDatabase: true);
    _updatesSub = FileDownloader().updates.listen((update) {
      if (update is TaskStatusUpdate) {
        unawaited(_handleTaskStatusUpdate(update));
      }
    });
  }

  Future<void> _handleTaskStatusUpdate(TaskStatusUpdate update) async {
    final meeting = await _db.getMeetingByUploadTaskId(update.task.taskId);
    if (meeting == null) return;

    if (update.status == TaskStatus.complete) {
      final body = update.responseBody;
      if (body != null && body.trim().isNotEmpty) {
        try {
          final parsed = jsonDecode(body) as Map<String, dynamic>;
          final serverMeeting = Meeting.fromJson(parsed);
          await _db.upsertFromServer(serverMeeting);
        } catch (_) {
          // Ignore malformed optional body; mark uploaded below.
        }
      }
      await _cleanupLocalAudio(meeting.localAudioPath);
      await _db.updateUploadTracking(
        meeting.id,
        uploadState: 'uploaded',
        clearUploadTaskId: true,
        clearLocalAudioPath: true,
        status: 'queued',
        clearError: true,
      );
      _updatedController.add(meeting.id);
    } else if (update.status == TaskStatus.failed ||
        update.status == TaskStatus.canceled ||
        update.status == TaskStatus.notFound) {
      await _db.updateUploadTracking(
        meeting.id,
        uploadState: 'failed',
        clearUploadTaskId: true,
        errorMessage:
            update.exception?.description ?? 'Background upload failed.',
      );
      _updatedController.add(meeting.id);
    }
  }

  /// Creates the remote meeting record and starts background upload of the `.m4a`.
  Future<Meeting> uploadMeeting(Meeting localMeeting) async {
    if (!_settings.isConfigured) {
      await _db.updateUploadTracking(
        localMeeting.id,
        uploadState: 'pending_upload',
        errorMessage: 'Configure Server URL & Access Token in Settings to upload.',
      );
      _updatedController.add(localMeeting.id);
      return localMeeting;
    }

    final audioPath = localMeeting.localAudioPath;
    if (audioPath == null || audioPath.isEmpty || !await File(audioPath).exists()) {
      await _db.updateUploadTracking(
        localMeeting.id,
        uploadState: 'failed',
        errorMessage: 'Local audio file could not be found.',
      );
      _updatedController.add(localMeeting.id);
      return localMeeting;
    }

    final serverMeeting = await _api.createMeeting(
      clientId: localMeeting.clientId ?? localMeeting.id,
      title: localMeeting.title,
      manualNotes: localMeeting.manualNotes,
      sttProvider: localMeeting.sttProvider,
    );

    await _db.reconcileServerId(localMeeting.id, serverMeeting);
    final meetingId = serverMeeting.id;

    if (!kIsWeb && Platform.isIOS) {
      final task = UploadTask(
        url: _api.buildAudioUploadUri(meetingId).toString(),
        filename: p.basename(audioPath),
        baseDirectory: BaseDirectory.applicationDocuments,
        directory: 'recordings',
        fileField: 'file',
        fields: {'stt_provider': localMeeting.sttProvider},
        headers: _api.buildAuthHeaders(),
        updates: Updates.statusAndProgress,
      );

      await _db.updateUploadTracking(
        meetingId,
        uploadState: 'uploading',
        uploadTaskId: task.taskId,
        clearError: true,
      );
      _updatedController.add(meetingId);

      final enqueued = await FileDownloader().enqueue(task);
      if (!enqueued) {
        await _db.updateUploadTracking(
          meetingId,
          uploadState: 'failed',
          clearUploadTaskId: true,
          errorMessage: 'Failed to enqueue iOS background upload.',
        );
        _updatedController.add(meetingId);
      }
      return (await _db.getMeeting(meetingId)) ?? serverMeeting;
    }

    // Desktop / non-iOS fallback using standard multipart upload.
    await _db.updateUploadTracking(
      meetingId,
      uploadState: 'uploading',
      clearError: true,
    );
    _updatedController.add(meetingId);

    try {
      final uploaded = await _api.uploadAudioMultipart(
        meetingId: meetingId,
        filePath: audioPath,
        sttProvider: localMeeting.sttProvider,
      );
      await _cleanupLocalAudio(audioPath);
      await _db.upsertFromServer(uploaded);
      await _db.updateUploadTracking(
        meetingId,
        uploadState: 'uploaded',
        clearLocalAudioPath: true,
        clearUploadTaskId: true,
        clearError: true,
      );
      _updatedController.add(meetingId);
      return (await _db.getMeeting(meetingId)) ?? uploaded;
    } catch (err) {
      await _db.updateUploadTracking(
        meetingId,
        uploadState: 'failed',
        errorMessage: err.toString(),
      );
      _updatedController.add(meetingId);
      rethrow;
    }
  }

  Future<void> retryPendingUploads() async {
    if (!_settings.isConfigured) return;
    final pending = await _db.listPendingUploads();
    for (final m in pending) {
      if (m.uploadState == 'uploading' && m.uploadTaskId != null) {
        continue;
      }
      try {
        await uploadMeeting(m);
      } catch (_) {
        // Keep queued for next retry cycle.
      }
    }
  }

  Future<void> _cleanupLocalAudio(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // Ignore cleanup errors.
    }
  }

  Future<void> dispose() async {
    await _updatesSub?.cancel();
    await _updatedController.close();
  }
}
