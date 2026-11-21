import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum ActionButtonCommand {
  startRecording,
  toggleRecording,
}

class ActionButtonService with WidgetsBindingObserver {
  ActionButtonService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.noteit/action_button');

  final MethodChannel _channel;
  final _controller = StreamController<ActionButtonCommand>.broadcast();
  bool _initialized = false;

  Stream<ActionButtonCommand> get commands => _controller.stream;

  void init() {
    if (_initialized) return;
    _initialized = true;

    if (kIsWeb || !Platform.isIOS) {
      return;
    }

    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onActionTriggered') {
        _emitRawAction(call.arguments as String?);
      }
    });
    unawaited(consumePendingAction());
  }

  Future<void> consumePendingAction() async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      final raw = await _channel.invokeMethod<String>('consumePendingAction');
      _emitRawAction(raw);
    } on MissingPluginException {
      // Safe fallback during tests or unsupported environments.
    } catch (_) {
      // Ignore transient bridge errors.
    }
  }

  void _emitRawAction(String? raw) {
    if (raw == 'start_recording') {
      _controller.add(ActionButtonCommand.startRecording);
    } else if (raw == 'toggle_recording') {
      _controller.add(ActionButtonCommand.toggleRecording);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(consumePendingAction());
    }
  }

  void dispose() {
    if (_initialized && !kIsWeb && Platform.isIOS) {
      WidgetsBinding.instance.removeObserver(this);
      _channel.setMethodCallHandler(null);
    }
    _controller.close();
  }
}
