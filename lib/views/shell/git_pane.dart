import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';
import '../../theme/app_theme.dart';
import '../git_panel_sheet.dart';

/// Desktop mount of the Git panel.
///
/// [GitPanelSheet] is presentation-agnostic — it takes the state and a toast
/// callback and returns a column — so the only thing this adds is the wrapper
/// the compact layout gets from `_showGitSlider`: a private
/// [ScaffoldMessenger] so the panel's own SnackBars render in front of it
/// rather than behind, on the root Scaffold.
class GitPane extends StatelessWidget {
  const GitPane({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();

    return ScaffoldMessenger(
      child: Builder(
        builder: (messengerCtx) => Scaffold(
          backgroundColor: AppColors.panel,
          body: GitPanelSheet(
            state: state,
            onToast: (message) => _toast(messengerCtx, message),
          ),
        ),
      ),
    );
  }

  /// Mirrors `_TerminalTabState._toast` so a git action reads the same wherever
  /// the panel is mounted.
  void _toast(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message,
            style: AppText.mono(11, color: AppColors.bone, spacing: 0.3)),
        backgroundColor: AppColors.panelHi,
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }
}
