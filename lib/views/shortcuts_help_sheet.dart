import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/swiss.dart';
import 'shell/app_commands.dart';

/// The reference for everything the app can do that isn't a button.
///
/// KAMMEL is full of gestures that are genuinely good and completely invisible:
/// hold-and-drag for the arrow joystick, pinch to resize the font, swipe to
/// change quick-key layer, long-press to move the explorer dock, double-tap to
/// rename a session. Until now none of them were written down anywhere, so a
/// user could only find them by accident — which mostly means never.
///
/// Reachable from the terminal's "más" menu, from Ajustes, from the command
/// palette and with Ctrl+Shift+I, and shown once on first run.
void showShortcutsHelpSheet(BuildContext context) {
  showAdaptiveSheet(
    context,
    backgroundColor: AppColors.panel,
    isScrollControlled: true,
    heightFactor: 0.92,
    maxWidth: 620,
    builder: (sheetCtx) => const ShortcutsHelpView(),
  );
}

/// One entry in the gesture reference.
class _Gesture {
  final IconData icon;

  /// Spanish source strings, translated at draw time.
  final String action;
  final String result;

  const _Gesture(this.icon, this.action, this.result);
}

const List<_Gesture> _terminalGestures = [
  _Gesture(Icons.touch_app_outlined, 'Un toque',
      'Enfoca la terminal y abre el teclado del sistema.'),
  _Gesture(Icons.swipe_vertical, 'Deslizar arriba/abajo',
      'Recorre el historial de salida. Dentro de tmux o un TUI, envía la rueda a la aplicación.'),
  _Gesture(Icons.gamepad_outlined, 'Mantener pulsado y arrastrar',
      'Convierte el dedo en un joystick de flechas: cuanto más lejos arrastras, más rápido se repite la tecla.'),
  _Gesture(Icons.blur_circular, 'Mantener pulsado, mover un poco y esperar',
      'Abre el menú radial del pad: ocho accesos rápidos alrededor del dedo. Arrastra a uno y suelta; en el centro se cancela.'),
  _Gesture(Icons.text_fields, 'Mantener pulsado sin mover',
      'Selecciona la palabra y muestra los tiradores para ampliar la selección.'),
  _Gesture(Icons.pinch_outlined, 'Pellizcar con dos dedos',
      'Cambia el tamaño de la letra de la terminal.'),
  _Gesture(Icons.keyboard_double_arrow_down, 'Botón flotante ↓',
      'Aparece al subir por el historial: vuelve al prompt de un toque.'),
];

const List<_Gesture> _quickKeyGestures = [
  _Gesture(Icons.swipe, 'Deslizar sobre las teclas rápidas',
      'Cambia de capa (CTRL, NAV, FN, ACCIONES, MIS).'),
  _Gesture(Icons.tab, 'Tocar una pestaña de la barra',
      'Salta directamente a esa capa. El engranaje abre el gestor de atajos.'),
  _Gesture(Icons.north_east, 'Deslizar sobre una flecha',
      'Envía la dirección del deslizamiento sin levantar el dedo.'),
];

const List<_Gesture> _otherGestures = [
  _Gesture(Icons.drag_indicator, 'Mantener pulsado el dock del explorador',
      'Lo arrastra a otra altura o al lado contrario de la pantalla.'),
  _Gesture(Icons.edit_outlined, 'Doble toque en la sesión activa',
      'Renombra la sesión.'),
  _Gesture(Icons.folder_open, 'Mantener pulsado un archivo en Git',
      'Lo abre en el explorador y el editor en vez de mostrar su diff.'),
  _Gesture(Icons.arrow_back, 'Gesto de atrás',
      'Retrocede dentro de la app (cierra el archivo, quita la selección…). Dos veces seguidas sale.'),
];

/// The body of the help sheet, extracted so the onboarding can embed it.
class ShortcutsHelpView extends StatelessWidget {
  const ShortcutsHelpView({super.key});

  @override
  Widget build(BuildContext context) {
    final commands = appCommands().where((c) => c.activator != null).toList();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('ATAJOS Y GESTOS'),
                    style: AppText.label(11,
                        color: AppColors.bone, spacing: 1.4)),
                const SizedBox(height: 8),
                Text(
                  tr('Casi todo lo que hace KAMMEL rápido está aquí. Puedes volver a esta pantalla desde el menú de la terminal o con Ctrl+Shift+I.'),
                  style: AppText.body(12, color: AppColors.muted),
                ),
              ],
            ),
          ),

          _gestureSection(tr('En la terminal'), _terminalGestures),
          _gestureSection(tr('Teclas rápidas'), _quickKeyGestures),
          _gestureSection(tr('En el resto de la app'), _otherGestures),

          // Keyboard shortcuts. Shown on every platform: an Android tablet with
          // a keyboard case is exactly the setup that benefits most, and hiding
          // them behind a platform check would make them undiscoverable there.
          for (final section in CommandSection.values)
            _shortcutSection(
              section,
              commands.where((c) => c.section == section).toList(),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              tr('Los atajos usan Ctrl+Shift porque Ctrl solo pertenece al shell: Ctrl+C, Ctrl+W y compañía tienen que llegar intactos al servidor.'),
              style: AppText.body(11, color: AppColors.faint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _gestureSection(String title, List<_Gesture> gestures) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SwissPanel(
        title: title,
        children: [
          for (int i = 0; i < gestures.length; i++) ...[
            if (i > 0) Hairline(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(gestures[i].icon, size: 16, color: AppColors.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr(gestures[i].action),
                            style: AppText.body(12,
                                color: AppColors.bone,
                                weight: FontWeight.w700)),
                        const SizedBox(height: 3),
                        Text(tr(gestures[i].result),
                            style: AppText.body(11, color: AppColors.muted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _shortcutSection(CommandSection section, List<AppCommand> commands) {
    if (commands.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SwissPanel(
        title: tr('Teclado · {0}', [section.label]),
        children: [
          for (int i = 0; i < commands.length; i++) ...[
            if (i > 0) Hairline(),
            _shortcutRow(tr(commands[i].label),
                describeActivator(commands[i].activator!)),
          ],
          if (section == CommandSection.sessions) ...[
            Hairline(),
            _shortcutRow(tr('Ir a la sesión 1…9'), 'Alt+1…9'),
          ],
        ],
      ),
    );
  }

  Widget _shortcutRow(String label, String keys) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: AppText.body(12, color: AppColors.bone)),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration:
                BoxDecoration(border: Border.all(color: AppColors.hairline)),
            child: Text(keys,
                style: AppText.mono(10, color: AppColors.muted, spacing: 0.5)),
          ),
        ],
      ),
    );
  }
}
