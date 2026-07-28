import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/server_controller.dart';
import '../theme/app_theme.dart';
import 'swiss.dart';

class MenuDrawer extends StatelessWidget {
  const MenuDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);

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
                    'KAMMEL SSH - MENÚ',
                    style: AppText.label(12, color: AppColors.bone, spacing: 1.5),
                  ),
                ],
              ),
            ),
            Hairline(),
            
            // Section 1: Server console (monitor + Docker). Always enabled —
            // the console picks its own server and opens a dedicated SSH
            // client, like a cloud-provider console.
            ListTile(
              leading: Icon(Icons.dns_outlined, color: AppColors.accent),
              title: Text(
                'SERVIDOR',
                style: AppText.mono(11, color: AppColors.bone),
              ),
              subtitle: Text(
                'Monitor, Docker y auditoría por SSH',
                style: AppText.body(9, color: AppColors.muted),
              ),
              onTap: () {
                Navigator.of(context).pop(); // Close drawer
                state.setActiveTabIndex(4); // Switch to Server console
              },
            ),
            Hairline(),

            // Section 1b: Database viewer. Lands in the server picker (same
            // as SERVIDOR) when no server is connected yet, but opens
            // straight into the BASE DE DATOS section once connected instead
            // of the default monitor view.
            ListTile(
              leading: Icon(Icons.storage_rounded, color: AppColors.accent),
              title: Text(
                'BASE DE DATOS',
                style: AppText.mono(11, color: AppColors.bone),
              ),
              subtitle: Text(
                'Explora tablas y relaciones por SSH',
                style: AppText.body(9, color: AppColors.muted),
              ),
              onTap: () {
                Navigator.of(context).pop(); // Close drawer
                final server = state.server;
                if (server.phase == ServerPhase.ready) {
                  server.setSection(ServerSection.database);
                } else {
                  server.landingSection = ServerSection.database;
                }
                state.setActiveTabIndex(4); // Switch to Server console
              },
            ),
            Hairline(),

            // Section 2: General settings
            ListTile(
              leading: Icon(Icons.tune, color: AppColors.bone),
              title: Text(
                'AJUSTES GENERALES', 
                style: AppText.mono(11, color: AppColors.bone),
              ),
              subtitle: Text(
                'Seguridad, explorador y llaves',
                style: AppText.body(9, color: AppColors.muted),
              ),
              onTap: () {
                Navigator.of(context).pop(); // Close drawer
                state.setActiveTabIndex(5); // Switch to Settings Tab
              },
            ),
            Hairline(),

            // Section 3: Personalization
            ListTile(
              leading: Icon(Icons.palette_outlined, color: AppColors.accent),
              title: Text(
                'PERSONALIZACIÓN', 
                style: AppText.mono(11, color: AppColors.bone),
              ),
              subtitle: Text(
                'Temas, colores y fuentes',
                style: AppText.body(9, color: AppColors.muted),
              ),
              onTap: () {
                Navigator.of(context).pop(); // Close drawer
                state.setActiveTabIndex(6); // Switch to Personalization Tab
              },
            ),
            Hairline(),

            // Section 4: About
            ListTile(
              leading: Icon(Icons.info_outline, color: AppColors.bone),
              title: Text(
                'ACERCA DE LA APP', 
                style: AppText.mono(11, color: AppColors.bone),
              ),
              subtitle: Text(
                'Información, versión y actualizaciones',
                style: AppText.body(9, color: AppColors.muted),
              ),
              onTap: () {
                Navigator.of(context).pop(); // Close drawer
                state.setActiveTabIndex(7); // Switch to About Tab
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
                  FutureBuilder<PackageInfo>(
                    future: PackageInfo.fromPlatform(),
                    builder: (context, snapshot) {
                      final info = snapshot.data;
                      final version = info != null ? '${info.version}+${info.buildNumber}' : '…';
                      return Text(
                        'KAMMEL SSH v$version',
                        style: AppText.mono(8, color: AppColors.muted),
                      );
                    },
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
