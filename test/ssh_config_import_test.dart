import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/models/jump_chain.dart';
import 'package:terminal_agent/services/ssh_config_import.dart';

void main() {
  group('SshConfigImport.parse', () {
    test('reads a plain host block', () {
      final hosts = SshConfigImport.parse('''
Host prod
  HostName 10.0.0.5
  User deploy
  Port 2222
''');

      expect(hosts.length, 1);
      expect(hosts.single.alias, 'prod');
      expect(hosts.single.hostName, '10.0.0.5');
      expect(hosts.single.user, 'deploy');
      expect(hosts.single.port, 2222);
    });

    test('defaults the port and falls back to the alias as the host name', () {
      final hosts = SshConfigImport.parse('Host box\n  User me\n');

      expect(hosts.single.port, 22);
      // An entry with no HostName connects to the alias itself, exactly as
      // OpenSSH does.
      expect(hosts.single.hostName, 'box');
    });

    test('skips wildcard blocks, which are defaults and not machines', () {
      final hosts = SshConfigImport.parse('''
Host *
  ServerAliveInterval 60

Host real
  HostName example.com
''');

      expect(hosts.map((h) => h.alias), ['real']);
    });

    test('expands the several aliases a block can declare', () {
      final hosts =
          SshConfigImport.parse('Host a b c\n  HostName shared.example\n');

      expect(hosts.map((h) => h.alias), ['a', 'b', 'c']);
      expect(hosts.every((h) => h.hostName == 'shared.example'), isTrue);
    });

    test('drops hosts needing directives this app cannot honour', () {
      // A ProxyCommand entry would create a profile that silently connects
      // somewhere else (or nowhere) — worse than not importing it.
      final hosts = SshConfigImport.parse('''
Host tunneled
  HostName 10.0.0.9
  ProxyCommand nc -X connect -x proxy:8080 %h %p

Host direct
  HostName 10.0.0.10
''');

      expect(hosts.map((h) => h.alias), ['direct']);
    });

    test('accepts the Key=value form and ignores comments', () {
      final hosts = SshConfigImport.parse('''
# a comment
Host eq
  HostName=1.2.3.4
  User=root
''');

      expect(hosts.single.hostName, '1.2.3.4');
      expect(hosts.single.user, 'root');
    });

    test('an IdentityFile turns into "use the device key"', () {
      final hosts = SshConfigImport.parse(
          'Host keyed\n  HostName h\n  IdentityFile ~/.ssh/id_ed25519\n');

      final profile = hosts.single.toProfile();
      expect(profile.useDeviceKey, isTrue);
      // The key itself is never read out of the config file.
      expect(profile.privateKey, isNull);
      expect(profile.password, isNull);
    });

    test('an empty or junk file yields nothing rather than throwing', () {
      expect(SshConfigImport.parse(''), isEmpty);
      expect(SshConfigImport.parse('not a config at all'), isEmpty);
    });
  });

  group('SshConfigImport ProxyJump', () {
    test('links a jump host defined in the same file', () {
      final hosts = SshConfigImport.parse('''
Host bastion
  HostName bastion.example.com
  User jump

Host prod
  HostName 10.0.0.9
  ProxyJump bastion
''');

      final prod = hosts.firstWhere((h) => h.alias == 'prod');
      expect(prod.proxyJump, 'bastion');
      expect(hosts.map((h) => h.alias), containsAll(['bastion', 'prod']));
    });

    test('drops an entry whose jump host has no block here', () {
      // We would have to invent the bastion's user and port. A machine we
      // cannot route to correctly is not imported at all.
      final hosts = SshConfigImport.parse('''
Host prod
  HostName 10.0.0.9
  ProxyJump bastion.example.com
''');

      expect(hosts, isEmpty);
    });

    test('drops a multi-hop spec rather than guessing the order', () {
      final hosts = SshConfigImport.parse('''
Host a
  HostName a.example.com

Host b
  HostName b.example.com

Host prod
  HostName 10.0.0.9
  ProxyJump a,b
''');

      expect(hosts.map((h) => h.alias), containsAll(['a', 'b']));
      expect(hosts.map((h) => h.alias), isNot(contains('prod')));
    });

    test('drops a user@host jump spec', () {
      final hosts = SshConfigImport.parse('''
Host bastion
  HostName bastion.example.com

Host prod
  HostName 10.0.0.9
  ProxyJump jump@bastion
''');

      expect(hosts.map((h) => h.alias), ['bastion']);
    });

    test('"ProxyJump none" is not a jump host', () {
      final hosts = SshConfigImport.parse('''
Host prod
  HostName 10.0.0.9
  ProxyJump none
''');

      expect(hosts.single.proxyJump, isNull);
    });

    test('a loop drops every host in it', () {
      final hosts = SshConfigImport.parse('''
Host a
  HostName a.example.com
  ProxyJump b

Host b
  HostName b.example.com
  ProxyJump a
''');

      expect(hosts, isEmpty);
    });

    test('a host is dropped when its bastion was dropped', () {
      // The drop has to propagate: `deep` is only reachable through `mid`,
      // which is only reachable through a bastion we refused to invent.
      final hosts = SshConfigImport.parse('''
Host mid
  HostName mid.example.com
  ProxyJump unknown.example.com

Host deep
  HostName deep.example.com
  ProxyJump mid
''');

      expect(hosts, isEmpty);
    });

    test('a chain deeper than the app allows is dropped', () {
      final buffer = StringBuffer('Host h0\n  HostName h0.example.com\n');
      for (var i = 1; i <= JumpChain.maxHops + 1; i++) {
        buffer.write('Host h$i\n  HostName h$i.example.com\n'
            '  ProxyJump h${i - 1}\n');
      }
      final hosts = SshConfigImport.parse(buffer.toString());
      final aliases = hosts.map((h) => h.alias).toList();

      // The last one needs maxHops + 1 hops to be reached.
      expect(aliases, contains('h${JumpChain.maxHops}'));
      expect(aliases, isNot(contains('h${JumpChain.maxHops + 1}')));
    });
  });

  group('SshConfigImport.toProfiles', () {
    final hosts = SshConfigImport.parse('''
Host bastion
  HostName bastion.example.com
  User jump

Host prod
  HostName 10.0.0.9
  User deploy
  ProxyJump bastion

Host alone
  HostName alone.example.com
''');

    test('wires the chain by id, not by name', () {
      final profiles = SshConfigImport.toProfiles(hosts, {'prod', 'bastion'});
      final prod = profiles.firstWhere((p) => p.name == 'prod');
      final bastion = profiles.firstWhere((p) => p.name == 'bastion');

      expect(prod.jumpProfileId, bastion.id);
      expect(bastion.jumpProfileId, isNull);
      expect(JumpChain.resolve(prod, profiles).map((p) => p.name), ['bastion']);
    });

    test('pulls in a bastion that was not ticked', () {
      // Importing prod without bastion would create a profile that can never
      // connect, and the user has no way to know that from the list.
      final profiles = SshConfigImport.toProfiles(hosts, {'prod'});

      expect(profiles.map((p) => p.name), containsAll(['prod', 'bastion']));
      expect(JumpChain.validate(profiles.firstWhere((p) => p.name == 'prod'),
              profiles),
          isNull);
    });

    test('imports only what was asked for when nothing else is needed', () {
      final profiles = SshConfigImport.toProfiles(hosts, {'alone'});
      expect(profiles.map((p) => p.name), ['alone']);
    });

    test('an unknown alias in the selection is ignored', () {
      final profiles = SshConfigImport.toProfiles(hosts, {'ghost'});
      expect(profiles, isEmpty);
    });
  });
}
