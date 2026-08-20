import 'package:flutter_test/flutter_test.dart';
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
      // Importing a ProxyJump entry would create a profile that silently
      // connects somewhere else (or nowhere) — worse than not importing it.
      final hosts = SshConfigImport.parse('''
Host behind-bastion
  HostName 10.0.0.9
  ProxyJump bastion

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
}
