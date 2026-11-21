import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/app_settings.dart';
import '../../core/models/meeting.dart';
import '../../core/storage/local_db.dart';
import '../../core/utils/markdown_formatter.dart';
import '../../services/action_button_service.dart';
import '../../services/audio_recorder_service.dart';
import '../../services/upload_service.dart';

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({
    super.key,
    required this.settings,
    required this.db,
    required this.recorder,
    required this.uploadService,
    required this.actionButtonService,
  });

  final AppSettings settings;
  final LocalDb db;
  final AudioRecorderService recorder;
  final UploadService uploadService;
  final ActionButtonService actionButtonService;

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  final _titleCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  final String _clientId = const Uuid().v4();
  late Meeting _draft;

  StreamSubscription<Duration>? _durSub;
  StreamSubscription<double>? _ampSub;
  StreamSubscription<RecordState>? _stateSub;
  StreamSubscription<ActionButtonCommand>? _actionSub;
  Timer? _autosaveTimer;

  Duration _elapsed = Duration.zero;
  double _amplitude = 0.0;
  RecordState _recordState = RecordState.stop;
  bool _starting = true;
  bool _finishing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().toUtc().toIso8601String();
    _draft = Meeting(
      id: _clientId,
      clientId: _clientId,
      title: 'Untitled Meeting',
      status: 'created',
      sttProvider: widget.settings.sttProvider,
      createdAt: now,
      updatedAt: now,
      uploadState: 'recording',
    );

    _durSub = widget.recorder.durationStream.listen((d) {
      if (mounted) setState(() => _elapsed = d);
    });
    _ampSub = widget.recorder.amplitudeStream.listen((a) {
      if (mounted) setState(() => _amplitude = a);
    });
    _stateSub = widget.recorder.stateStream.listen((s) {
      if (mounted) setState(() => _recordState = s);
    });
    _actionSub = widget.actionButtonService.commands.listen((cmd) {
      if (cmd == ActionButtonCommand.toggleRecording &&
          !_starting &&
          !_finishing) {
        unawaited(_stopAndUpload());
      }
    });

    unawaited(_beginRecording());
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _durSub?.cancel();
    _ampSub?.cancel();
    _stateSub?.cancel();
    _actionSub?.cancel();
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _beginRecording() async {
    try {
      final path = await widget.recorder.startNewRecording(_clientId);
      _draft = _draft.copyWith(
        localAudioPath: path,
        uploadState: 'recording',
      );
      await widget.db.saveLocalMeeting(_draft);
      if (mounted) {
        setState(() {
          _starting = false;
          _recordState = RecordState.record;
        });
      }
    } catch (err) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = err.toString();
        });
      }
    }
  }

  void _scheduleDraftSave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistDraftFields());
    });
  }

  Future<void> _persistDraftFields() async {
    final title = _titleCtrl.text.trim().isEmpty
        ? 'Untitled Meeting'
        : _titleCtrl.text.trim();
    _draft = _draft.copyWith(
      title: title,
      manualNotes: _notesCtrl.text,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    await widget.db.saveLocalMeeting(_draft);
  }

  Future<void> _togglePauseResume() async {
    if (_recordState == RecordState.record) {
      await widget.recorder.pause();
    } else if (_recordState == RecordState.pause) {
      await widget.recorder.resume();
    }
  }

  Future<void> _stopAndUpload() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    _autosaveTimer?.cancel();

    try {
      final audioPath = await widget.recorder.stop();
      final title = _titleCtrl.text.trim().isEmpty
          ? 'Untitled Meeting'
          : _titleCtrl.text.trim();
      final completedDraft = _draft.copyWith(
        title: title,
        manualNotes: _notesCtrl.text,
        durationSeconds: _elapsed.inMilliseconds / 1000.0,
        localAudioPath: audioPath,
        uploadState: 'pending_upload',
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await widget.db.saveLocalMeeting(completedDraft);

      // Kick off upload without blocking navigation if offline.
      String finalMeetingId = completedDraft.id;
      try {
        final updated = await widget.uploadService.uploadMeeting(completedDraft);
        finalMeetingId = updated.id;
      } catch (_) {
        // Meeting remains saved locally with pending_upload / failed state for retry.
      }

      if (!mounted) return;
      Navigator.of(context).pop(finalMeetingId);
    } catch (err) {
      if (mounted) {
        setState(() {
          _finishing = false;
          _error = err.toString();
        });
      }
    }
  }

  Future<void> _confirmDiscard() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard Recording?'),
        content: const Text(
          'This will permanently delete the audio capture and rough notes for this session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Recording'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      _autosaveTimer?.cancel();
      await widget.recorder.discard();
      await widget.db.deleteMeeting(_draft.id);
      if (mounted) Navigator.of(context).pop(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isPaused = _recordState == RecordState.pause;
    final formattedTime =
        MarkdownFormatter.formatTimestamp(_elapsed.inSeconds.toDouble());

    return PopScope(
      canPop: _error != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_finishing) {
          unawaited(_confirmDiscard());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Discard',
            onPressed: _finishing ? null : _confirmDiscard,
          ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isPaused ? Colors.amber : colors.error,
                ),
              ),
              const SizedBox(width: 8),
              Text(isPaused ? 'Paused · $formattedTime' : formattedTime),
            ],
          ),
          actions: [
            TextButton(
              onPressed: _starting || _finishing ? null : _stopAndUpload,
              child: const Text('Done'),
            ),
          ],
        ),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.mic_off, size: 48, color: colors.error),
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.error),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(null),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: isPaused ? 0.0 : (0.08 + _amplitude * 0.92),
                        minHeight: 6,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _titleCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Meeting title (optional — AI names it later)',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        filled: false,
                      ),
                      style: Theme.of(context).textTheme.titleLarge,
                      onChanged: (_) => _scheduleDraftSave(),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        controller: _notesCtrl,
                        expands: true,
                        maxLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: const InputDecoration(
                          hintText:
                              'Jot down rough thoughts, names, or key bullets...\n\n'
                              'NoteIt merges these with the transcript into your enhanced summary.\n'
                              'You can lock your phone or switch apps anytime — recording continues in the background.',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          filled: false,
                        ),
                        onChanged: (_) => _scheduleDraftSave(),
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: _starting || _finishing
                                ? null
                                : _togglePauseResume,
                            icon: Icon(
                              isPaused ? Icons.play_arrow : Icons.pause,
                            ),
                            label: Text(isPaused ? 'Resume' : 'Pause'),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _starting || _finishing
                                  ? null
                                  : _stopAndUpload,
                              icon: _finishing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.stop_circle_outlined),
                              label: Text(
                                _finishing
                                    ? 'Saving & Queuing...'
                                    : 'Stop & Summarize',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
