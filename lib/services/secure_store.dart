import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin wrapper over [FlutterSecureStorage] for connection secrets
/// (passwords and private keys). On Android these land in the Keystore-backed
/// EncryptedSharedPreferences; on Linux in libsecret. Profile *metadata* still
/// lives in plain shared_preferences — only the secrets go here, keyed by the
/// owning profile's id.
class SecureStore {
  SecureStore._();
  static final SecureStore instance = SecureStore._();

  static const _storage = FlutterSecureStorage();

  static String _pwKey(String id) => 'pw_$id';
  static String _pkKey(String id) => 'pk_$id';

  Future<String?> readPassword(String id) => _storage.read(key: _pwKey(id));
  Future<String?> readPrivateKey(String id) => _storage.read(key: _pkKey(id));

  /// Writes (or clears, when [value] is null/empty) a single secret.
  Future<void> _put(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  Future<void> writeSecrets(String id,
      {String? password, String? privateKey}) async {
    await _put(_pwKey(id), password);
    await _put(_pkKey(id), privateKey);
  }

  Future<void> deleteSecrets(String id) async {
    await _storage.delete(key: _pwKey(id));
    await _storage.delete(key: _pkKey(id));
  }
}
