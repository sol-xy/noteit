import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config/app_settings.dart';
import '../models/meeting.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

class NoteItApiClient {
  NoteItApiClient({
    required this._settings,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final AppSettings _settings;
  final http.Client _http;

  Uri _uri(String path, [Map<String, String>? queryParams]) {
    if (!_settings.isConfigured) {
      throw ApiException('Server URL and access token are not configured.');
    }
    final base = Uri.parse(_settings.serverUrl);
    final combinedPath = '${base.path}$path';
    return base.replace(
      path: combinedPath,
      queryParameters:
          queryParams == null || queryParams.isEmpty ? null : queryParams,
    );
  }

  Map<String, String> _headers({bool jsonBody = true}) {
    final map = <String, String>{
      'Authorization': 'Bearer ${_settings.authToken}',
    };
    if (jsonBody) {
      map['Content-Type'] = 'application/json';
    }
    return map;
  }

  Future<Map<String, dynamic>> testConnection({
    required String serverUrl,
    required String authToken,
  }) async {
    final normalized = AppSettings.normalizeServerUrl(serverUrl);
    final base = Uri.parse(normalized);
    final uri = base.replace(path: '${base.path}/api/auth/me');
    final resp = await _http
        .get(uri, headers: {'Authorization': 'Bearer ${authToken.trim()}'})
        .timeout(const Duration(seconds: 15));
    return _decodeJsonMap(resp);
  }

  Future<List<Meeting>> listMeetings({String? query}) async {
    final params = <String, String>{};
    if (query != null && query.trim().isNotEmpty) {
      params['q'] = query.trim();
    }
    final resp = await _http
        .get(_uri('/api/meetings', params), headers: _headers(jsonBody: false))
        .timeout(const Duration(seconds: 20));
    final map = _decodeJsonMap(resp);
    final raw = (map['meetings'] as List<dynamic>?) ?? const [];
    return raw.map((e) => Meeting.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Meeting> createMeeting({
    String? clientId,
    required String title,
    required String manualNotes,
    required String sttProvider,
  }) async {
    final resp = await _http
        .post(
          _uri('/api/meetings'),
          headers: _headers(),
          body: jsonEncode({
            'client_id': clientId,
            'title': title,
            'manual_notes': manualNotes,
            'stt_provider': sttProvider,
          }),
        )
        .timeout(const Duration(seconds: 20));
    return Meeting.fromJson(_decodeJsonMap(resp));
  }

  Future<Meeting> getMeeting(String id) async {
    final resp = await _http
        .get(_uri('/api/meetings/$id'), headers: _headers(jsonBody: false))
        .timeout(const Duration(seconds: 20));
    return Meeting.fromJson(_decodeJsonMap(resp));
  }

  Future<Meeting> updateMeeting(
    String id, {
    String? title,
    String? manualNotes,
  }) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (manualNotes != null) body['manual_notes'] = manualNotes;

    final resp = await _http
        .patch(
          _uri('/api/meetings/$id'),
          headers: _headers(),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    return Meeting.fromJson(_decodeJsonMap(resp));
  }

  Future<void> deleteMeeting(String id) async {
    final resp = await _http
        .delete(_uri('/api/meetings/$id'), headers: _headers(jsonBody: false))
        .timeout(const Duration(seconds: 20));
    _ensureSuccess(resp);
  }

  Future<Meeting> uploadAudioMultipart({
    required String meetingId,
    required String filePath,
    required String sttProvider,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      _uri('/api/meetings/$meetingId/audio'),
    );
    request.headers.addAll(_headers(jsonBody: false));
    request.fields['stt_provider'] = sttProvider;
    request.files.add(await http.MultipartFile.fromPath('file', filePath));

    final streamed = await _http.send(request).timeout(const Duration(minutes: 5));
    final resp = await http.Response.fromStream(streamed);
    return Meeting.fromJson(_decodeJsonMap(resp));
  }

  Future<Meeting> retryMeeting(String id) async {
    final resp = await _http
        .post(_uri('/api/meetings/$id/retry'), headers: _headers(jsonBody: false))
        .timeout(const Duration(seconds: 20));
    return Meeting.fromJson(_decodeJsonMap(resp));
  }

  Future<Meeting> resummarizeMeeting(
    String id, {
    String? manualNotes,
    String? customInstructions,
  }) async {
    final resp = await _http
        .post(
          _uri('/api/meetings/$id/resummarize'),
          headers: _headers(),
          body: jsonEncode({
            'manual_notes': manualNotes,
            'custom_instructions': customInstructions,
          }),
        )
        .timeout(const Duration(seconds: 20));
    return Meeting.fromJson(_decodeJsonMap(resp));
  }

  Future<String> exportMarkdown(String id) async {
    final resp = await _http
        .get(_uri('/api/meetings/$id/export.md'), headers: _headers(jsonBody: false))
        .timeout(const Duration(seconds: 20));
    _ensureSuccess(resp);
    return utf8.decode(resp.bodyBytes);
  }

  Future<List<ChatMessage>> listChat(String meetingId) async {
    final resp = await _http
        .get(_uri('/api/meetings/$meetingId/chat'), headers: _headers(jsonBody: false))
        .timeout(const Duration(seconds: 20));
    _ensureSuccess(resp);
    final raw = jsonDecode(utf8.decode(resp.bodyBytes)) as List<dynamic>;
    return raw
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ChatMessage> sendChat(String meetingId, String message) async {
    final resp = await _http
        .post(
          _uri('/api/meetings/$meetingId/chat'),
          headers: _headers(),
          body: jsonEncode({'message': message}),
        )
        .timeout(const Duration(seconds: 60));
    final map = _decodeJsonMap(resp);
    return ChatMessage.fromJson(
      map['assistant_message'] as Map<String, dynamic>,
    );
  }

  Future<void> clearChat(String meetingId) async {
    final resp = await _http
        .delete(
          _uri('/api/meetings/$meetingId/chat'),
          headers: _headers(jsonBody: false),
        )
        .timeout(const Duration(seconds: 20));
    _ensureSuccess(resp);
  }

  Uri buildAudioUploadUri(String meetingId) => _uri('/api/meetings/$meetingId/audio');

  Map<String, String> buildAuthHeaders() => _headers(jsonBody: false);

  void _ensureSuccess(http.Response resp) {
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return;
    }
    String detail = 'Request failed (${resp.statusCode})';
    try {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is Map<String, dynamic> && decoded['detail'] != null) {
        detail = decoded['detail'].toString();
      }
    } catch (_) {
      // ignore non-JSON error body
    }
    throw ApiException(detail, statusCode: resp.statusCode);
  }

  Map<String, dynamic> _decodeJsonMap(http.Response resp) {
    _ensureSuccess(resp);
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }
}
