import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/known_hosts.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

/// Asks the user to accept a server's identity.
///
/// Two very different situations share this sheet on purpose, but they do *not*
/// look alike: a first connection is routine (accept and pin), while a changed
/// key is a potential impersonation and defaults to "cancel".
Future<bool> showHostKeyDialog(
    BuildContext context, HostKeyChallenge challenge) async {
  final changed = challenge.verdict == HostKeyVerdict.mismatch;

  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.panel,
      title: Row(
        children: [
          Icon(changed ? Icons.gpp_maybe : Icons.verified_user_outlined,
              size: 18, color: changed ? AppColors.danger : AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              changed
                  ? 'LA IDENTIDAD DEL SERVIDOR CAMBIÓ'
                  : 'PRIMERA CONEXIÓN CON ESTE SERVIDOR',
              style: AppText.label(11,
                  color: changed ? AppColors.danger : AppColors.bone,
                  spacing: 1.2),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              changed
                  ? 'La huella de ${challenge.host}:${challenge.port} no es la '
                      'que guardamos. Puede que hayan reinstalado el servidor… '
                      'o que alguien se esté haciendo pasar por él para robar '
                      'tu contraseña y todo lo que pase por los túneles.'
                  : 'Nunca te habías conectado a ${challenge.host}:'
                      '${challenge.port}. Comprueba que esta huella coincide '
                      'con la del servidor antes de aceptar.',
              style: AppText.body(12, color: AppColors.muted),
            ),
            const SizedBox(height: 14),
            _FingerprintBlock(
              label: changed ? 'HUELLA RECIBIDA AHORA' : 'HUELLA DEL SERVIDOR',
              value: challenge.fingerprint,
              keyType: challenge.keyType,
              danger: changed,
            ),
            if (changed && challenge.previousFingerprint != null) ...[
              const SizedBox(height: 10),
              _FingerprintBlock(
                label: 'HUELLA GUARDADA'
                    '${challenge.previousAddedAt != null ? ' · ${_date(challenge.previousAddedAt!)}' : ''}',
                value: challenge.previousFingerprint!,
                keyType: null,
                danger: false,
              ),
            ],
            const SizedBox(height: 14),
            Text(
              changed
                  ? 'Si no reinstalaste el servidor tú, cancela y averigua qué '
                      'pasó antes de volver a conectarte.'
                  : 'En el servidor puedes verla con:\n'
                      'ssh-keygen -lf /etc/ssh/ssh_host_${challenge.keyType.replaceAll('ssh-', '')}_key.pub',
              style: AppText.mono(10, color: AppColors.faint),
            ),
          ],
        ),
      ),
      actions: [
        GhostButton(
          label: 'Cancelar',
          dense: true,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        GhostButton(
          label: changed ? 'Aceptar el cambio' : 'Confiar y guardar',
          dense: true,
          danger: changed,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );

  return accepted ?? false;
}

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

class _FingerprintBlock extends StatelessWidget {
  final String label;
  final String value;
  final String? keyType;
  final bool danger;

  const _FingerprintBlock({
    required this.label,
    required this.value,
    required this.keyType,
    required this.danger,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.bone;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.ink,
        border: Border.all(color: danger ? AppColors.danger : AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: AppText.label(8,
                        color: AppColors.muted, spacing: 1.2)),
              ),
              if (keyType != null) MonoTag(keyType!),
              InkWell(
                onTap: () => Clipboard.setData(ClipboardData(text: value)),
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.copy, size: 13, color: AppColors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(value, style: AppText.mono(11, color: color)),
        ],
      ),
    );
  }
}
