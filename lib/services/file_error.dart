/// Turns a failed file operation into a sentence the user can act on.
///
/// Deliberately **not** shared with [ConnectionError] (`models/connection_error.dart`),
/// which classifies SSH failures: the two look alike and mean opposite things.
/// "Permission denied" from a handshake is a rejected credential — the fix is
/// the profile. The same words from SFTP mean the account simply cannot write
/// to that directory, and sending the user to edit their password would be
/// actively misleading.
///
/// Everything below is a POSIX errno that SFTP and `dart:io` both surface.
/// Anything unrecognised keeps its own text rather than being flattened into
/// "algo salió mal": a specific unknown error still beats a vague known one.
library;

import '../l10n/l10n.dart';

/// The cause of [error], as one short phrase. Never ends in a period — callers
/// append it after "No se pudo eliminar: …".
String describeFileError(Object error) {
  final text = error.toString().toLowerCase();
  bool has(List<String> needles) => needles.any(text.contains);

  if (has(['permission denied', 'errno = 13', 'errno = 1'])) {
    return tr('no tienes permiso para escribir aquí');
  }
  if (has(['no such file', 'errno = 2'])) {
    return tr('ya no existe');
  }
  if (has(['file exists', 'errno = 17'])) {
    return tr('ya existe algo con ese nombre');
  }
  if (has(['directory not empty', 'errno = 39'])) {
    return tr('la carpeta no está vacía');
  }
  if (has(['no space left', 'errno = 28'])) {
    return tr('no queda espacio en el disco');
  }
  if (has(['read-only', 'errno = 30'])) {
    return tr('el sistema de archivos es de solo lectura');
  }
  if (has(['is a directory', 'errno = 21'])) {
    return tr('es una carpeta, no un archivo');
  }
  if (has(['not a directory', 'errno = 20'])) {
    return tr('no es una carpeta');
  }
  if (has(['too long', 'errno = 36'])) {
    return tr('el nombre es demasiado largo');
  }
  // The SFTP channel died — usually the SSH session went with it.
  if (has(['closed', 'not connected', 'broken pipe'])) {
    return tr('se perdió la conexión con el servidor');
  }
  return _trim(rawDetail(error));
}

/// The exception's own text, kept verbatim for a "ver detalle" disclosure.
String rawDetail(Object error) {
  var msg = error.toString();
  if (msg.startsWith('Exception: ')) msg = msg.substring(11);
  return msg.trim();
}

String _trim(String msg) =>
    msg.length > 120 ? '${msg.substring(0, 117)}…' : msg;
