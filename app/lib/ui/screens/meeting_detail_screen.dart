import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/noteit_api_client.dart';
import '../../core/config/app_settings.dart';
import '../../core/models/meeting.dart';
import '../../core/storage/local_db.dart';
import '../../core/utils/markdown_formatter.dart';
import '../../services/upload_service.dart';

class MeetingDetailScreen extends StatefulWidget {
  const MeetingDetailScreen({
    super.key,
    required this.meetingId,
    required this.settings,
    required this.api,
    required this.db,
    required this.uploadService,
  });

  final String meetingId;
  final AppSettings settings;
  final NoteItApiClient api;
  final LocalDb db;
  final UploadService uploadService;

  @override
  State<MeetingDetailScreen> createState() => _MeetingDetailScreenState();
}

class _MeetingDetailScreenState extends State<MeetingDetailScreen> {
  final _notesCtrl = TextEditingController();
  final _transcriptFilterCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();

  Meeting? _meeting;
  List<ChatMessage> _chatMessages = [];
  bool _loading = true;
  bool _sendingChat = false;
  Timer? _pollTimer;
  StreamSubscription<String>? _uploadSub;
  String _transcriptFilter = '';

  @override
  void initState() {
    super.initState();
    _uploadSub = widget.uploadService.onMeetingUpdated.listen((updatedId) {
      if (updatedId == widget.meetingId) {
        unawaited(_loadData());
      }
    });
    unawaited(_loadData());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _uploadSub?.cancel();
    _notesCtrl.dispose();
    _transcriptFilterCtrl.dispose();
    _chatCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);

    final cached = await widget.db.getMeeting(widget.meetingId);
    final cachedChat = await widget.db.listChatMessages(widget.meetingId);
    if (cached != null && mounted) {
      setState(() {
        _meeting = cached;
        _chatMessages = cachedChat;
        if (_notesCtrl.text != cached.manualNotes && _notesCtrl.text.isEmpty) {
          _notesCtrl.text = cached.manualNotes;
        }
        _loading = false;
      });
    }

    if (widget.settings.isConfigured &&
        (cached == null || cached.uploadState != 'pending_upload')) {
      try {
        final remote = await widget.api.getMeeting(widget.meetingId);
        await widget.db.upsertFromServer(remote, includeSegments: true);
        final refreshed = await widget.db.getMeeting(widget.meetingId) ?? remote;

        final remoteChat = await widget.api.listChat(widget.meetingId);
        await widget.db.replaceChatMessages(widget.meetingId, remoteChat);

        if (mounted) {
          setState(() {
            _meeting = refreshed;
            _chatMessages = remoteChat;
            _notesCtrl.text = refreshed.manualNotes;
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    } else if (mounted) {
      setState(() => _loading = false);
    }

    _syncPolling();
  }

  void _syncPolling() {
    _pollTimer?.cancel();
    final m = _meeting;
    if (m != null && (m.isProcessing || m.uploadState == 'uploading')) {
      _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_loadData(silent: true));
      });
    }
  }

  Future<void> _editTitle() async {
    final m = _meeting;
    if (m == null) return;
    final ctrl = TextEditingController(text: m.title);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Meeting'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (next == null || next.isEmpty || next == m.title) return;

    try {
      final updated = await widget.api.updateMeeting(m.id, title: next);
      await widget.db.upsertFromServer(updated);
      await _loadData(silent: true);
    } catch (err) {
      _showSnack(err.toString());
    }
  }

  Future<void> _saveNotes({bool resummarize = false}) async {
    final m = _meeting;
    if (m == null) return;
    try {
      if (resummarize) {
        final updated = await widget.api.resummarizeMeeting(
          m.id,
          manualNotes: _notesCtrl.text,
        );
        await widget.db.upsertFromServer(updated);
        _showSnack('Re-summarizing...');
      } else {
        final updated = await widget.api.updateMeeting(
          m.id,
          manualNotes: _notesCtrl.text,
        );
        await widget.db.upsertFromServer(updated);
        _showSnack('Notes saved');
      }
      await _loadData(silent: true);
    } catch (err) {
      _showSnack(err.toString());
    }
  }

  Future<void> _openResummarizeDialog() async {
    final m = _meeting;
    if (m == null) return;
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Re-summarize Meeting'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Custom instructions (optional)',
            hintText: 'e.g., Focus on technical decisions and action items',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Generate'),
          ),
        ],
      ),
    );
    final instructions = ctrl.text.trim();
    ctrl.dispose();
    if (confirmed != true) return;

    try {
      final updated = await widget.api.resummarizeMeeting(
        m.id,
        customInstructions: instructions.isEmpty ? null : instructions,
      );
      await widget.db.upsertFromServer(updated);
      _showSnack('Re-summarizing...');
      await _loadData(silent: true);
    } catch (err) {
      _showSnack(err.toString());
    }
  }

  Future<void> _retry() async {
    final m = _meeting;
    if (m == null) return;
    try {
      if (m.needsUpload) {
        await widget.uploadService.uploadMeeting(m);
        _showSnack('Upload started');
      } else {
        final updated = await widget.api.retryMeeting(m.id);
        await widget.db.upsertFromServer(updated);
        _showSnack('Retry queued');
      }
      await _loadData(silent: true);
    } catch (err) {
      _showSnack(err.toString());
    }
  }

  Future<String> _resolveMarkdown() async {
    final m = _meeting!;
    if (widget.settings.isConfigured && !m.needsUpload) {
      try {
        return await widget.api.exportMarkdown(m.id);
      } catch (_) {
        // Fallback to local render when offline.
      }
    }
    return MarkdownFormatter.renderMeeting(m);
  }

  Future<void> _copyMarkdown() async {
    if (_meeting == null) return;
    final md = await _resolveMarkdown();
    await Clipboard.setData(ClipboardData(text: md));
    _showSnack('Markdown copied to clipboard');
  }

  Future<void> _shareMarkdown(BuildContext buttonContext) async {
    final m = _meeting;
    if (m == null) return;
    final md = await _resolveMarkdown();
    final tempDir = await getTemporaryDirectory();
    final filename = MarkdownFormatter.safeFileName(m.title, m.id);
    final file = File(p.join(tempDir.path, filename));
    await file.writeAsString(md);

    Rect? origin;
    if (buttonContext.mounted) {
      final box = buttonContext.findRenderObject() as RenderBox?;
      if (box != null) {
        origin = box.localToGlobal(Offset.zero) & box.size;
      }
    }

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'text/markdown')],
        subject: m.title,
        sharePositionOrigin: origin,
      ),
    );
  }

  Future<void> _deleteMeeting() async {
    final m = _meeting;
    if (m == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Meeting?'),
        content: const Text('This removes the meeting permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      if (widget.settings.isConfigured && m.uploadState != 'pending_upload') {
        await widget.api.deleteMeeting(m.id);
      }
    } catch (_) {
      // Allow deleting local copy even if unreachable.
    }
    if (m.localAudioPath != null) {
      final f = File(m.localAudioPath!);
      if (await f.exists()) await f.delete();
    }
    await widget.db.deleteMeeting(m.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _sendChat() async {
    final m = _meeting;
    final msg = _chatCtrl.text.trim();
    if (m == null || msg.isEmpty || _sendingChat) return;

    _chatCtrl.clear();
    setState(() => _sendingChat = true);
    try {
      await widget.api.sendChat(m.id, msg);
      final updatedChat = await widget.api.listChat(m.id);
      await widget.db.replaceChatMessages(m.id, updatedChat);
      if (mounted) setState(() => _chatMessages = updatedChat);
    } catch (err) {
      _showSnack(err.toString());
    } finally {
      if (mounted) setState(() => _sendingChat = false);
    }
  }

  Future<void> _clearChat() async {
    final m = _meeting;
    if (m == null) return;
    try {
      await widget.api.clearChat(m.id);
      await widget.db.replaceChatMessages(m.id, const []);
      if (mounted) setState(() => _chatMessages = []);
    } catch (err) {
      _showSnack(err.toString());
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final m = _meeting;
    if (_loading && m == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (m == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Meeting not found')),
      );
    }

    final colors = Theme.of(context).colorScheme;
    final filteredSegments = m.segments.where((s) {
      if (_transcriptFilter.isEmpty) return true;
      return s.text.toLowerCase().contains(_transcriptFilter.toLowerCase());
    }).toList();

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: _editTitle,
            child: Text(m.title, overflow: TextOverflow.ellipsis),
          ),
          actions: [
            Builder(
              builder: (btnCtx) => IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: 'Share Markdown',
                onPressed: () => _shareMarkdown(btnCtx),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy_all_outlined),
              tooltip: 'Copy Markdown',
              onPressed: _copyMarkdown,
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'rename') unawaited(_editTitle());
                if (value == 'delete') unawaited(_deleteMeeting());
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Summary'),
              Tab(text: 'Notes'),
              Tab(text: 'Transcript'),
              Tab(text: 'Ask AI'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (m.isProcessing ||
                m.uploadState == 'uploading' ||
                m.needsUpload ||
                m.status == 'failed')
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: m.status == 'failed' || m.uploadState == 'failed'
                    ? colors.error.withValues(alpha: 0.12)
                    : colors.primary.withValues(alpha: 0.10),
                child: Row(
                  children: [
                    if (m.isProcessing || m.uploadState == 'uploading')
                      const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        m.errorMessage?.isNotEmpty == true
                            ? '${m.displayStatus}: ${m.errorMessage}'
                            : 'Status: ${m.displayStatus}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (m.status == 'failed' || m.needsUpload)
                      TextButton(
                        onPressed: _retry,
                        child: const Text('Retry'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  // 1. Summary Tab
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            m.durationSeconds != null
                                ? 'Duration ${MarkdownFormatter.formatTimestamp(m.durationSeconds!)}'
                                : '',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          OutlinedButton.icon(
                            onPressed: m.isProcessing
                                ? null
                                : _openResummarizeDialog,
                            icon: const Icon(Icons.auto_awesome, size: 18),
                            label: const Text('Re-summarize'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (m.summary.trim().isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Text(
                            'Summary will appear here once transcription and AI synthesis finish.',
                          ),
                        )
                      else
                        MarkdownBody(
                          data: m.summary,
                          selectable: true,
                        ),
                    ],
                  ),

                  // 2. My Notes Tab
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _saveNotes(resummarize: false),
                                child: const Text('Save Notes'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                onPressed: m.isProcessing
                                    ? null
                                    : () => _saveNotes(resummarize: true),
                                child: const Text('Save & Re-summarize'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: TextField(
                            controller: _notesCtrl,
                            expands: true,
                            maxLines: null,
                            textAlignVertical: TextAlignVertical.top,
                            decoration: const InputDecoration(
                              hintText: 'Your rough meeting notes...',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 3. Transcript Tab
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          controller: _transcriptFilterCtrl,
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            hintText: 'Filter transcript...',
                          ),
                          onChanged: (v) =>
                              setState(() => _transcriptFilter = v.trim()),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: filteredSegments.isNotEmpty
                              ? ListView.separated(
                                  itemCount: filteredSegments.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (_, idx) {
                                    final seg = filteredSegments[idx];
                                    return Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          width: 58,
                                          child: Text(
                                            MarkdownFormatter.formatTimestamp(
                                              seg.startSec,
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ),
                                        Expanded(
                                          child: SelectableText(seg.text),
                                        ),
                                      ],
                                    );
                                  },
                                )
                              : SingleChildScrollView(
                                  child: SelectableText(
                                    m.transcript.trim().isNotEmpty
                                        ? m.transcript
                                        : 'No transcript available yet.',
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),

                  // 4. Ask AI Tab
                  Column(
                    children: [
                      if (_chatMessages.isNotEmpty)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _clearChat,
                            child: const Text('Clear Chat'),
                          ),
                        ),
                      Expanded(
                        child: _chatMessages.isEmpty
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text(
                                    'Ask anything about decisions, quotes, or action items from this meeting.',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.all(16),
                                itemCount: _chatMessages.length,
                                itemBuilder: (_, idx) {
                                  final msg = _chatMessages[idx];
                                  final isUser = msg.role == 'user';
                                  return Align(
                                    alignment: isUser
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 10),
                                      padding: const EdgeInsets.all(12),
                                      constraints: const BoxConstraints(
                                        maxWidth: 320,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isUser
                                            ? colors.primary
                                            : colors.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: isUser
                                          ? Text(
                                              msg.content,
                                              style: TextStyle(
                                                color: colors.onPrimary,
                                              ),
                                            )
                                          : MarkdownBody(
                                              data: msg.content,
                                              selectable: true,
                                            ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _chatCtrl,
                                  decoration: const InputDecoration(
                                    hintText: 'Ask about this meeting...',
                                  ),
                                  onSubmitted: (_) => _sendChat(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filled(
                                onPressed: _sendingChat ? null : _sendChat,
                                icon: _sendingChat
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.send),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
