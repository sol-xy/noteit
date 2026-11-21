import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class AudioRecorderService {
  AudioRecorderService({this._recorder});

  AudioRecorder? _recorder;
  AudioRecorder get _instance => _recorder ??= AudioRecorder();

  final _durationController = StreamController<Duration>.broadcast();
  final _amplitudeController = StreamController<double>.broadcast();
  final _stateController = StreamController<RecordState>.broadcast();

  StreamSubscription<Amplitude>? _ampSub;
  StreamSubscription<RecordState>? _stateSub;
  Timer? _elapsedTimer;

  RecordState _currentState = RecordState.stop;
  Duration _elapsed = Duration.zero;
  String? _activeFilePath;
  DateTime? _segmentStart;

  RecordState get currentState => _currentState;
  Duration get elapsed => _elapsed;
  String? get activeFilePath => _activeFilePath;

  Stream<Duration> get durationStream => _durationController.stream;
  Stream<double> get amplitudeStream => _amplitudeController.stream;
  Stream<RecordState> get stateStream => _stateController.stream;

  Future<bool> hasPermission() => _instance.hasPermission();

  Future<String> startNewRecording(String meetingClientId) async {
    final permitted = await _instance.hasPermission();
    if (!permitted) {
      throw StateError('Microphone permission was denied.');
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final recDir = Directory(p.join(docsDir.path, 'recordings'));
    if (!await recDir.exists()) {
      await recDir.create(recursive: true);
    }
    final filePath = p.join(recDir.path, '$meetingClientId.m4a');

    _elapsed = Duration.zero;
    _activeFilePath = filePath;
    _segmentStart = DateTime.now();

    _attachSubscriptions();

    const config = RecordConfig(
      encoder: AudioEncoder.aacLc,
      bitRate: 32000,
      sampleRate: 24000,
      numChannels: 1,
      iosConfig: IosRecordConfig(
        categoryOptions: [
          IosAudioCategoryOption.allowBluetooth,
          IosAudioCategoryOption.defaultToSpeaker,
        ],
      ),
    );

    await _instance.start(config, path: filePath);
    _currentState = RecordState.record;
    _stateController.add(_currentState);
    _startTimer();
    return filePath;
  }

  Future<void> pause() async {
    if (_currentState != RecordState.record) return;
    await _instance.pause();
    _flushSegmentElapsed();
    _elapsedTimer?.cancel();
    _currentState = RecordState.pause;
    _stateController.add(_currentState);
  }

  Future<void> resume() async {
    if (_currentState != RecordState.pause) return;
    await _instance.resume();
    _segmentStart = DateTime.now();
    _currentState = RecordState.record;
    _stateController.add(_currentState);
    _startTimer();
  }

  Future<String?> stop() async {
    _flushSegmentElapsed();
    _elapsedTimer?.cancel();
    _elapsedTimer = null;

    final path = await _instance.stop();
    await _detachSubscriptions();
    _currentState = RecordState.stop;
    _stateController.add(_currentState);
    final result = path ?? _activeFilePath;
    _activeFilePath = null;
    return result;
  }

  Future<void> discard() async {
    final path = await stop();
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  void _attachSubscriptions() {
    _ampSub?.cancel();
    _stateSub?.cancel();

    _ampSub = _instance
        .onAmplitudeChanged(const Duration(milliseconds: 120))
        .listen((amp) {
      // Normalize dBFS [-60, 0] into [0.0, 1.0].
      final normalized = ((amp.current + 60.0) / 60.0).clamp(0.0, 1.0);
      _amplitudeController.add(normalized);
    });

    _stateSub = _instance.onStateChanged().listen((state) {
      if (state == RecordState.pause && _currentState == RecordState.record) {
        _flushSegmentElapsed();
        _elapsedTimer?.cancel();
      } else if (state == RecordState.record && _currentState == RecordState.pause) {
        _segmentStart = DateTime.now();
        _startTimer();
      }
      _currentState = state;
      _stateController.add(state);
    });
  }

  Future<void> _detachSubscriptions() async {
    await _ampSub?.cancel();
    _ampSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
  }

  void _startTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_currentState == RecordState.record && _segmentStart != null) {
        final total = _elapsed + DateTime.now().difference(_segmentStart!);
        _durationController.add(total);
      }
    });
  }

  void _flushSegmentElapsed() {
    if (_segmentStart != null) {
      _elapsed += DateTime.now().difference(_segmentStart!);
      _segmentStart = null;
      _durationController.add(_elapsed);
    }
  }

  Future<void> dispose() async {
    _elapsedTimer?.cancel();
    await _detachSubscriptions();
    await _recorder?.dispose();
    await _durationController.close();
    await _amplitudeController.close();
    await _stateController.close();
  }
}
