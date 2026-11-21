import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../../core/api/noteit_api_client.dart';
import '../../core/config/app_settings.dart';
import '../../core/models/meeting.dart';
import '../../core/storage/local_db.dart';
import '../../core/utils/markdown_formatter.dart';
import '../../services/action_button_service.dart';
import '../../services/audio_recorder_service.dart';
import '../../services/upload_service.dart';
import 'meeting_detail_screen.dart';
import 'recorder_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.settings,
    required this.api,
    required this.db,
    required this.recorder,
    required this.uploadService,
    required this.actionButtonService,
  });

  final AppSettings settings;
  final NoteItApiClient api;
  final LocalDb db;
  final AudioRecorderService recorder;
  final UploadService uploadService;
  final ActionButtonService actionButtonService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchCtrl = TextEditingController();
  List<Meeting> _meetings = [];
  bool _loading = true;
  bool _recorderOpen = false;
  String? _syncError;

  StreamSubscription<ActionButtonCommand>? _actionSub;
  StreamSubscription<String>? _uploadSub;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _actionSub = widget.actionButtonService.commands.listen(_handleActionCmd);
    _uploadSub = widget.uploadService.onMeetingUpdated.listen((_) {
      unawaited(_loadLocalMeetings());
    });
    unawaited(_initialLoad());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _actionSub?.cancel();
    _uploadSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _initialLoad() async {
    await _loadLocalMeetings();
    await _refreshFromServer();
    await widget.actionButtonService.consumePendingAction();
  }

  Future<void> _loadLocalMeetings() async {
    final rows = await widget.db.listMeetings(query: _searchCtrl.text);
    if (mounted) {
      setState(() {
        _meetings = rows;
        _loading = false;
      });
    }
  }

  Future<void> _refreshFromServer() async {
    if (!widget.settings.isConfigured) {
      if (mounted) setState(() => _syncError = null);
      return;
    }
    try {
      await widget.uploadService.retryPendingUploads();
      final remote = await widget.api.listMeetings(query: _searchCtrl.text);
      await widget.db.upsertMeetingsFromServer(remote);
      final merged = await widget.db.listMeetings(query: _searchCtrl.text);
      if (mounted) {
        setState(() {
          _meetings = merged;
          _syncError = null;
        });
      }
    } catch (err) {
      if (mounted) {
        setState(() => _syncError = err.toString());
      }
    }
  }

  void _handleActionCmd(ActionButtonCommand cmd) {
    if ((cmd == ActionButtonCommand.startRecording ||
            cmd == ActionButtonCommand.toggleRecording) &&
        !_recorderOpen) {
      unawaited(_openRecorder());
    }
  }

  Future<void> _openRecorder() async {
    if (_recorderOpen || !mounted) return;
    _recorderOpen = true;
    final meetingId = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => RecorderScreen(
          settings: widget.settings,
          db: widget.db,
          recorder: widget.recorder,
          uploadService: widget.uploadService,
          actionButtonService: widget.actionButtonService,
        ),
      ),
    );
    _recorderOpen = false;
    await _loadLocalMeetings();
    if (meetingId != null && mounted) {
      await _openDetail(meetingId);
    }
  }

  Future<void> _openDetail(String meetingId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MeetingDetailScreen(
          meetingId: meetingId,
          settings: widget.settings,
          api: widget.api,
          db: widget.db,
          uploadService: widget.uploadService,
        ),
      ),
    );
    await _loadLocalMeetings();
    await _refreshFromServer();
  }

  Future<void> _openSettings() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: widget.settings,
          api: widget.api,
          db: widget.db,
        ),
      ),
    );
    if (saved == true) {
      await _refreshFromServer();
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return DateFormat('MMM d, HH:mm').format(dt);
  }

  Color _badgeColor(String status, ColorScheme colors) {
    switch (status) {
      case 'completed':
        return colors.primary.withValues(alpha: 0.14);
      case 'failed':
      case 'upload failed':
        return colors.error.withValues(alpha: 0.14);
      default:
        return colors.secondary.withValues(alpha: 0.16);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('NoteIt'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openRecorder,
        icon: const Icon(Icons.mic),
        label: const Text('Record'),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshFromServer,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          children: [
            if (!widget.settings.isConfigured)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: Icon(Icons.link, color: colors.primary),
                  title: const Text('Connect Your Server'),
                  subtitle: const Text(
                    'Add your server URL and personal access token in Settings to enable transcription and summaries.',
                  ),
                  trailing: TextButton(
                    onPressed: _openSettings,
                    child: const Text('Setup'),
                  ),
                ),
              ),
            if (_syncError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Offline / Sync note: $_syncError',
                  style: TextStyle(color: colors.error, fontSize: 12),
                ),
              ),
            TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search meetings, notes, transcripts...',
              ),
              onChanged: (_) {
                _searchDebounce?.cancel();
                _searchDebounce = Timer(const Duration(milliseconds: 220), () {
                  unawaited(_loadLocalMeetings());
                  unawaited(_refreshFromServer());
                });
              },
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_meetings.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48, horizontal: 16),
                child: Center(
                  child: Text(
                    'No meetings yet.\nTap Record or press your iPhone Action Button to capture your first meeting.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              for (final m in _meetings)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    onTap: () => _openDetail(m.id),
                    title: Text(
                      m.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        [
                          _formatDate(m.createdAt),
                          if (m.durationSeconds != null)
                            MarkdownFormatter.formatTimestamp(m.durationSeconds!),
                        ].join(' · '),
                      ),
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _badgeColor(m.displayStatus, colors),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        m.displayStatus,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
