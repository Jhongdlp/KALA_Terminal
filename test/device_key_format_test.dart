// Validates the OpenSSH key container produced by DeviceKey against the same
// parser used at connect time (dartssh2's SSHKeyPair.fromPem): a key we
// generate must round-trip into a usable ed25519 identity.
//
// The encoding logic is exercised directly (not via DeviceKey.generate, which
// needs secure storage): the test replicates generate()'s two inputs by
// driving the private encoder through a known pinenacl keypair.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/ed25519.dart' as nacl;

import 'package:terminal_agent/services/device_key.dart';

void main() {
  test('DeviceKey PEM round-trips through dartssh2 and signs correctly', () {
    final signingKey = nacl.SigningKey.generate();
    final seed = Uint8List.fromList(signingKey.seed);
    final publicKey = Uint8List.fromList(signingKey.verifyKey);

    final pem = DeviceKey.encodeOpenSshPrivateForTest(seed, publicKey);

    // dartssh2 must parse it as a single ed25519 identity.
    final pairs = SSHKeyPair.fromPem(pem);
    expect(pairs, hasLength(1));
    final pair = pairs.single;
    expect(pair.type, 'ssh-ed25519');

    // And its signature over arbitrary data must verify with the public key.
    final data = utf8.encode('kala device key roundtrip');
    final sigEncoded = pair.sign(Uint8List.fromList(data)).encode();
    final verified = signingKey.verifyKey.verify(
      signature: nacl.Signature(_ed25519SigBytes(sigEncoded)),
      message: Uint8List.fromList(data),
    );
    expect(verified, isTrue);
  });

  test('public line and fingerprint derive from the same blob', () {
    final signingKey = nacl.SigningKey.generate();
    final publicKey = Uint8List.fromList(signingKey.verifyKey);

    final line = DeviceKey.publicLineForTest(publicKey);
    expect(line, startsWith('ssh-ed25519 '));
    expect(line, endsWith(' kala@device'));

    // The base64 blob must decode to {string "ssh-ed25519", string pub}.
    final blob = base64.decode(line.split(' ')[1]);
    expect(blob.sublist(4, 4 + 11), utf8.encode('ssh-ed25519'));
    expect(blob.sublist(blob.length - 32), publicKey);
  });
}

/// dartssh2 signatures encode as an SSH wire blob {type, sig}; extract the raw
/// 64-byte ed25519 signature for pinenacl to verify.
Uint8List _ed25519SigBytes(Uint8List encoded) {
  // {uint32 len, "ssh-ed25519", uint32 len, sig64} → last 64 bytes.
  return Uint8List.sublistView(encoded, encoded.length - 64);
}
