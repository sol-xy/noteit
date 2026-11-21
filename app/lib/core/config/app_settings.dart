import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore()
      : _storage = const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock,
          ),
        );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class InMemoryKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class AppSettings extends ChangeNotifier {
  AppSettings({SecureKeyValueStore? store})
      : _store = store ?? FlutterSecureKeyValueStore();

  static const _serverUrlKey = 'noteit_server_url';
  static const _authTokenKey = 'noteit_auth_token';
  static const _sttProviderKey = 'noteit_stt_provider';

  final SecureKeyValueStore _store;

  String _serverUrl = '';
  String _authToken = '';
  String _sttProvider = 'auto';
  bool _loaded = false;

  String get serverUrl => _serverUrl;
  String get authToken => _authToken;
  String get sttProvider => _sttProvider;
  bool get isLoaded => _loaded;
  bool get isConfigured =>
      _serverUrl.isNotEmpty &&
      _authToken.isNotEmpty &&
      validateServerUrl(_serverUrl) == null;

  Future<void> load() async {
    _serverUrl = normalizeServerUrl(await _store.read(_serverUrlKey) ?? '');
    _authToken = (await _store.read(_authTokenKey) ?? '').trim();
    final provider = (await _store.read(_sttProviderKey) ?? 'auto').trim();
    _sttProvider = {'auto', 'groq', 'gemini'}.contains(provider)
        ? provider
        : 'auto';
    _loaded = true;
    notifyListeners();
  }

  Future<void> save({
    required String serverUrl,
    required String authToken,
    required String sttProvider,
  }) async {
    final normalizedUrl = normalizeServerUrl(serverUrl);
    final trimmedToken = authToken.trim();
    final normalizedProvider =
        {'auto', 'groq', 'gemini'}.contains(sttProvider.trim())
            ? sttProvider.trim()
            : 'auto';

    await _store.write(_serverUrlKey, normalizedUrl);
    await _store.write(_authTokenKey, trimmedToken);
    await _store.write(_sttProviderKey, normalizedProvider);

    _serverUrl = normalizedUrl;
    _authToken = trimmedToken;
    _sttProvider = normalizedProvider;
    _loaded = true;
    notifyListeners();
  }

  Future<void> clearCredentials() async {
    await _store.delete(_serverUrlKey);
    await _store.delete(_authTokenKey);
    _serverUrl = '';
    _authToken = '';
    notifyListeners();
  }

  static String normalizeServerUrl(String raw) {
    var trimmed = raw.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  /// Returns an error string if invalid, or null if valid.
  static String? validateServerUrl(String raw) {
    final normalized = normalizeServerUrl(raw);
    if (normalized.isEmpty) {
      return 'Server URL is required';
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      return 'Enter a valid URL starting with https:// or http://';
    }
    return null;
  }

  static bool isInsecureHttpUrl(String raw) {
    final uri = Uri.tryParse(normalizeServerUrl(raw));
    return uri != null && uri.scheme == 'http';
  }
}
