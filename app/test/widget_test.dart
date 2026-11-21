import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:noteit/core/api/noteit_api_client.dart';
import 'package:noteit/core/config/app_settings.dart';
import 'package:noteit/core/storage/local_db.dart';
import 'package:noteit/services/action_button_service.dart';
import 'package:noteit/services/audio_recorder_service.dart';
import 'package:noteit/services/upload_service.dart';
import 'package:noteit/ui/screens/home_screen.dart';
import 'package:noteit/ui/theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('validates and normalizes server URLs', () {
    expect(
      AppSettings.normalizeServerUrl(' https://noteit.example.com/ '),
      'https://noteit.example.com',
    );
    expect(AppSettings.validateServerUrl('https://noteit.example.com'), isNull);
    expect(AppSettings.validateServerUrl('not-a-url'), isNotNull);
    expect(AppSettings.isInsecureHttpUrl('http://localhost:8080'), isTrue);
    expect(
      AppSettings.isInsecureHttpUrl('https://noteit.example.com'),
      isFalse,
    );
  });

  testWidgets('HomeScreen shows setup banner when unconfigured', (tester) async {
    final settings = AppSettings(store: InMemoryKeyValueStore());
    await settings.load();

    final db = LocalDb(
      factory: databaseFactoryFfi,
      dbPathOverride: inMemoryDatabasePath,
    );
    await tester.runAsync(() async {
      await db.database;
    });

    final api = NoteItApiClient(
      settings: settings,
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    final recorder = AudioRecorderService();
    final uploadService = UploadService(settings: settings, api: api, db: db);
    final actionButtonService = ActionButtonService();

    await tester.pumpWidget(
      MaterialApp(
        theme: NoteItTheme.light(),
        home: HomeScreen(
          settings: settings,
          api: api,
          db: db,
          recorder: recorder,
          uploadService: uploadService,
          actionButtonService: actionButtonService,
        ),
      ),
    );

    // Let sqflite_common_ffi isolate query finish before pumping settled UI.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();

    expect(find.text('NoteIt'), findsOneWidget);
    expect(find.text('Connect Your Server'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);

    await tester.runAsync(() async {
      await db.close();
      await uploadService.dispose();
    });
    actionButtonService.dispose();
  });
}
