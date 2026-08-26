import '../l10n/l10n.dart';
import 'connection_profile.dart';

/// Why a configured jump chain cannot be used.
enum JumpChainProblem {
  /// The profile named as the jump host no longer exists (deleted, or a
  /// backup restored without it).
  missing,

  /// The chain loops back on itself — A through B through A, or A through A.
  cycle,

  /// More hops than [JumpChain.maxHops].
  tooDeep,

  /// A hop points at the local terminal profile, which has no SSH server to
  /// forward through.
  localHop,
}

/// A chain that cannot be walked. This is a *configuration* failure, found
/// before a single socket is opened, so it is worth its own type: the message
/// has to name the broken link, and the fix is always "edit the profile".
class JumpChainError implements Exception {
  final JumpChainProblem problem;

  /// The profile whose `jumpProfileId` is the broken link.
  final String profileName;

  /// The hop it points at — a name when we could resolve one, the raw id when
  /// the profile is gone.
  final String hopName;

  const JumpChainError(this.problem,
      {required this.profileName, required this.hopName});

  String get message {
    switch (problem) {
      case JumpChainProblem.missing:
        return tr('El servidor de salto de "{0}" ya no existe.', [profileName]);
      case JumpChainProblem.cycle:
        return tr('Los saltos de "{0}" forman un ciclo.', [profileName]);
      case JumpChainProblem.tooDeep:
        return tr('La cadena de saltos de "{0}" es demasiado larga (máximo {1}).',
            [profileName, JumpChain.maxHops]);
      case JumpChainProblem.localHop:
        return tr('"{0}" no puede saltar por la terminal local.', [profileName]);
    }
  }

  @override
  String toString() => message;
}

/// A hop that was reachable as configuration but failed as a connection.
///
/// Kept distinct from the underlying error so the message can say *which*
/// machine of the chain refused: "no se pudo conectar" is useless when three
/// hosts were dialled and the user cannot tell which one broke.
class JumpHopError implements Exception {
  /// Name of the hop profile that failed.
  final String hopName;

  /// The failure as thrown by dartssh2 / dart:io.
  final Object cause;

  const JumpHopError(this.hopName, this.cause);

  @override
  String toString() => 'JumpHopError($hopName): $cause';
}

/// Resolution of `ProxyJump`-style host chaining.
///
/// A machine worth protecting is usually not reachable from the internet: it
/// sits behind a bastion, and `ssh -J bastion target` is how everyone gets to
/// it. Without this the app cannot reach any of those machines at all, which is
/// most of the interesting ones.
///
/// The chain is expressed as **profile ids**, not as a host/user/key triplet
/// copied onto the profile: the bastion is a machine the user already has a
/// profile for, with its own key, its own port and its own pinned host key, and
/// duplicating that into every profile behind it means fixing it in ten places
/// the day it moves.
///
/// Everything here is pure: no I/O, no `AppState`. That is what lets the form
/// refuse a cycle *before* saving it and the connection path refuse one before
/// opening a socket, with the same code.
class JumpChain {
  JumpChain._();

  /// Hard cap on intermediate hops. OpenSSH has no fixed limit; this one exists
  /// so a malformed chain fails with a sentence instead of with a stack of
  /// timeouts, and five is already more bastions than anyone stacks.
  static const int maxHops = 5;

  /// The hops needed to reach [target], in **dial order**: the first entry is
  /// the one contacted directly from the device, the last one is where the
  /// forward to [target] is opened. Empty when the profile connects directly.
  ///
  /// Throws [JumpChainError] when the chain is unusable.
  static List<ConnectionProfile> resolve(
      ConnectionProfile target, List<ConnectionProfile> all) {
    final byId = {for (final p in all) p.id: p};
    final chain = <ConnectionProfile>[];
    // Seeded with the target so a profile pointing at itself reads as a cycle
    // rather than as a one-hop chain to itself.
    final visited = <String>{target.id};

    var current = target;
    while (current.jumpProfileId != null) {
      final hopId = current.jumpProfileId!;
      if (!visited.add(hopId)) {
        throw JumpChainError(JumpChainProblem.cycle,
            profileName: current.name, hopName: byId[hopId]?.name ?? hopId);
      }
      final hop = byId[hopId];
      if (hop == null) {
        throw JumpChainError(JumpChainProblem.missing,
            profileName: current.name, hopName: hopId);
      }
      if (hop.isLocal) {
        throw JumpChainError(JumpChainProblem.localHop,
            profileName: current.name, hopName: hop.name);
      }
      chain.add(hop);
      if (chain.length > maxHops) {
        throw JumpChainError(JumpChainProblem.tooDeep,
            profileName: target.name, hopName: hop.name);
      }
      current = hop;
    }

    // Collected target-first; dialling goes the other way.
    return chain.reversed.toList(growable: false);
  }

  /// [resolve] without the throw — the error, or null when the chain is fine.
  static JumpChainError? validate(
      ConnectionProfile target, List<ConnectionProfile> all) {
    try {
      resolve(target, all);
      return null;
    } on JumpChainError catch (e) {
      return e;
    }
  }

  /// Whether pointing [targetId]'s jump at [candidateId] would close a loop.
  ///
  /// This is what keeps the picker honest: an unusable chain is never offered
  /// in the first place, so it cannot be saved and then fail at connect time.
  static bool wouldCycle(
      String targetId, String candidateId, List<ConnectionProfile> all) {
    if (targetId == candidateId) return true;
    final byId = {for (final p in all) p.id: p};
    final seen = <String>{};
    var current = byId[candidateId];
    while (current != null) {
      if (current.id == targetId) return true;
      // A loop that does not pass through the target is somebody else's
      // problem; walking it forever would be ours.
      if (!seen.add(current.id)) return false;
      final next = current.jumpProfileId;
      current = next == null ? null : byId[next];
    }
    return false;
  }

  /// Hops already behind [candidateId], so the picker can refuse an option
  /// that would push the chain past [maxHops].
  static int depthOf(String candidateId, List<ConnectionProfile> all) {
    final byId = {for (final p in all) p.id: p};
    final seen = <String>{};
    var depth = 0;
    var current = byId[candidateId];
    while (current != null) {
      if (!seen.add(current.id)) break;
      depth++;
      final next = current.jumpProfileId;
      current = next == null ? null : byId[next];
    }
    return depth;
  }

  /// The profiles the profile with [targetId] may legally jump through, in the
  /// order given.
  ///
  /// Takes an id rather than a profile so the form can call it for a profile
  /// that does not exist yet: a draft has an id before it has anything else.
  static List<ConnectionProfile> candidatesFor(
      String targetId, List<ConnectionProfile> all) {
    return all
        .where((p) =>
            !p.isLocal &&
            p.id != targetId &&
            !wouldCycle(targetId, p.id, all) &&
            // Picking this candidate makes the target's chain exactly as long
            // as the candidate's own depth, so that is what has to fit.
            depthOf(p.id, all) <= maxHops)
        .toList(growable: false);
  }

  /// `bastión → dmz` for the UI, or null when the profile connects directly or
  /// its chain is broken. Never throws: this is called from `build`.
  static String? describe(ConnectionProfile target, List<ConnectionProfile> all) {
    try {
      final chain = resolve(target, all);
      if (chain.isEmpty) return null;
      return chain.map((p) => p.name).join(' → ');
    } on JumpChainError {
      return null;
    }
  }
}
