import '../l10n/l10n.dart';
import '../services/friendly_error.dart';
import 'jump_chain.dart';

/// What kind of failure it was — not for wording (that's [FriendlyError]'s job)
/// but for deciding **which action to offer**. "Reintentar" is the right button
/// for a timeout and the wrong one for a rejected password.
enum ConnectionErrorKind {
  /// Credentials rejected, or a key that couldn't be used.
  auth,

  /// Host doesn't resolve, nothing is listening, or the port is wrong.
  address,

  /// Reachability: timeout, no route, no network.
  network,

  /// Host key unknown or changed and not accepted.
  hostKey,

  /// The jump-host chain itself is unusable: a hop that no longer exists, a
  /// cycle, or one too many hops. Nothing was dialled.
  jump,

  /// Anything we couldn't place.
  unknown,
}

/// A connection failure, classified once and kept on the session.
///
/// The raw exception from dartssh2 is a developer string — `SSHAuthFailError`,
/// `SocketException: Connection refused (OS Error: …, errno = 111)`. Writing it
/// into the terminal is what the app used to do, and it tells the user neither
/// what happened nor what to do about it.
///
/// The *wording* comes from [describeError], which already knows this app's
/// real failure modes. What this class adds is the routing: which screen fixes
/// this, so the banner and the failure dialog can offer that button instead of
/// a generic retry.
class ConnectionError {
  final ConnectionErrorKind kind;
  final FriendlyError friendly;

  /// When it happened, so a banner can age ("hace 5 min") instead of implying
  /// the failure is current.
  final DateTime at;

  ConnectionError(this.kind, this.friendly, {DateTime? at})
      : at = at ?? DateTime.now();

  factory ConnectionError.from(Object error) =>
      ConnectionError(_kindOf(error), describeError(error));

  /// One short line for a banner.
  String get title => friendly.message;

  /// What to try next, when there is an obvious next thing.
  String? get hint => friendly.hint;

  /// The original exception text, kept for the "detalles técnicos" disclosure.
  String get detail => friendly.detail;

  /// Whether editing the profile is the likely fix — the failure dialog makes
  /// "Editar perfil" its primary action then, and demotes "Reintentar".
  bool get suggestsEditingProfile =>
      kind == ConnectionErrorKind.auth ||
      kind == ConnectionErrorKind.address ||
      kind == ConnectionErrorKind.jump;

  /// Whether this is resolved in Ajustes → Servidores conocidos.
  bool get suggestsKnownHosts => kind == ConnectionErrorKind.hostKey;

  /// Label for the action that most likely fixes it.
  String get primaryActionLabel {
    if (suggestsKnownHosts) return tr('Revisar identidad');
    if (suggestsEditingProfile) return tr('Editar perfil');
    return tr('Reintentar');
  }

  static ConnectionErrorKind _kindOf(Object error) {
    // Typed first: a broken chain is a configuration problem, and a failed hop
    // is classified by *its* cause — a bastion refusing the password should
    // still route to "editar perfil", not to a generic retry.
    if (error is JumpChainError) return ConnectionErrorKind.jump;
    if (error is JumpHopError) return _kindOf(error.cause);

    final text = error.toString().toLowerCase();
    bool has(List<String> needles) => needles.any(text.contains);

    if (has(['host key', 'hostkey'])) return ConnectionErrorKind.hostKey;
    if (has([
      'sshauthfail',
      'authentication',
      'permission denied',
      'unsupported key',
      'private key',
      'passphrase',
      'decrypt',
    ])) {
      return ConnectionErrorKind.auth;
    }
    if (has([
      'refused',
      'failed host lookup',
      'no address associated',
      'name or service not known',
      'errno = 111',
      'errno = 61',
    ])) {
      return ConnectionErrorKind.address;
    }
    if (has([
      'timeout',
      'timed out',
      'network is unreachable',
      'no route to host',
      'socketexception',
      'errno = 110',
      'errno = 101',
      'errno = 113',
    ])) {
      return ConnectionErrorKind.network;
    }
    return ConnectionErrorKind.unknown;
  }
}
