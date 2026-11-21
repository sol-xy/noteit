import '../models/meeting.dart';

class MarkdownFormatter {
  static String formatTimestamp(double seconds) {
    final total = seconds < 0 ? 0 : seconds.floor();
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final secs = total % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  static String safeFileName(String title, String meetingId) {
    final slug = title
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = slug.isEmpty
        ? 'meeting-${meetingId.substring(0, meetingId.length >= 8 ? 8 : meetingId.length)}'
        : (slug.length > 80 ? slug.substring(0, 80) : slug);
    return '$base.md';
  }

  static String _escapeYaml(String value) {
    final cleaned = value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', ' ');
    return '"$cleaned"';
  }

  static String renderMeeting(Meeting meeting) {
    final durationStr = meeting.durationSeconds != null
        ? formatTimestamp(meeting.durationSeconds!)
        : 'unknown';
    final provider = meeting.sttUsed ?? meeting.sttProvider;

    final buf = StringBuffer()
      ..writeln('---')
      ..writeln('title: ${_escapeYaml(meeting.title)}')
      ..writeln('date: ${_escapeYaml(meeting.createdAt)}')
      ..writeln('duration: ${_escapeYaml(durationStr)}')
      ..writeln('stt_provider: ${_escapeYaml(provider)}')
      ..writeln('---')
      ..writeln()
      ..writeln('# ${meeting.title}')
      ..writeln();

    if (meeting.summary.trim().isNotEmpty) {
      buf
        ..writeln('## Enhanced Summary')
        ..writeln()
        ..writeln(meeting.summary.trim())
        ..writeln();
    }

    if (meeting.manualNotes.trim().isNotEmpty) {
      buf
        ..writeln('## My Notes')
        ..writeln()
        ..writeln(meeting.manualNotes.trim())
        ..writeln();
    }

    buf
      ..writeln('## Transcript')
      ..writeln();

    if (meeting.segments.isNotEmpty) {
      for (final seg in meeting.segments) {
        final text = seg.text.trim();
        if (text.isNotEmpty) {
          buf.writeln('- **[${formatTimestamp(seg.startSec)}]** $text');
        }
      }
    } else if (meeting.transcript.trim().isNotEmpty) {
      buf.writeln(meeting.transcript.trim());
    } else {
      buf.writeln('_No transcript available._');
    }

    return buf.toString();
  }
}
