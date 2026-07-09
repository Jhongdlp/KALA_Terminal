import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'swiss.dart';

class MenuDrawer extends StatelessWidget {
  const MenuDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    // Listen to the session status so the drawer can show/hide remote actions
    final state = Provider.of<AppState>(context);
    final isRemote = state.connectionStatus == ConnectionStatus.remote;
    final activeProfileName = state.activeProfile?.name ?? 'SIN CONEXIÓN';

    return Drawer(
      backgroundColor: AppColors.ink,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drawer Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: Row(
                children: [
                  Icon(Icons.terminal_outlined, color: AppColors.accent, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    'KALA - MENÚ',
                    style: AppText.label(12, color: AppColors.bone, spacing: 1.5),
                  ),
                ],
              ),
            ),
            Hairline(),
            
            // Section 1: Server Management
            ListTile(
              enabled: isRemote,
              leading: Icon(
                Icons.dashboard_outlined, 
                color: isRemote ? AppColors.accent : AppColors.muted
              ),
              title: Text(
                'SERVIDORES (VPS)', 
                style: AppText.mono(11, color: isRemote ? AppColors.bone : AppColors.muted),
              ),
              subtitle: Text(
                isRemote ? 'Monitorizar $activeProfileName' : 'Requiere conexión SSH activa',
                style: AppText.body(9, color: AppColors.muted),
              ),
              onTap: isRemote ? () {
                Navigator.of(context).pop(); // Close drawer
                state.setActiveTabIndex(4); // Switch to VPS Tab
              } : null,
            ),
            Hairline(),

            // Section 2: App Settings
            ListTile(
              leading: Icon(Icons.tune, color: AppColors.bone),
              title: Text(
                'AJUSTES DE LA APP', 
                style: AppText.mono(11, color: AppColors.bone),
              ),
              subtitle: Text(
                'Temas, fuentes y llaves de seguridad',
                style: AppText.body(9, color: AppColors.muted),
              ),
              onTap: () {
                Navigator.of(context).pop(); // Close drawer
                state.setActiveTabIndex(5); // Switch to Settings Tab
              },
            ),
            Hairline(),

            const Spacer(),
            
            // Drawer Footer / Info
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'KALA TERMINAL v1.3.4',
                    style: AppText.mono(8, color: AppColors.muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Desarrollado para entornos móviles y Linux',
                    style: AppText.body(8, color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
