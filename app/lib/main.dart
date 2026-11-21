import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'core/api/noteit_api_client.dart';
import 'core/config/app_settings.dart';
import 'core/storage/local_db.dart';
import 'services/action_button_service.dart';
import 'services/audio_recorder_service.dart';
import 'services/upload_service.dart';
import 'ui/screens/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final settings = AppSettings();
  await settings.load();

  final db = LocalDb();
  final api = NoteItApiClient(settings: settings);
  final recorder = AudioRecorderService();
  final uploadService = UploadService(settings: settings, api: api, db: db);
  await uploadService.init();

  final actionButtonService = ActionButtonService();
  actionButtonService.init();

  runApp(
    NoteItApp(
      settings: settings,
      api: api,
      db: db,
      recorder: recorder,
      uploadService: uploadService,
      actionButtonService: actionButtonService,
    ),
  );
}

class NoteItApp extends StatelessWidget {
  const NoteItApp({
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
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NoteIt',
      debugShowCheckedModeBanner: false,
      theme: NoteItTheme.light(),
      darkTheme: NoteItTheme.dark(),
      themeMode: ThemeMode.system,
      home: HomeScreen(
        settings: settings,
        api: api,
        db: db,
        recorder: recorder,
        uploadService: uploadService,
        actionButtonService: actionButtonService,
      ),
    );
  }
}
