import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pinenacl/ed25519.dart' as nacl;

import 'secure_store.dart';

/// The phone's own SSH identity: a single ed25519 keypair generated on-device
/// and kept in secure storage. Profiles opt in with `useDeviceKey`; the user
/// installs it on servers by copying the public line into
/// `~/.ssh/authorized_keys`. Passwordless auth without ever moving a private
/// key off the phone.
class DeviceKey {
  DeviceKey._();

  static const String _comment = 'kammel@device';

  /// Cached PEM for the current process (secure-storage reads are slow on
  /// Android; the key never changes underneath us except via [generate]).
  static String? _pemCache;

  /// Returns the device key's private PEM, or null if none was generated yet.
  static Future<String?> privatePem() async {
    return _pemCache ??= await SecureStore.instance.readDeviceKey();
  }

  static Future<bool> exists() async => (await privatePem()) != null;

  /// Generates a fresh ed25519 keypair, stores it, and returns its PEM.
  /// Replaces any previous key (callers should confirm with the user first —
  /// servers holding the old public key stop accepting the phone).
  static Future<String> generate() async {
    final signingKey = nacl.SigningKey.generate();
    final seed = Uint8List.fromList(signingKey.seed);
    final publicKey = Uint8List.fromList(signingKey.verifyKey);
    final pem = _encodeOpenSshPrivate(seed, publicKey);
    await SecureStore.instance.writeDeviceKey(pem);
    _pemCache = pem;
    return pem;
  }

  /// The `authorized_keys` line for the stored key, or null without a key.
  static Future<String?> publicLine() async {
    final pub = await _publicKeyBytes();
    if (pub == null) return null;
    return 'ssh-ed25519 ${base64.encode(_publicBlob(pub))} $_comment';
  }

  /// OpenSSH-style fingerprint (`SHA256:<base64-nopad>`), or null without a key.
  static Future<String?> fingerprint() async {
    final pub = await _publicKeyBytes();
    if (pub == null) return null;
    final digest = sha256.convert(_publicBlob(pub)).bytes;
    return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
  }

  /// Recovers the 32-byte public key from the stored PEM. The ed25519 private
  /// block stores seed‖pub, so no elliptic math is needed here.
  static Future<Uint8List?> _publicKeyBytes() async {
    final pem = await privatePem();
    if (pem == null) return null;
    final seed = _seedFromPem(pem);
    if (seed == null) return null;
    return Uint8List.fromList(nacl.SigningKey.fromSeed(seed).verifyKey);
  }

  /// Test-only access to the OpenSSH encoders (the real entry points depend on
  /// secure storage, unavailable in unit tests).
  @visibleForTesting
  static String encodeOpenSshPrivateForTest(
          Uint8List seed, Uint8List publicKey) =>
      _encodeOpenSshPrivate(seed, publicKey);

  @visibleForTesting
  static String publicLineForTest(Uint8List publicKey) =>
      'ssh-ed25519 ${base64.encode(_publicBlob(publicKey))} $_comment';

  // ---- OpenSSH key format ---------------------------------------------------
  // Unencrypted "openssh-key-v1" container holding one ed25519 key, exactly
  // what `ssh-keygen -t ed25519` produces and what dartssh2's
  // SSHKeyPair.fromPem parses back.

  /// `{ string "ssh-ed25519", string pub }` — the wire blob used in
  /// authorized_keys, fingerprints, and inside the private container.
  static Uint8List _publicBlob(Uint8List publicKey) {
    final w = _SshWriter();
    w.writeString(ascii.encode('ssh-ed25519'));
    w.writeString(publicKey);
    return w.takeBytes();
  }

  static String _encodeOpenSshPrivate(Uint8List seed, Uint8List publicKey) {
    final check = Random.secure().nextInt(0xFFFFFFFF);

    // Private section: check twice, key type + material, comment, then pad to
    // the cipher block size (8 for "none") with 1,2,3,…
    final priv = _SshWriter();
    priv.writeUint32(check);
    priv.writeUint32(check);
    priv.writeString(ascii.encode('ssh-ed25519'));
    priv.writeString(publicKey);
    priv.writeString(Uint8List.fromList([...seed, ...publicKey]));
    priv.writeString(ascii.encode(_comment));
    var pad = 1;
    while (priv.length % 8 != 0) {
      priv.writeByte(pad++);
    }

    final outer = _SshWriter();
    outer.writeRaw(ascii.encode('openssh-key-v1\x00'));
    outer.writeString(ascii.encode('none')); // cipher
    outer.writeString(ascii.encode('none')); // kdf
    outer.writeString(Uint8List(0)); // kdf options
    outer.writeUint32(1); // number of keys
    outer.writeString(_publicBlob(publicKey));
    outer.writeString(priv.takeBytes());

    final b64 = base64.encode(outer.takeBytes());
    final lines = <String>[];
    for (var i = 0; i < b64.length; i += 70) {
      lines.add(b64.substring(i, min(i + 70, b64.length)));
    }
    return '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        '${lines.join('\n')}\n'
        '-----END OPENSSH PRIVATE KEY-----\n';
  }

  /// Extracts the 32-byte seed back out of an unencrypted openssh-key-v1 PEM
  /// produced by [_encodeOpenSshPrivate].
  static Uint8List? _seedFromPem(String pem) {
    try {
      final body = pem
          .split('\n')
          .where((l) => l.isNotEmpty && !l.startsWith('-----'))
          .join();
      final data = base64.decode(body);
      final r = _SshReader(data);
      r.skipRaw('openssh-key-v1\x00'.length);
      r.readString(); // cipher
      r.readString(); // kdf
      r.readString(); // kdf options
      r.readUint32(); // nkeys
      r.readString(); // public blob
      final privBlock = _SshReader(r.readString());
      privBlock.readUint32();
      privBlock.readUint32();
      privBlock.readString(); // key type
      privBlock.readString(); // public key
      final keyMaterial = privBlock.readString(); // seed ‖ pub (64 bytes)
      if (keyMaterial.length < 32) return null;
      return Uint8List.sublistView(keyMaterial, 0, 32);
    } catch (_) {
      return null;
    }
  }
}

/// Minimal SSH wire-format writer (uint32 length-prefixed strings).
class _SshWriter {
  final _builder = BytesBuilder(copy: false);
  int get length => _builder.length;

  void writeRaw(List<int> bytes) => _builder.add(bytes);
  void writeByte(int byte) => _builder.addByte(byte & 0xFF);

  void writeUint32(int value) {
    _builder.add([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);
  }

  void writeString(List<int> bytes) {
    writeUint32(bytes.length);
    _builder.add(bytes);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

/// Minimal SSH wire-format reader mirroring [_SshWriter].
class _SshReader {
  final Uint8List _data;
  int _offset = 0;
  _SshReader(this._data);

  void skipRaw(int count) => _offset += count;

  int readUint32() {
    final v = (_data[_offset] << 24) |
        (_data[_offset + 1] << 16) |
        (_data[_offset + 2] << 8) |
        _data[_offset + 3];
    _offset += 4;
    return v;
  }

  Uint8List readString() {
    final len = readUint32();
    final out = Uint8List.sublistView(_data, _offset, _offset + len);
    _offset += len;
    return out;
  }
}
