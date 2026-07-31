import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

/// Wraps [LocalAuthentication] for the optional app lock. The lock uses the
/// device biometric (fingerprint/face) as the primary factor and falls back to
/// the phone's own screen-lock credential (PIN/pattern/password) — there is no
/// KAMMEL-specific PIN, so nothing secret is stored by this layer.
class AppLock {
  AppLock._();
  static final AppLock instance = AppLock._();

  static final LocalAuthentication _auth = LocalAuthentication();

  /// Whether the device can authenticate at all — either enrolled biometrics or
  /// a configured screen lock. Used to stop the settings toggle from arming a
  /// lock the phone could never satisfy (which would strand the user).
  Future<bool> isSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  /// Prompts for biometric/device-credential auth. Returns true only on a
  /// successful unlock; false on cancel, lockout, or any error.
  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Desbloquea KAMMEL SSH para continuar',
        options: const AuthenticationOptions(
          // Allow the phone's PIN/pattern/password as a fallback, not just
          // biometrics.
          biometricOnly: false,
          // Keep the prompt up if the app is briefly backgrounded (e.g. the
          // system biometric UI), instead of erroring out.
          stickyAuth: true,
        ),
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: 'Desbloquear KAMMEL SSH',
            biometricHint: '',
            cancelButton: 'Cancelar',
            deviceCredentialsRequiredTitle: 'Bloqueo no configurado',
            deviceCredentialsSetupDescription:
                'Configura un bloqueo de pantalla en tu teléfono para usar '
                'esta función.',
            goToSettingsButton: 'Ajustes',
            goToSettingsDescription:
                'Configura huella o un bloqueo de pantalla en los ajustes del '
                'teléfono.',
          ),
        ],
      );
    } on PlatformException {
      return false;
    }
  }
}
