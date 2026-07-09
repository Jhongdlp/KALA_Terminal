import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/app_lock.dart';
import '../theme/app_theme.dart';

/// Full-screen gate shown before the app shell when the app lock is enabled.
/// Prompts for biometric/device-credential auth on appear and on demand, and
/// only reveals the app once [AppState.markUnlocked] is set.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _authenticating = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // Kick off the prompt automatically after the first frame so the user
    // rarely has to tap the button.
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  Future<void> _authenticate() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _failed = false;
    });

    final ok = await AppLock.instance.authenticate();
    if (!mounted) return;

    if (ok) {
      context.read<AppState>().markUnlocked();
    } else {
      setState(() {
        _authenticating = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.hairline, width: 1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    _failed ? Icons.lock_outline : Icons.fingerprint,
                    size: 30,
                    color: _failed ? AppColors.danger : AppColors.bone,
                  ),
                ),
                const SizedBox(height: 24),
                Text('KALA', style: AppText.display(44, color: AppColors.bone)),
                const SizedBox(height: 10),
                Text(
                  _failed
                      ? 'AUTENTICACIÓN CANCELADA'
                      : 'APLICACIÓN BLOQUEADA',
                  style: AppText.label(9,
                      color: _failed ? AppColors.danger : AppColors.muted),
                ),
                const SizedBox(height: 4),
                Text(
                  'Usa tu huella o el bloqueo del teléfono para continuar.',
                  textAlign: TextAlign.center,
                  style: AppText.body(12, color: AppColors.faint),
                ),
                const SizedBox(height: 28),
                _UnlockButton(
                  authenticating: _authenticating,
                  onTap: _authenticate,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnlockButton extends StatelessWidget {
  final bool authenticating;
  final VoidCallback onTap;

  const _UnlockButton({required this.authenticating, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.bone,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: authenticating ? null : onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          alignment: Alignment.center,
          child: authenticating
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppColors.ink),
                  ),
                )
              : Text(
                  'DESBLOQUEAR',
                  style: AppText.label(11,
                      color: AppColors.ink, weight: FontWeight.w800),
                ),
        ),
      ),
    );
  }
}
