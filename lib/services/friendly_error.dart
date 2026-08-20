import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../l10n/l10n.dart';

/// A failure turned into something a person can act on.
///
/// [message] is one sentence saying what went wrong; [hint] is the next thing
/// to try, when there is an obvious one; [detail] is the original exception,
/// kept verbatim so the UI can offer it behind a "ver detalle" and nothing is
/// actually lost in translation.
class FriendlyError {
  final String message;
  final String? hint;
  final String detail;

  const FriendlyError(this.message, {this.hint, required this.detail});

  /// One line for a terminal write or a log.
  String get oneLine => hint == null ? message : '$message $hint';

  @override
  String toString() => oneLine;
}

/// Maps the handful of failures a user actually hits to a sentence.
///
/// Everything here is a real failure mode of dartssh2 or `dart:io` on this
/// app's connection paths — SSH auth, a refused or unreachable host, a wrong
/// host key, a bad private key. Anything unrecognised keeps its own text
/// rather than being flattened into a useless "algo salió mal": a specific
/// unknown error is still more useful than a vague known one.
///
/// For *file* operations use `describeFileError` (`services/file_error.dart`)
/// instead — the same words mean different things there. "Permission denied"
/// from a handshake is a rejected credential; from SFTP it is a directory the
/// account cannot write to.
FriendlyError describeError(Object error) {
  final detail = _detailOf(error);
  final lower = detail.toLowerCase();

  FriendlyError of(String message, [String? hint]) =>
      FriendlyError(message, hint: hint, detail: detail);

  // ---- SSH ---------------------------------------------------------------

  if (error is SSHAuthFailError || lower.contains('authentication')) {
    return of(
      tr('El servidor rechazó las credenciales.'),
      tr('Revisa el usuario, la contraseña o la llave del perfil.'),
    );
  }
  if (error is SSHAuthAbortError) {
    return of(tr('La autenticación se interrumpió antes de terminar.'));
  }
  if (error is SSHKeyDecodeError || lower.contains('unsupported key')) {
    if (error is SSHKeyDecryptError) {
      return of(
        tr('La llave privada está protegida con contraseña.'),
        tr('KALA no puede descifrarla: usa una llave sin contraseña.'),
      );
    }
    return of(
      tr('No se pudo leer la llave privada.'),
      tr('Debe estar en formato PEM u OpenSSH y sin cifrar.'),
    );
  }
  if (error is SSHHostkeyError ||
      lower.contains('host key') ||
      lower.contains('hostkey')) {
    return of(
      tr('La clave del servidor no coincide con la guardada.'),
      tr('Si cambiaste de servidor, olvídalo en Ajustes → Servidores conocidos.'),
    );
  }

  // ---- Network -----------------------------------------------------------

  if (error is SocketException ||
      error is SSHSocketError ||
      lower.contains('socketexception')) {
    if (lower.contains('refused')) {
      return of(
        tr('El servidor rechazó la conexión en ese puerto.'),
        tr('Comprueba el puerto y que el servicio SSH esté activo.'),
      );
    }
    if (lower.contains('failed host lookup') ||
        lower.contains('no address associated')) {
      return of(
        tr('No se encontró ese host.'),
        tr('Revisa el nombre o usa su dirección IP.'),
      );
    }
    if (lower.contains('network is unreachable') ||
        lower.contains('no route to host')) {
      return of(
        tr('No hay ruta hasta ese servidor.'),
        tr('¿Necesitas estar en la misma red o conectar la VPN?'),
      );
    }
    return of(tr('No se pudo abrir la conexión.'));
  }
  if (error is TimeoutException ||
      lower.contains('timeout') ||
      lower.contains('timed out')) {
    return of(
      tr('El servidor no respondió a tiempo.'),
      tr('Puede estar apagado, o un firewall está bloqueando el puerto.'),
    );
  }

  // Unrecognised: its own text, trimmed. Better a specific unknown than a
  // vague known one.
  return FriendlyError(_trim(detail), detail: detail);
}

String _detailOf(Object error) {
  var msg = error.toString();
  if (msg.startsWith('Exception: ')) msg = msg.substring(11);
  return msg.trim();
}

String _trim(String msg) =>
    msg.length > 160 ? '${msg.substring(0, 157)}…' : msg;
