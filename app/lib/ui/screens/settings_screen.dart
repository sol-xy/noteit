import 'package:material_ui/material_ui.dart';

import '../../core/api/noteit_api_client.dart';
import '../../core/config/app_settings.dart';
import '../../core/storage/local_db.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.api,
    required this.db,
  });

  final AppSettings settings;
  final NoteItApiClient api;
  final LocalDb db;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;

  String _sttProvider = 'auto';
  bool _obscureToken = true;
  bool _testing = false;
  bool _saving = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.settings.serverUrl);
    _tokenCtrl = TextEditingController(text: widget.settings.authToken);
    _sttProvider = widget.settings.sttProvider;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _statusMessage = null;
    });
    try {
      final info = await widget.api.testConnection(
        serverUrl: _urlCtrl.text,
        authToken: _tokenCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _statusIsError = false;
        _statusMessage =
            'Connected (${info['auth_method']}) · Server default STT: ${info['default_stt_provider']}';
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _statusIsError = true;
        _statusMessage = err.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.settings.save(
        serverUrl: _urlCtrl.text,
        authToken: _tokenCtrl.text,
        sttProvider: _sttProvider,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved securely in Keychain')),
      );
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Local Cache?'),
        content: const Text(
          'Removes locally cached meetings and chat threads from this device. '
          'Meetings stored on your server remain intact.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.db.clearAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Local cache cleared')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final showHttpWarning = AppSettings.isInsecureHttpUrl(_urlCtrl.text);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Backend Connection',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://noteit.example.com',
              ),
              onChanged: (_) => setState(() {}),
              validator: (v) => AppSettings.validateServerUrl(v ?? ''),
            ),
            if (showHttpWarning) ...[
              const SizedBox(height: 8),
              Text(
                'Warning: Using plain HTTP sends your access token unencrypted. Use HTTPS in production.',
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _tokenCtrl,
              obscureText: _obscureToken,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Personal Access Token',
                hintText: 'Paste AUTH_TOKEN from your server .env',
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                  icon: Icon(
                    _obscureToken ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Token is required' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _testing ? null : _testConnection,
                    child: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Test Connection'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _saveSettings,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                _statusMessage!,
                style: TextStyle(
                  color: _statusIsError ? colors.error : colors.primary,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'Speech-to-Text Preference',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('Auto')),
                ButtonSegment(value: 'groq', label: Text('Groq')),
                ButtonSegment(value: 'gemini', label: Text('Gemini')),
              ],
              selected: {_sttProvider},
              onSelectionChanged: (sel) =>
                  setState(() => _sttProvider = sel.first),
            ),
            const SizedBox(height: 6),
            Text(
              'Auto uses Groq Whisper (whisper-large-v3-turbo) and falls back to Gemini Flash if rate-limited.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'iPhone Action Button Setup',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '1. Start one quick recording in-app first to grant Microphone permission.\n'
                      '2. Open iOS Settings -> Action Button -> Shortcut.\n'
                      '3. Select "Toggle NoteIt Recording" (or "Start NoteIt Recording").\n'
                      '4. Press the side Action Button anytime to launch & record immediately. '
                      'Once recording starts, you can lock your screen and it keeps recording.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _clearCache,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Clear Local Cache'),
            ),
          ],
        ),
      ),
    );
  }
}
