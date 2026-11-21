import 'package:flutter_test/flutter_test.dart';
import 'package:noteit/core/models/meeting.dart';
import 'package:noteit/core/utils/markdown_formatter.dart';

void main() {
  test('formats timestamps and safe file names', () {
    expect(MarkdownFormatter.formatTimestamp(0), '00:00');
    expect(MarkdownFormatter.formatTimestamp(65), '01:05');
    expect(MarkdownFormatter.formatTimestamp(3665), '01:01:05');
    expect(
      MarkdownFormatter.safeFileName('Q4 Roadmap / Sync!', '12345678'),
      'Q4-Roadmap-Sync.md',
    );
  });

  test('renders Obsidian-ready Markdown with frontmatter and segments', () {
    const meeting = Meeting(
      id: 'm1',
      title: 'Architecture Review',
      status: 'completed',
      manualNotes: '- Keep backend ARM64 friendly',
      summary: '## Overview\n\nApproved FastAPI + SQLite.',
      durationSeconds: 125,
      sttUsed: 'groq',
      createdAt: '2026-11-21T10:00:00Z',
      updatedAt: '2026-11-21T10:02:00Z',
      segments: [
        TranscriptSegment(
          seq: 0,
          startSec: 12,
          endSec: 18,
          text: 'Let us deploy with Docker.',
        ),
      ],
    );

    final md = MarkdownFormatter.renderMeeting(meeting);
    expect(md, contains('title: "Architecture Review"'));
    expect(md, contains('duration: "02:05"'));
    expect(md, contains('## Enhanced Summary'));
    expect(md, contains('## My Notes'));
    expect(md, contains('- **[00:12]** Let us deploy with Docker.'));
  });
}
