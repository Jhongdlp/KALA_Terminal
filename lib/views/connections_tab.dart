import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/connection_profile.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

class ConnectionsTab extends StatelessWidget {
  const ConnectionsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);

    return Container(
      color: AppColors.ink,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ScreenHeader(
            'Workspace',
            eyebrow: 'KALA',
            trailing: InvertedButton(
              label: 'Nueva',
              icon: Icons.add,
              dense: true,
              onPressed: () => _showProfileDialog(context, null),
            ),
          ),

          // SSH servers panel
          SwissPanel(
            title: 'Servidores remotos · SSH',
            children: [
              if (state.profiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 28),
                  child: Center(
                    child: Text('SIN SERVIDORES CONFIGURADOS',
                        style: AppText.mono(9,
                            color: AppColors.muted, spacing: 1.5)),
                  ),
                )
              else
                for (int i = 0; i < state.profiles.length; i++) ...[
                  if (i > 0) Hairline(),
                  _buildProfileRow(context, state, state.profiles[i]),
                ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProfileRow(
      BuildContext context, AppState state, ConnectionProfile profile) {
    final isConnected = state.connectionStatus == ConnectionStatus.remote &&
        state.activeProfile?.id == profile.id;

    return LayerRow(
      glyph: Icon(isConnected ? Icons.circle : Icons.circle_outlined),
      title: profile.name,
      meta: '${profile.username}@${profile.host}:${profile.port}',
      active: isConnected,
      trailing: const Icon(Icons.more_horiz),
      onTrailingTap: () =>
          _showProfileActions(context, state, profile, isConnected),
      onTap: () {
        if (isConnected) {
          _showProfileActions(context, state, profile, isConnected);
        } else {
          state.connectToSSH(profile);
        }
      },
    );
  }

  // ---- Action sheet (connect / edit / delete / disconnect) -----------------

  void _showProfileActions(BuildContext context, AppState state,
      ConnectionProfile profile, bool isConnected) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(profile.name.toUpperCase(),
                  style:
                      AppText.label(11, color: AppColors.bone, spacing: 1.4)),
            ),
            Hairline(),
            if (isConnected) ...[
              _actionTile(sheetCtx, Icons.bolt_outlined, 'IR A LA CONSOLA', () {
                state.setActiveTabIndex(1);
              }),
              Hairline(),
            ],
            _actionTile(sheetCtx, Icons.add_circle_outline, 'NUEVA SESIÓN', () {
              state.connectToSSH(profile);
            }),
            Hairline(),
            if (!isConnected) ...[
              _actionTile(sheetCtx, Icons.bolt_outlined, 'CONECTAR', () {
                state.connectToSSH(profile);
              }),
              Hairline(),
            ],
            _actionTile(sheetCtx, Icons.edit_outlined, 'EDITAR', () {
              _showProfileDialog(context, profile);
            }),
            if (isConnected) ...[
              Hairline(),
              _actionTile(sheetCtx, Icons.power_settings_new, 'DESCONECTAR',
                  () => state.disconnect()),
            ],
            Hairline(),
            _actionTile(sheetCtx, Icons.delete_outline, 'ELIMINAR', () {
              _showDeleteConfirmation(context, state, profile);
            }, danger: true),
          ],
        ),
      ),
    );
  }

  Widget _actionTile(
      BuildContext sheetCtx, IconData icon, String label, VoidCallback action,
      {bool danger = false}) {
    final fg = danger ? AppColors.danger : AppColors.bone;
    final sz = (16 * sheetCtx.read<AppState>().uiIconFactor).roundToDouble();
    return InkWell(
      onTap: () {
        Navigator.of(sheetCtx).pop();
        action();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: sz, color: fg),
            const SizedBox(width: 12),
            Text(label,
                style: AppText.label(10, color: fg, spacing: 1.0)),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirmation(
      BuildContext context, AppState state, ConnectionProfile profile) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text('ELIMINAR CONEXIÓN',
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: Text('¿Eliminar el perfil "${profile.name}"?',
            style: AppText.body(12, color: AppColors.muted)),
        actions: [
          GhostButton(
            label: 'Cancelar',
            dense: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
          GhostButton(
            label: 'Eliminar',
            dense: true,
            danger: true,
            onPressed: () {
              state.deleteProfile(profile.id);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  void _showProfileDialog(BuildContext context, ConnectionProfile? profile) {
    final isEditing = profile != null;
    final nameController = TextEditingController(text: profile?.name ?? '');
    final hostController = TextEditingController(text: profile?.host ?? '');
    final portController =
        TextEditingController(text: profile?.port.toString() ?? '22');
    final usernameController =
        TextEditingController(text: profile?.username ?? '');
    final passwordController =
        TextEditingController(text: profile?.password ?? '');
    final commandController = TextEditingController();
    final tunnelController = TextEditingController();
    final forwards = List<PortForward>.from(profile?.forwards ?? const []);
    var useTmux = profile?.useTmux ?? false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height -
            MediaQuery.of(context).padding.top -
            12,
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 18,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(isEditing ? 'EDITAR PERFIL SSH' : 'NUEVO PERFIL SSH',
                    style: AppText.label(10,
                        color: AppColors.bone, spacing: 1.6)),
                const SizedBox(height: 4),
                Hairline(),
                const SizedBox(height: 16),

                // ---- Paste full ssh command -> autofill ------------------
                Text('PEGAR COMANDO SSH',
                    style: AppText.label(9,
                        color: AppColors.muted, spacing: 1.4)),
                const SizedBox(height: 6),
                _field(commandController,
                    'ssh -L 3000:localhost:3000 usuario@host',
                    mono: true),
                const SizedBox(height: 8),
                GhostButton(
                  label: 'Autocompletar desde el comando',
                  icon: Icons.auto_fix_high,
                  dense: true,
                  onPressed: () {
                    final parsed =
                        ConnectionProfile.parseCommand(commandController.text);
                    if (parsed == null) {
                      ScaffoldMessenger.of(sheetCtx).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'No se pudo leer el comando. Verifica el formato.')),
                      );
                      return;
                    }
                    setSheetState(() {
                      hostController.text = parsed.host;
                      if (parsed.username != null) {
                        usernameController.text = parsed.username!;
                      }
                      portController.text = (parsed.port ?? 22).toString();
                      if (parsed.forwards.isNotEmpty) {
                        forwards
                          ..clear()
                          ..addAll(parsed.forwards);
                      }
                      if (nameController.text.isEmpty) {
                        nameController.text = parsed.host;
                      }
                    });
                  },
                ),
                const SizedBox(height: 16),
                Hairline(),
                const SizedBox(height: 16),

                _field(nameController, 'NOMBRE DEL PERFIL'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _field(hostController, 'HOST / IP', mono: true),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 1,
                      child: _field(portController, 'PUERTO',
                          mono: true, number: true),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _field(usernameController, 'USUARIO', mono: true),
                const SizedBox(height: 12),
                _field(passwordController, 'CONTRASEÑA (OPCIONAL)',
                    obscure: true),
                const SizedBox(height: 8),

                // ---- Persistent session (tmux) ---------------------------
                ToggleRow(
                  label: 'SESIÓN PERSISTENTE (TMUX)',
                  description:
                      'Los agentes y procesos siguen corriendo si se corta la '
                      'conexión; al reconectar vuelves donde estabas. Requiere '
                      'tmux en el servidor.',
                  value: useTmux,
                  onChanged: (v) => setSheetState(() => useTmux = v),
                ),
                const SizedBox(height: 8),

                // ---- Port-forward tunnels (-L) ---------------------------
                Text('TÚNELES · PORT FORWARDING (-L)',
                    style: AppText.label(9,
                        color: AppColors.muted, spacing: 1.4)),
                const SizedBox(height: 8),
                for (int i = 0; i < forwards.length; i++)
                  _tunnelRow(forwards[i], () {
                    setSheetState(() => forwards.removeAt(i));
                  }),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _field(
                          tunnelController, 'PUERTO:HOST:PUERTO (3000:localhost:3000)',
                          mono: true),
                    ),
                    const SizedBox(width: 8),
                    GhostButton(
                      label: 'Añadir',
                      icon: Icons.add,
                      dense: true,
                      onPressed: () {
                        final pf =
                            PortForward.parseSpec(tunnelController.text.trim());
                        if (pf == null) {
                          ScaffoldMessenger.of(sheetCtx).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Formato de túnel inválido. Usa puerto:host:puerto')),
                          );
                          return;
                        }
                        setSheetState(() {
                          forwards.add(pf);
                          tunnelController.clear();
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                InvertedButton(
                  label: isEditing ? 'Guardar cambios' : 'Conectar y guardar',
                  expand: true,
                  onPressed: () {
                    if (nameController.text.isEmpty ||
                        hostController.text.isEmpty ||
                        usernameController.text.isEmpty) {
                      ScaffoldMessenger.of(sheetCtx).showSnackBar(
                        const SnackBar(
                            content: Text('Completa los campos requeridos')),
                      );
                      return;
                    }

                    final newProfile = ConnectionProfile(
                      id: profile?.id ?? const Uuid().v4(),
                      name: nameController.text,
                      host: hostController.text,
                      port: int.tryParse(portController.text) ?? 22,
                      username: usernameController.text,
                      password: passwordController.text.isEmpty
                          ? null
                          : passwordController.text,
                      forwards: forwards,
                      useTmux: useTmux,
                    );

                    final state =
                        Provider.of<AppState>(sheetCtx, listen: false);
                    state.saveProfile(newProfile);
                    Navigator.of(sheetCtx).pop();

                    if (!isEditing) state.connectToSSH(newProfile);
                  },
                ),
                const SizedBox(height: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tunnelRow(PortForward fwd, VoidCallback onRemove) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.swap_horiz, size: 14, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'localhost:${fwd.bindPort}  →  ${fwd.remoteHost}:${fwd.remotePort}',
              style: AppText.mono(12, color: AppColors.bone),
            ),
          ),
          InkWell(
            onTap: onRemove,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 14, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController controller, String label,
      {bool mono = false, bool number = false, bool obscure = false}) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enableIMEPersonalizedLearning: !obscure,
      keyboardType: number ? TextInputType.number : null,
      decoration: InputDecoration(labelText: label),
      style: mono
          ? AppText.mono(13, color: AppColors.bone)
          : AppText.body(13, color: AppColors.bone),
    );
  }
}
