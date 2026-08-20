import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';
import 'shortcuts_help_sheet.dart';

/// A three-card introduction, shown once.
///
/// The app's best features are gestures, and a gesture nobody performs might as
/// well not exist: hold-and-drag arrows, pinch-to-resize, swipeable key layers,
/// agent notifications. This is the smallest thing that makes them findable —
/// three cards, skippable at any point, with a door into the full reference for
/// anyone who wants it.
///
/// Deliberately not a tour with overlays pinned to real widgets: those break the
/// moment the layout changes (and this app has two shells), and they block the
/// UI on the one screen a new user most wants to touch.
Future<void> showOnboarding(BuildContext context) {
  return showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    heightFactor: 0.85,
    maxWidth: 560,
    builder: (sheetCtx) => const _Onboarding(),
  );
}

/// Shows the introduction the first time the app runs, and never again.
///
/// Safe to call on every mount: the shell is remounted on a language change,
/// and the "seen" flag is written as soon as it is shown.
Future<void> maybeShowOnboarding(BuildContext context) async {
  final state = context.read<AppState>();
  if (state.onboardingSeen) return;
  await state.markOnboardingSeen();
  if (!context.mounted) return;
  await showOnboarding(context);
}

class _Card {
  final IconData icon;
  final String title;
  final String body;
  final List<String> bullets;

  const _Card(this.icon, this.title, this.body, this.bullets);
}

const List<_Card> _cards = [
  _Card(
    Icons.dns_outlined,
    'Tus servidores, en el bolsillo',
    'KAMMEL conecta por SSH y te da la terminal, los archivos por SFTP, un editor de código y un panel de Git del servidor. Todo sobre la misma conexión.',
    [
      'Guarda un servidor una vez y conéctate de un toque.',
      'Pega un comando ssh completo y se rellena solo.',
      'Prueba la conexión antes de guardarla.',
    ],
  ),
  _Card(
    Icons.touch_app_outlined,
    'Una terminal pensada para el dedo',
    'Escribir en un móvil es el cuello de botella, así que casi todo tiene un gesto.',
    [
      'Mantén pulsado y arrastra: el dedo se convierte en un joystick de flechas.',
      'Pellizca con dos dedos para cambiar el tamaño de la letra.',
      'Desliza sobre la barra de teclas para cambiar de capa: CTRL, NAV, FN…',
      'Busca en toda la salida con la lupa de la barra superior.',
    ],
  ),
  _Card(
    Icons.notifications_active_outlined,
    'Pensada para agentes de IA',
    'Si dejas a Claude Code (o cualquier TUI) trabajando y sales de la app, KAMMEL vigila la pantalla y te avisa.',
    [
      'Notificación cuando el agente termina o te hace una pregunta.',
      'Guarda prompts reutilizables con variables.',
      'Adjunta una foto o un documento: se sube al servidor y se pega su ruta.',
      'Con tmux activado, reconectar te devuelve donde estabas.',
    ],
  ),
];

class _Onboarding extends StatefulWidget {
  const _Onboarding();

  @override
  State<_Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<_Onboarding> {
  final PageController _pages = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  bool get _isLast => _index == _cards.length - 1;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
            child: Row(
              children: [
                Text('KAMMEL SSH',
                    style:
                        AppText.mono(10, color: AppColors.muted, spacing: 2)),
                const Spacer(),
                GhostButton(
                  label: _isLast ? tr('Cerrar') : tr('Saltar'),
                  dense: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pages,
              itemCount: _cards.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (ctx, i) => _card(_cards[i]),
            ),
          ),
          _dots(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              children: [
                InvertedButton(
                  label: _isLast ? tr('Empezar') : tr('Siguiente'),
                  expand: true,
                  onPressed: () {
                    if (_isLast) {
                      Navigator.of(context).pop();
                    } else {
                      _pages.nextPage(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut);
                    }
                  },
                ),
                const SizedBox(height: 8),
                GhostButton(
                  label: tr('Ver todos los atajos y gestos'),
                  icon: Icons.help_outline,
                  dense: true,
                  onPressed: () {
                    Navigator.of(context).pop();
                    showShortcutsHelpSheet(context);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(_Card card) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(card.icon, size: 34, color: AppColors.accent),
          const SizedBox(height: 18),
          Text(tr(card.title).toUpperCase(),
              style: AppText.label(13, color: AppColors.bone, spacing: 1.2)),
          const SizedBox(height: 10),
          Text(tr(card.body), style: AppText.body(13, color: AppColors.muted)),
          const SizedBox(height: 18),
          for (final bullet in card.bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5, right: 10),
                    child: Container(
                        width: 5, height: 5, color: AppColors.accent),
                  ),
                  Expanded(
                    child: Text(tr(bullet),
                        style: AppText.body(12, color: AppColors.bone)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _dots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < _cards.length; i++)
          Container(
            width: i == _index ? 18 : 6,
            height: 3,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            color: i == _index ? AppColors.accent : AppColors.hairline,
          ),
      ],
    );
  }
}
