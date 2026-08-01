import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/models/connection_profile.dart';
import 'package:terminal_agent/models/ssh_tunnel.dart';

void main() {
  group('SshTunnel.parseSpec', () {
    test('bare local spec defaults to -L', () {
      final t = SshTunnel.parseSpec('8080:localhost:80')!;
      expect(t.kind, TunnelKind.local);
      expect(t.listenPort, 8080);
      expect(t.destHost, 'localhost');
      expect(t.destPort, 80);
      expect(t.exposeToLan, isFalse);
    });

    test('reads the three flags, spaced or glued', () {
      expect(SshTunnel.parseSpec('-L 3000:127.0.0.1:3000')!.kind,
          TunnelKind.local);
      expect(SshTunnel.parseSpec('-D1080')!.kind, TunnelKind.dynamicSocks);
      expect(SshTunnel.parseSpec('-R 8080:localhost:3000')!.kind,
          TunnelKind.remote);
    });

    test('dynamic accepts both `1080` and `host:1080`', () {
      expect(SshTunnel.parseSpec('-D 1080')!.listenPort, 1080);
      final bound = SshTunnel.parseSpec('-D 0.0.0.0:1080')!;
      expect(bound.listenPort, 1080);
      expect(bound.exposeToLan, isTrue);
    });

    test('a wildcard bind address turns into exposeToLan', () {
      final t = SshTunnel.parseSpec('-L *:8080:localhost:80')!;
      expect(t.listenPort, 8080);
      expect(t.destPort, 80);
      expect(t.exposeToLan, isTrue);
    });

    test('a loopback bind address stays private', () {
      final t = SshTunnel.parseSpec('-L 127.0.0.1:8080:localhost:80')!;
      expect(t.exposeToLan, isFalse);
    });

    test('rejects garbage', () {
      expect(SshTunnel.parseSpec(''), isNull);
      expect(SshTunnel.parseSpec('-L'), isNull);
      expect(SshTunnel.parseSpec('8080:localhost'), isNull);
      expect(SshTunnel.parseSpec('ocho:localhost:80'), isNull);
    });
  });

  group('SshTunnel.toSpec', () {
    test('round-trips through parseSpec', () {
      for (final spec in const [
        '-L 8080:localhost:80',
        '-D 1080',
        '-R 9000:localhost:3000',
      ]) {
        expect(SshTunnel.parseSpec(spec)!.toSpec(), spec);
      }
    });

    test('marks a LAN-exposed bind', () {
      final t = SshTunnel(
          kind: TunnelKind.local,
          listenPort: 8080,
          destHost: 'localhost',
          destPort: 80,
          exposeToLan: true);
      expect(t.toSpec(), '-L *:8080:localhost:80');
    });
  });

  group('SshTunnel.validate', () {
    SshTunnel local(int listen, {int dest = 80, String host = 'localhost'}) =>
        SshTunnel(
            kind: TunnelKind.local,
            listenPort: listen,
            destHost: host,
            destPort: dest);

    test('accepts a normal local tunnel', () {
      expect(local(8080).validate(), isNull);
    });

    test('rejects privileged listen ports (Android cannot bind them)', () {
      expect(local(80).validate(), contains('1024'));
      expect(local(1023).validate(), contains('1024'));
      expect(local(1024).validate(), isNull);
    });

    test('rejects out-of-range and missing destinations', () {
      expect(local(70000).validate(), isNotNull);
      expect(local(8080, dest: 0).validate(), isNotNull);
      expect(local(8080, host: '  ').validate(), isNotNull);
    });

    test('remote tunnels may ask the server to pick the port', () {
      final t = SshTunnel(
          kind: TunnelKind.remote,
          listenPort: 0,
          destHost: 'localhost',
          destPort: 3000);
      expect(t.validate(), isNull);
    });

    test('SOCKS needs no destination', () {
      final t = SshTunnel(kind: TunnelKind.dynamicSocks, listenPort: 1080);
      expect(t.validate(), isNull);
    });
  });

  group('ConnectionProfile persistence', () {
    test('migrates legacy `forwards` into tunnels', () {
      final legacy = json.encode({
        'id': 'p1',
        'name': 'server',
        'host': '10.0.0.5',
        'port': 22,
        'username': 'jhon',
        'forwards': [
          {'bindPort': 8080, 'remoteHost': '127.0.0.1', 'remotePort': 80},
        ],
      });

      final profile = ConnectionProfile.fromJson(legacy);
      expect(profile.tunnels, hasLength(1));
      expect(profile.tunnels.single.kind, TunnelKind.local);
      expect(profile.tunnels.single.listenPort, 8080);
      expect(profile.tunnels.single.destHost, '127.0.0.1');
      expect(profile.tunnels.single.destPort, 80);
    });

    test('`tunnels` wins when both keys are present', () {
      final both = json.encode({
        'id': 'p1',
        'name': 'server',
        'host': '10.0.0.5',
        'port': 22,
        'username': 'jhon',
        'tunnels': [
          SshTunnel(kind: TunnelKind.dynamicSocks, listenPort: 1080).toMap(),
        ],
        'forwards': [
          {'bindPort': 8080, 'remoteHost': '127.0.0.1', 'remotePort': 80},
        ],
      });

      final profile = ConnectionProfile.fromJson(both);
      expect(profile.tunnels, hasLength(1));
      expect(profile.tunnels.single.kind, TunnelKind.dynamicSocks);
    });

    test('round-trips tunnels and keeps a legacy mirror for downgrades', () {
      final profile = ConnectionProfile(
        id: 'p1',
        name: 'server',
        host: '10.0.0.5',
        port: 22,
        username: 'jhon',
        tunnels: [
          SshTunnel(
              id: 't1',
              kind: TunnelKind.local,
              listenPort: 8080,
              destHost: 'localhost',
              destPort: 80),
          SshTunnel(id: 't2', kind: TunnelKind.dynamicSocks, listenPort: 1080),
        ],
      );

      final map = json.decode(profile.toJson()) as Map<String, dynamic>;
      expect((map['forwards'] as List), hasLength(1)); // only the -L one
      expect((map['forwards'] as List).single['bindPort'], 8080);

      final restored = ConnectionProfile.fromJson(profile.toJson());
      expect(restored.tunnels.map((t) => t.id), ['t1', 't2']);
      expect(restored.tunnels[1].kind, TunnelKind.dynamicSocks);
    });

    test('ids survive an edit through copyWith', () {
      final profile = ConnectionProfile(
        id: 'p1',
        name: 'server',
        host: 'h',
        port: 22,
        username: 'u',
        tunnels: [SshTunnel(id: 't1', kind: TunnelKind.local, listenPort: 8080)],
      );
      final edited = profile.copyWith(tunnels: [
        profile.tunnels.single.copyWith(listenPort: 9090),
      ]);
      expect(edited.tunnels.single.id, 't1');
      expect(edited.tunnels.single.listenPort, 9090);
    });
  });

  group('ConnectionProfile.parseCommand', () {
    test('picks up -L, -D and -R from a full command line', () {
      final parsed = ConnectionProfile.parseCommand(
          'ssh -p 2222 -L 8080:localhost:80 -D 1080 -R 9000:localhost:3000 '
          'jhon@10.0.0.5')!;

      expect(parsed.host, '10.0.0.5');
      expect(parsed.username, 'jhon');
      expect(parsed.port, 2222);
      expect(parsed.tunnels.map((t) => t.kind), [
        TunnelKind.local,
        TunnelKind.dynamicSocks,
        TunnelKind.remote,
      ]);
    });

    test('does not mistake a flag value for the host', () {
      final parsed =
          ConnectionProfile.parseCommand('ssh -i /home/j/.ssh/id jhon@host')!;
      expect(parsed.host, 'host');
    });
  });
}
