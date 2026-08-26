import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/models/connection_error.dart';
import 'package:terminal_agent/models/connection_profile.dart';
import 'package:terminal_agent/models/jump_chain.dart';

ConnectionProfile p(String id, {String? jump, bool isLocal = false}) =>
    ConnectionProfile(
      id: id,
      name: id,
      host: '$id.example.com',
      port: 22,
      username: 'u',
      isLocal: isLocal,
      jumpProfileId: jump,
    );

void main() {
  group('resolve', () {
    test('a profile with no jump connects directly', () {
      final target = p('prod');
      expect(JumpChain.resolve(target, [target]), isEmpty);
    });

    test('one hop', () {
      final bastion = p('bastion');
      final prod = p('prod', jump: 'bastion');
      expect(JumpChain.resolve(prod, [bastion, prod]).map((h) => h.id),
          ['bastion']);
    });

    test('hops come back in dial order, outermost first', () {
      // edge -> dmz -> prod is how the user reads it; edge is what the phone
      // actually dials, so that is what has to come out first.
      final edge = p('edge');
      final dmz = p('dmz', jump: 'edge');
      final prod = p('prod', jump: 'dmz');
      expect(JumpChain.resolve(prod, [edge, dmz, prod]).map((h) => h.id),
          ['edge', 'dmz']);
    });

    test('a deleted jump host is named, not silently ignored', () {
      final prod = p('prod', jump: 'gone');
      final error = JumpChain.validate(prod, [prod]);
      expect(error, isNotNull);
      expect(error!.problem, JumpChainProblem.missing);
      expect(error.hopName, 'gone');
    });

    test('a profile pointing at itself is a cycle, not a one-hop chain', () {
      final self = p('self', jump: 'self');
      expect(JumpChain.validate(self, [self])!.problem, JumpChainProblem.cycle);
    });

    test('a two-profile loop terminates instead of hanging', () {
      final a = p('a', jump: 'b');
      final b = p('b', jump: 'a');
      expect(JumpChain.validate(a, [a, b])!.problem, JumpChainProblem.cycle);
    });

    test('the local terminal cannot be a hop', () {
      final local = p('local', isLocal: true);
      final prod = p('prod', jump: 'local');
      expect(JumpChain.validate(prod, [local, prod])!.problem,
          JumpChainProblem.localHop);
    });

    test('a chain exactly at the limit resolves', () {
      final all = <ConnectionProfile>[p('h0')];
      for (var i = 1; i <= JumpChain.maxHops; i++) {
        all.add(p('h$i', jump: 'h${i - 1}'));
      }
      final target = all.last;
      expect(JumpChain.resolve(target, all).length, JumpChain.maxHops);
    });

    test('one hop past the limit is refused', () {
      final all = <ConnectionProfile>[p('h0')];
      for (var i = 1; i <= JumpChain.maxHops + 1; i++) {
        all.add(p('h$i', jump: 'h${i - 1}'));
      }
      expect(JumpChain.validate(all.last, all)!.problem,
          JumpChainProblem.tooDeep);
    });
  });

  group('wouldCycle', () {
    final a = p('a');
    final b = p('b', jump: 'a');
    final c = p('c', jump: 'b');
    final all = [a, b, c];

    test('a profile may not jump through itself', () {
      expect(JumpChain.wouldCycle('a', 'a', all), isTrue);
    });

    test('jumping through something already behind you closes the loop', () {
      // c already goes through b through a; making a jump through c is a loop.
      expect(JumpChain.wouldCycle('a', 'c', all), isTrue);
    });

    test('jumping deeper down an existing chain is fine', () {
      final d = p('d');
      expect(JumpChain.wouldCycle('d', 'c', [...all, d]), isFalse);
    });

    test('a loop elsewhere in the list does not hang the walk', () {
      final x = p('x', jump: 'y');
      final y = p('y', jump: 'x');
      expect(JumpChain.wouldCycle('a', 'x', [...all, x, y]), isFalse);
    });
  });

  group('candidatesFor', () {
    test('offers only usable hops', () {
      final a = p('a');
      final b = p('b', jump: 'a');
      final local = p('local', isLocal: true);
      final all = [a, b, local];

      // For `a`: not itself, not the local terminal, and not `b` — which
      // already goes through `a`.
      expect(JumpChain.candidatesFor('a', all).map((x) => x.id), isEmpty);
      expect(JumpChain.candidatesFor('new', all).map((x) => x.id), ['a', 'b']);
    });

    test('a candidate that would overflow the limit is not offered', () {
      final all = <ConnectionProfile>[p('h0')];
      for (var i = 1; i <= JumpChain.maxHops; i++) {
        all.add(p('h$i', jump: 'h${i - 1}'));
      }
      final ids = JumpChain.candidatesFor('new', all).map((x) => x.id);
      // Jumping through h4 gives a chain of maxHops; through h5 it would be
      // one too many.
      expect(ids, contains('h${JumpChain.maxHops - 1}'));
      expect(ids, isNot(contains('h${JumpChain.maxHops}')));
    });
  });

  group('describe', () {
    test('reads in dial order', () {
      final edge = p('edge');
      final dmz = p('dmz', jump: 'edge');
      final prod = p('prod', jump: 'dmz');
      expect(JumpChain.describe(prod, [edge, dmz, prod]), 'edge → dmz');
    });

    test('is null for a direct profile and never throws on a broken one', () {
      final direct = p('direct');
      final broken = p('broken', jump: 'gone');
      expect(JumpChain.describe(direct, [direct]), isNull);
      expect(JumpChain.describe(broken, [broken]), isNull);
    });
  });

  group('persistence', () {
    test('the jump survives a JSON round trip', () {
      final prod = p('prod', jump: 'bastion');
      expect(ConnectionProfile.fromJson(prod.toJson()).jumpProfileId,
          'bastion');
      // It is metadata, not a secret, so it belongs in the plain prefs blob.
      expect(prod.toMapPublic()['jumpProfileId'], 'bastion');
    });

    test('a profile saved before this feature connects directly', () {
      final legacy = ConnectionProfile.fromMap({
        'id': 'old',
        'name': 'box',
        'host': 'h',
        'port': 22,
        'username': 'u',
      });
      expect(legacy.jumpProfileId, isNull);
    });

    test('copyWith needs clearJump to unlink', () {
      final prod = p('prod', jump: 'bastion');
      expect(prod.copyWith(name: 'other').jumpProfileId, 'bastion');
      expect(prod.copyWith(clearJump: true).jumpProfileId, isNull);
    });
  });

  group('failure routing', () {
    test('a broken chain sends the user to the profile, not to a retry', () {
      final failure = ConnectionError.from(const JumpChainError(
          JumpChainProblem.missing,
          profileName: 'prod',
          hopName: 'bastion'));

      expect(failure.kind, ConnectionErrorKind.jump);
      expect(failure.suggestsEditingProfile, isTrue);
      expect(failure.title, contains('prod'));
    });

    test('a hop failure is classified by its cause and names the hop', () {
      // The bastion rejected the password: that is an auth problem, and the
      // message has to say which of the three machines refused.
      final failure = ConnectionError.from(
          const JumpHopError('bastion', 'SSHAuthFailError: permission denied'));

      expect(failure.kind, ConnectionErrorKind.auth);
      expect(failure.title, contains('bastion'));
    });

    test('a hop that timed out is still a network failure', () {
      final failure = ConnectionError.from(
          const JumpHopError('bastion', 'SocketException: Connection timed out'));

      expect(failure.kind, ConnectionErrorKind.network);
    });
  });
}
