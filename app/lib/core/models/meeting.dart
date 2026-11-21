class TranscriptSegment {
  const TranscriptSegment({
    required this.seq,
    required this.startSec,
    required this.endSec,
    required this.text,
  });

  final int seq;
  final double startSec;
  final double endSec;
  final String text;

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) {
    return TranscriptSegment(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      startSec: (json['start_sec'] as num?)?.toDouble() ?? 0.0,
      endSec: (json['end_sec'] as num?)?.toDouble() ?? 0.0,
      text: (json['text'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toDbMap(String meetingId) => {
        'meeting_id': meetingId,
        'seq': seq,
        'start_sec': startSec,
        'end_sec': endSec,
        'text': text,
      };
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.meetingId,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final int id;
  final String meetingId;
  final String role;
  final String content;
  final String createdAt;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      meetingId: (json['meeting_id'] as String?) ?? '',
      role: (json['role'] as String?) ?? 'assistant',
      content: (json['content'] as String?) ?? '',
      createdAt: (json['created_at'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'meeting_id': meetingId,
        'role': role,
        'content': content,
        'created_at': createdAt,
      };
}

class Meeting {
  const Meeting({
    required this.id,
    this.clientId,
    required this.title,
    required this.status,
    this.errorMessage,
    this.manualNotes = '',
    this.summary = '',
    this.transcript = '',
    this.language,
    this.durationSeconds,
    this.sttProvider = 'auto',
    this.sttUsed,
    this.hasAudio = false,
    required this.createdAt,
    required this.updatedAt,
    this.localAudioPath,
    this.uploadState = 'none',
    this.uploadTaskId,
    this.segments = const [],
  });

  final String id;
  final String? clientId;
  final String title;
  final String status;
  final String? errorMessage;
  final String manualNotes;
  final String summary;
  final String transcript;
  final String? language;
  final double? durationSeconds;
  final String sttProvider;
  final String? sttUsed;
  final bool hasAudio;
  final String createdAt;
  final String updatedAt;

  // Local device upload tracking
  final String? localAudioPath;
  final String uploadState; // none, recording, pending_upload, uploading, uploaded, failed
  final String? uploadTaskId;
  final List<TranscriptSegment> segments;

  bool get isProcessing =>
      status == 'queued' || status == 'transcribing' || status == 'summarizing';

  bool get needsUpload =>
      localAudioPath != null &&
      localAudioPath!.isNotEmpty &&
      (uploadState == 'pending_upload' || uploadState == 'failed');

  String get displayStatus {
    if (uploadState == 'recording') return 'recording';
    if (uploadState == 'uploading') return 'uploading';
    if (uploadState == 'pending_upload') return 'pending upload';
    if (uploadState == 'failed' && status == 'created') return 'upload failed';
    return status;
  }

  Meeting copyWith({
    String? id,
    String? clientId,
    String? title,
    String? status,
    String? errorMessage,
    bool clearError = false,
    String? manualNotes,
    String? summary,
    String? transcript,
    String? language,
    double? durationSeconds,
    String? sttProvider,
    String? sttUsed,
    bool? hasAudio,
    String? createdAt,
    String? updatedAt,
    String? localAudioPath,
    bool clearLocalAudioPath = false,
    String? uploadState,
    String? uploadTaskId,
    bool clearUploadTaskId = false,
    List<TranscriptSegment>? segments,
  }) {
    return Meeting(
      id: id ?? this.id,
      clientId: clientId ?? this.clientId,
      title: title ?? this.title,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      manualNotes: manualNotes ?? this.manualNotes,
      summary: summary ?? this.summary,
      transcript: transcript ?? this.transcript,
      language: language ?? this.language,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      sttProvider: sttProvider ?? this.sttProvider,
      sttUsed: sttUsed ?? this.sttUsed,
      hasAudio: hasAudio ?? this.hasAudio,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      localAudioPath:
          clearLocalAudioPath ? null : (localAudioPath ?? this.localAudioPath),
      uploadState: uploadState ?? this.uploadState,
      uploadTaskId:
          clearUploadTaskId ? null : (uploadTaskId ?? this.uploadTaskId),
      segments: segments ?? this.segments,
    );
  }

  factory Meeting.fromJson(Map<String, dynamic> json) {
    final segList = (json['segments'] as List<dynamic>?)
            ?.map((e) => TranscriptSegment.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <TranscriptSegment>[];
    return Meeting(
      id: json['id'] as String,
      clientId: json['client_id'] as String?,
      title: (json['title'] as String?) ?? 'Untitled Meeting',
      status: (json['status'] as String?) ?? 'created',
      errorMessage: json['error_message'] as String?,
      manualNotes: (json['manual_notes'] as String?) ?? '',
      summary: (json['summary'] as String?) ?? '',
      transcript: (json['transcript'] as String?) ?? '',
      language: json['language'] as String?,
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
      sttProvider: (json['stt_provider'] as String?) ?? 'auto',
      sttUsed: json['stt_used'] as String?,
      hasAudio: (json['has_audio'] as bool?) ?? false,
      createdAt: (json['created_at'] as String?) ?? '',
      updatedAt: (json['updated_at'] as String?) ?? '',
      segments: segList,
    );
  }

  factory Meeting.fromDbMap(
    Map<String, dynamic> map, {
    List<TranscriptSegment> segments = const [],
  }) {
    return Meeting(
      id: map['id'] as String,
      clientId: map['client_id'] as String?,
      title: (map['title'] as String?) ?? 'Untitled Meeting',
      status: (map['status'] as String?) ?? 'created',
      errorMessage: map['error_message'] as String?,
      manualNotes: (map['manual_notes'] as String?) ?? '',
      summary: (map['summary'] as String?) ?? '',
      transcript: (map['transcript'] as String?) ?? '',
      language: map['language'] as String?,
      durationSeconds: (map['duration_seconds'] as num?)?.toDouble(),
      sttProvider: (map['stt_provider'] as String?) ?? 'auto',
      sttUsed: map['stt_used'] as String?,
      hasAudio: (map['has_audio'] as int? ?? 0) == 1,
      createdAt: (map['created_at'] as String?) ?? '',
      updatedAt: (map['updated_at'] as String?) ?? '',
      localAudioPath: map['local_audio_path'] as String?,
      uploadState: (map['upload_state'] as String?) ?? 'none',
      uploadTaskId: map['upload_task_id'] as String?,
      segments: segments,
    );
  }

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'client_id': clientId,
        'title': title,
        'status': status,
        'error_message': errorMessage,
        'manual_notes': manualNotes,
        'summary': summary,
        'transcript': transcript,
        'language': language,
        'duration_seconds': durationSeconds,
        'stt_provider': sttProvider,
        'stt_used': sttUsed,
        'has_audio': hasAudio ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'local_audio_path': localAudioPath,
        'upload_state': uploadState,
        'upload_task_id': uploadTaskId,
      };
}
