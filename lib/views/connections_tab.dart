import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ssh_config_import.dart';
import 'package:uuid/uuid.dart';
import '../models/connection_group.dart';
import '../models/connection_profile.dart';
import '../models/jump_chain.dart';
import '../models/ssh_tunnel.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_sheet.dart';
import '../widgets/profile_tint.dart';
import '../widgets/swiss.dart';
import '../widgets/tap_target.dart';
import 'backup_sheet.dart';
import 'tunnel_editor_sheet.dart';
import '../l10n/format.dart';
import '../l10n/l10n.dart';

/// The connections screen: the app's front door.
///
/// It is a flat list of profiles until there are enough of them that a flat
/// list stops working, and then it grows exactly three affordances, in the
/// order a user runs out of road:
///
///  1. **Recientes** — the top of the screen is the most valuable real estate,
///     and "the box I was on ten minutes ago" is the overwhelmingly common
///     target. Only shown once there are more profiles than fit a glance.
///  2. **Favoritos** — an explicit pin for the two or three that matter,
///     because "recent" churns when you're bouncing between machines.
///  3. **Grupos** — folders, for the point where even the pinned list is long.
///     [ConnectionGroup] has been in the model all along with no UI on it.
///
/// The search field appears at the same threshold as Recientes: below it,
/// searching a list you can already see is pure chrome.
class ConnectionsTab extends StatefulWidget {
  const ConnectionsTab({super.key});

  @override
  State<ConnectionsTab> createState() => _ConnectionsTabState();
}

class _ConnectionsTabState extends State<ConnectionsTab> {
  /// Profile count from which the screen starts organising itself.
  static const int _organiseThreshold = 5;

  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// Groups the user has folded shut. Deliberately *not* persisted: a collapsed
  /// folder is a way of getting a long list out of the way right now, and a
  /// group that stays shut across restarts is how a profile gets lost.
  final Set<String> _collapsed = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final profiles = state.profiles;
    final organise = profiles.length >= _organiseThreshold;
    final searching = _query.trim().isNotEmpty;
    final matches = _filter(profiles);

    return ContentColumn(
      color: AppColors.ink,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ScreenHeader(
            tr('Workspace'),
            eyebrow: 'KAMMEL SSH',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconTapTarget(
                  icon: Icons.more_horiz,
                  label: tr('Más opciones'),
                  color: AppColors.muted,
                  onTap: () => _showOverflow(context, state),
                ),
                const SizedBox(width: 4),
                InvertedButton(
                  label: tr('Nueva'),
                  icon: Icons.add,
                  dense: true,
                  onPressed: () => _showProfileDialog(context, null),
                ),
              ],
            ),
          ),

          if (organise) _searchField(),

          if (profiles.isEmpty)
            _emptyState(context, state)
          else if (searching)
            SwissPanel(
              title: tr('{0} RESULTADO(S)', [matches.length]),
              children: [
                if (matches.isEmpty)
                  _hint(tr('Ningún servidor coincide con «{0}».', [_query]))
                else
                  for (int i = 0; i < matches.length; i++) ...[
                    if (i > 0) Hairline(),
                    _buildProfileRow(context, state, matches[i]),
                  ],
              ],
            )
          else
            ..._organisedPanels(context, state, organise),
        ],
      ),
    );
  }

  // ---- Sections --------------------------------------------------------------

  List<Widget> _organisedPanels(
      BuildContext context, AppState state, bool organise) {
    final profiles = state.profiles;
    final favorites =
        profiles.where((p) => state.isFavoriteProfile(p.id)).toList();
    final recents = organise ? state.recentProfiles() : const <ConnectionProfile>[];
    final panels = <Widget>[];

    if (recents.isNotEmpty) {
      panels.add(SwissPanel(
        title: tr('Recientes'),
        children: [
          for (int i = 0; i < recents.length; i++) ...[
            if (i > 0) Hairline(),
            _buildProfileRow(context, state, recents[i], showLastUsed: true),
          ],
        ],
      ));
      panels.add(const SizedBox(height: 12));
    }

    if (favorites.isNotEmpty) {
      panels.add(SwissPanel(
        title: tr('Favoritos'),
        children: [
          for (int i = 0; i < favorites.length; i++) ...[
            if (i > 0) Hairline(),
            _buildProfileRow(context, state, favorites[i]),
          ],
        ],
      ));
      panels.add(const SizedBox(height: 12));
    }

    for (final group in state.groups) {
      final members = profiles.where((p) => p.groupId == group.id).toList();
      final folded = _collapsed.contains(group.id);
      panels.add(SwissPanel(
        title: group.name,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${members.length}',
                style: AppText.mono(9, color: AppColors.muted)),
            const SizedBox(width: 6),
            IconTapTarget(
              icon: folded ? Icons.expand_more : Icons.expand_less,
              label: folded ? tr('Desplegar grupo') : tr('Plegar grupo'),
              size: 15,
              min: 30,
              color: AppColors.muted,
              onTap: () => setState(() =>
                  folded ? _collapsed.remove(group.id) : _collapsed.add(group.id)),
            ),
            IconTapTarget(
              icon: Icons.more_horiz,
              label: tr('Opciones del grupo'),
              size: 15,
              min: 30,
              color: AppColors.muted,
              onTap: () => _showGroupActions(context, state, group),
            ),
          ],
        ),
        children: [
          if (folded)
            const SizedBox.shrink()
          else if (members.isEmpty)
            _hint(tr('Grupo vacío. Mueve servidores aquí desde sus opciones.'))
          else
            for (int i = 0; i < members.length; i++) ...[
              if (i > 0) Hairline(),
              _buildProfileRow(context, state, members[i]),
            ],
        ],
      ));
      panels.add(const SizedBox(height: 12));
    }

    // Everything not in a group. Titled "servidores remotos" when there are no
    // groups at all, so a user who never made one sees the screen they always
    // saw rather than a bucket called "sin grupo".
    final loose = profiles
        .where((p) =>
            p.groupId == null ||
            !state.groups.any((g) => g.id == p.groupId))
        .toList();
    panels.add(SwissPanel(
      title: state.groups.isEmpty
          ? tr('Servidores remotos · SSH')
          : tr('Sin grupo'),
      children: [
        if (loose.isEmpty)
          _hint(tr('Todos tus servidores están en grupos.'))
        else
          for (int i = 0; i < loose.length; i++) ...[
            if (i > 0) Hairline(),
            _buildProfileRow(context, state, loose[i]),
          ],
      ],
    ));

    return panels;
  }

  List<ConnectionProfile> _filter(List<ConnectionProfile> profiles) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return profiles;
    return profiles.where((p) {
      return p.name.toLowerCase().contains(q) ||
          p.host.toLowerCase().contains(q) ||
          p.username.toLowerCase().contains(q) ||
          '${p.username}@${p.host}'.toLowerCase().contains(q);
    }).toList();
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.panel,
          border: Border.all(color: AppColors.hairline, width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(Icons.search, size: 15, color: AppColors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v),
                style: AppText.mono(12, color: AppColors.bone),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: tr('Buscar servidor, host o usuario…'),
                  hintStyle: AppText.body(12, color: AppColors.faint),
                ),
              ),
            ),
            if (_query.isNotEmpty)
              IconTapTarget(
                icon: Icons.close,
                label: tr('Limpiar búsqueda'),
                size: 15,
                min: 34,
                color: AppColors.muted,
                onTap: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
        child: Text(text,
            style: AppText.body(11, color: AppColors.muted),
            textAlign: TextAlign.center),
      );

  /// First run. The old empty state was a 9px label and nothing else; this one
  /// says what the app is for and offers both ways in — a fresh profile, or a
  /// backup from the phone the user just replaced.
  Widget _emptyState(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.panel,
          border: Border.all(color: AppColors.hairline, width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
        child: Column(
          children: [
            Icon(Icons.dns_outlined, size: 34, color: AppColors.muted),
            const SizedBox(height: 16),
            Text(tr('AÚN NO HAY SERVIDORES'),
                style:
                    AppText.label(10, color: AppColors.bone, spacing: 1.6)),
            const SizedBox(height: 10),
            Text(
              tr('Añade un servidor SSH para abrir su terminal, explorar sus archivos y editarlos desde aquí.'),
              textAlign: TextAlign.center,
              style: AppText.body(12, color: AppColors.muted),
            ),
            const SizedBox(height: 20),
            InvertedButton(
              label: tr('Crear la primera conexión'),
              icon: Icons.add,
              expand: true,
              onPressed: () => _showProfileDialog(context, null),
            ),
            const SizedBox(height: 10),
            GhostButton(
              label: tr('Restaurar una copia'),
              icon: Icons.download_outlined,
              dense: true,
              onPressed: () => showBackupSheet(context),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Rows ------------------------------------------------------------------

  Widget _buildProfileRow(
      BuildContext context, AppState state, ConnectionProfile profile,
      {bool showLastUsed = false}) {
    final isConnected = state.sessions.any((s) =>
        s.activeProfile?.id == profile.id &&
        s.connectionStatus == ConnectionStatus.remote);
    final favorite = state.isFavoriteProfile(profile.id);
    final lastUsed = state.lastConnectedAt(profile.id);

    var meta = '${profile.username}@${profile.host}:${profile.port}';
    final via = JumpChain.describe(profile, state.profiles);
    if (via != null) meta = '$meta · ${tr('vía {0}', [via])}';
    if (showLastUsed && lastUsed != null) {
      meta = '$meta · ${relativeTime(lastUsed)}';
    }

    // A chain that can no longer be walked (the bastion was deleted from a
    // restored backup, say) is worth saying *here*: the alternative is finding
    // out at connect time, which is exactly when it is most expensive.
    final chainError = JumpChain.validate(profile, state.profiles);
    final tint = profileTint(profile);

    return LayerRow(
      glyph: Icon(isConnected ? Icons.circle : Icons.circle_outlined),
      title: profile.name,
      meta: meta,
      active: isConnected,
      tint: tint,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (chainError != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: chainError.message,
                child: Icon(Icons.link_off,
                    size: 13,
                    color: isConnected ? AppColors.ink : AppColors.danger),
              ),
            ),
          if (profile.isProduction)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ProdBadge(tint: tint),
            ),
          if (favorite)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(Icons.star,
                  size: 13,
                  color: isConnected ? AppColors.ink : AppColors.accent),
            ),
          const Icon(Icons.more_horiz),
        ],
      ),
      onTrailingTap: () =>
          _showProfileActions(context, state, profile, isConnected),
      // A long press is the fast path to the same menu, so the small trailing
      // hit area is never the only way to reach it.
      onLongPress: () =>
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

  // ---- Action sheets ---------------------------------------------------------

  void _showOverflow(BuildContext context, AppState state) {
    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      maxWidth: 460,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sheetTitle(tr('WORKSPACE')),
            Hairline(),
            _actionTile(sheetCtx, Icons.create_new_folder_outlined,
                tr('NUEVO GRUPO'), () => _showGroupDialog(context, null)),
            Hairline(),
            _actionTile(sheetCtx, Icons.terminal, tr('IMPORTAR DE ~/.SSH/CONFIG'),
                () => _importSshConfig(context)),
            Hairline(),
            _actionTile(sheetCtx, Icons.backup_outlined,
                tr('COPIA DE SEGURIDAD'), () => showBackupSheet(context)),
          ],
        ),
      ),
    );
  }

  void _showProfileActions(BuildContext context, AppState state,
      ConnectionProfile profile, bool isConnected) {
    final favorite = state.isFavoriteProfile(profile.id);

    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      maxWidth: 460,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetTitle(profile.name.toUpperCase()),
              Hairline(),
              if (isConnected) ...[
                _actionTile(sheetCtx, Icons.bolt_outlined, tr('IR A LA CONSOLA'),
                    () => state.setActiveTabIndex(1)),
                Hairline(),
              ],
              _actionTile(sheetCtx, Icons.add_circle_outline, tr('NUEVA SESIÓN'),
                  () => state.connectToSSH(profile)),
              Hairline(),
              if (!isConnected) ...[
                _actionTile(sheetCtx, Icons.bolt_outlined, tr('CONECTAR'),
                    () => state.connectToSSH(profile)),
                Hairline(),
              ],
              _actionTile(
                  sheetCtx,
                  favorite ? Icons.star : Icons.star_border,
                  favorite ? tr('QUITAR DE FAVORITOS') : tr('AÑADIR A FAVORITOS'),
                  () => state.toggleFavoriteProfile(profile.id)),
              Hairline(),
              _actionTile(sheetCtx, Icons.folder_outlined, tr('MOVER A GRUPO…'),
                  () => _showGroupPicker(context, state, profile)),
              Hairline(),
              _actionTile(sheetCtx, Icons.edit_outlined, tr('EDITAR'),
                  () => _showProfileDialog(context, profile)),
              Hairline(),
              _actionTile(sheetCtx, Icons.copy_all_outlined, tr('DUPLICAR'),
                  () => _duplicate(context, state, profile)),
              if (isConnected) ...[
                Hairline(),
                _actionTile(sheetCtx, Icons.power_settings_new,
                    tr('DESCONECTAR'), () => state.disconnect()),
              ],
              Hairline(),
              _actionTile(sheetCtx, Icons.delete_outline, tr('ELIMINAR'), () {
                _showDeleteConfirmation(context, state, profile);
              }, danger: true),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _duplicate(
      BuildContext context, AppState state, ConnectionProfile profile) async {
    final copy = await state.duplicateProfile(profile);
    if (!context.mounted) return;
    // Straight into the editor: a duplicate always needs at least one field
    // changed, and that field is why the user duplicated it.
    _showProfileDialog(context, copy);
  }


  // ---- ~/.ssh/config --------------------------------------------------------

  /// Offers the hosts found in an OpenSSH config and imports the chosen ones.
  ///
  /// Anyone already using SSH from a laptop has that file; retyping thirty
  /// hosts into a phone form is what stops them from getting as far as trying
  /// the app.
  Future<void> _importSshConfig(BuildContext context) async {
    final state = context.read<AppState>();
    var hosts = await SshConfigImport.readDefault();
    if (!context.mounted) return;
    // No readable ~/.ssh/config (always the case on Android): let them pick it.
    hosts ??= await SshConfigImport.pickAndParse();
    if (!context.mounted || hosts == null) return;

    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('No se encontró ningún host utilizable en ese archivo.'))));
      return;
    }

    // Everything selected by default: the user opened this to import.
    final chosen = hosts.map((h) => h.alias).toSet();

    final confirmed = await showAdaptiveSheet<bool>(
      context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      maxWidth: 520,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetTitle(tr('IMPORTAR DE ~/.SSH/CONFIG')),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                    tr('Se crearán perfiles sin contraseña. Los que usen una llave quedarán marcados para usar la llave del dispositivo. Si un host salta por otro, ese otro se importa también.'),
                    style: AppText.body(11, color: AppColors.muted)),
              ),
              Hairline(),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: hosts!.length,
                  separatorBuilder: (_, _) => Hairline(),
                  itemBuilder: (ctx, i) {
                    final host = hosts![i];
                    final on = chosen.contains(host.alias);
                    return InkWell(
                      onTap: () => setSheetState(() =>
                          on ? chosen.remove(host.alias) : chosen.add(host.alias)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Icon(on ? Icons.check_box : Icons.check_box_outline_blank,
                                size: 16,
                                color: on ? AppColors.accent : AppColors.hairline),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(host.alias,
                                      style: AppText.body(12,
                                          color: AppColors.bone,
                                          weight: FontWeight.w700)),
                                  const SizedBox(height: 2),
                                  Text(
                                      host.proxyJump == null
                                          ? '${host.user ?? '?'}@${host.hostName}:${host.port}'
                                          : '${host.user ?? '?'}@${host.hostName}:${host.port}  ·  ${tr('vía {0}', [host.proxyJump!])}',
                                      style: AppText.mono(10,
                                          color: AppColors.muted)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Hairline(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: InvertedButton(
                  label: tr('Importar {0} servidor(es)', [chosen.length]),
                  expand: true,
                  onPressed: chosen.isEmpty
                      ? null
                      : () => Navigator.of(sheetCtx).pop(true),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true) return;
    // toProfiles wires the ProxyJump chains and pulls in any bastion a chosen
    // host needs, so the count can be larger than the ticks.
    final profiles = SshConfigImport.toProfiles(hosts, chosen);
    for (final profile in profiles) {
      await state.saveProfile(profile);
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Importados {0} servidor(es)', [profiles.length]))));
  }

  // ---- Groups ----------------------------------------------------------------

  void _showGroupPicker(
      BuildContext context, AppState state, ConnectionProfile profile) {
    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      maxWidth: 460,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetTitle(tr('MOVER A GRUPO')),
              Hairline(),
              _actionTile(sheetCtx, Icons.layers_clear_outlined,
                  tr('SIN GRUPO'), () => state.setProfileGroup(profile.id, null),
                  selected: profile.groupId == null),
              for (final group in state.groups) ...[
                Hairline(),
                _actionTile(sheetCtx, Icons.folder_outlined,
                    group.name.toUpperCase(),
                    () => state.setProfileGroup(profile.id, group.id),
                    selected: profile.groupId == group.id),
              ],
              Hairline(),
              _actionTile(sheetCtx, Icons.create_new_folder_outlined,
                  tr('NUEVO GRUPO…'), () async {
                final created = await _showGroupDialog(context, null);
                if (created != null) {
                  await state.setProfileGroup(profile.id, created.id);
                }
              }),
            ],
          ),
        ),
      ),
    );
  }

  void _showGroupActions(
      BuildContext context, AppState state, ConnectionGroup group) {
    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      maxWidth: 460,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sheetTitle(group.name.toUpperCase()),
            Hairline(),
            _actionTile(sheetCtx, Icons.edit_outlined, tr('RENOMBRAR'),
                () => _showGroupDialog(context, group)),
            Hairline(),
            _actionTile(sheetCtx, Icons.folder_delete_outlined,
                tr('ELIMINAR GRUPO'), () => _confirmDeleteGroup(context, state, group),
                danger: true),
          ],
        ),
      ),
    );
  }

  Future<ConnectionGroup?> _showGroupDialog(
      BuildContext context, ConnectionGroup? group) async {
    final controller = TextEditingController(text: group?.name ?? '');
    final state = Provider.of<AppState>(context, listen: false);

    return showDialog<ConnectionGroup>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(group == null ? tr('NUEVO GRUPO') : tr('RENOMBRAR GRUPO'),
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppText.body(13, color: AppColors.bone),
          decoration: InputDecoration(labelText: tr('NOMBRE DEL GRUPO')),
        ),
        actions: [
          GhostButton(
            label: tr('Cancelar'),
            dense: true,
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          GhostButton(
            label: tr('Guardar'),
            dense: true,
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              final saved = ConnectionGroup(
                id: group?.id ?? const Uuid().v4(),
                name: name,
                parentId: group?.parentId,
              );
              await state.saveGroup(saved);
              if (ctx.mounted) Navigator.of(ctx).pop(saved);
            },
          ),
        ],
      ),
    );
  }

  void _confirmDeleteGroup(
      BuildContext context, AppState state, ConnectionGroup group) {
    final members =
        state.profiles.where((p) => p.groupId == group.id).length;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(tr('ELIMINAR GRUPO'),
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: Text(
            members == 0
                ? tr('¿Eliminar el grupo "{0}"?', [group.name])
                : tr('¿Eliminar el grupo "{0}"? Sus {1} servidor(es) no se borran: pasan a "Sin grupo".',
                    [group.name, members]),
            style: AppText.body(12, color: AppColors.muted)),
        actions: [
          GhostButton(
            label: tr('Cancelar'),
            dense: true,
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          GhostButton(
            label: tr('Eliminar'),
            dense: true,
            danger: true,
            onPressed: () {
              state.deleteGroup(group.id);
              Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
  }

  // ---- Shared sheet bits -----------------------------------------------------

  Widget _sheetTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(text,
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
      );

  Widget _actionTile(
      BuildContext sheetCtx, IconData icon, String label, VoidCallback action,
      {bool danger = false, bool selected = false}) {
    final fg = danger ? AppColors.danger : AppColors.bone;
    final sz = (16 * sheetCtx.read<AppState>().uiIconFactor).roundToDouble();
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
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
              Expanded(
                child: Text(label,
                    style: AppText.label(10, color: fg, spacing: 1.0)),
              ),
              if (selected)
                Icon(Icons.check, size: sz, color: AppColors.accent),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeleteConfirmation(
      BuildContext context, AppState state, ConnectionProfile profile) {
    // Deleting a bastion is never a local edit: everything behind it loses its
    // way in. Say which machines, by name, while the list is still on screen.
    final dependents = state.profilesJumpingThrough(profile.id);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(tr('ELIMINAR CONEXIÓN'),
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('¿Eliminar el perfil "{0}"?', [profile.name]),
                style: AppText.body(12, color: AppColors.muted)),
            if (dependents.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                tr('{0} saltan por él y pasarán a conectar directamente: {1}', [
                  dependents.length,
                  dependents.map((p) => p.name).join(', '),
                ]),
                style: AppText.body(12, color: AppColors.danger),
              ),
            ],
          ],
        ),
        actions: [
          GhostButton(
            label: tr('Cancelar'),
            dense: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
          GhostButton(
            label: tr('Eliminar'),
            dense: true,
            danger: true,
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(context);
              final orphaned = await state.deleteProfile(profile.id);
              navigator.pop();
              // The in-memory profile still holds its secrets, so re-saving it
              // restores the entry *and* its password/key. A confirmation
              // dialog plus an undo is not redundant: the dialog catches the
              // wrong intention, the undo catches the wrong row.
              messenger
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(
                  content: Text(tr('"{0}" eliminado', [profile.name])),
                  action: SnackBarAction(
                    label: tr('Deshacer'),
                    onPressed: () async {
                      await state.saveProfile(profile);
                      // Undo has to put the chain back too, or the bastion
                      // returns with nothing pointing at it.
                      await state.relinkJumpHost(orphaned, profile.id);
                    },
                  ),
                ));
            },
          ),
        ],
      ),
    );
  }

  // ---- Profile form ----------------------------------------------------------

  void _showProfileDialog(BuildContext context, ConnectionProfile? profile) {
    final isEditing = profile != null;
    // Hoisted out of buildProfile(): the jump picker has to reason about this
    // profile's identity (a chain must not close a loop through it) before it
    // has been saved, and a fresh uuid per rebuild would not be an identity.
    final draftId = profile?.id ?? const Uuid().v4();
    final nameController = TextEditingController(text: profile?.name ?? '');
    final hostController = TextEditingController(text: profile?.host ?? '');
    final portController =
        TextEditingController(text: profile?.port.toString() ?? '22');
    final usernameController =
        TextEditingController(text: profile?.username ?? '');
    final passwordController =
        TextEditingController(text: profile?.password ?? '');
    final privateKeyController =
        TextEditingController(text: profile?.privateKey ?? '');
    final commandController = TextEditingController();
    final tunnels = List<SshTunnel>.from(profile?.tunnels ?? const []);
    var useTmux = profile?.useTmux ?? false;
    var useDeviceKey = profile?.useDeviceKey ?? false;
    var colorHex = profile?.colorHex;
    var isProduction = profile?.isProduction ?? false;
    var jumpProfileId = profile?.jumpProfileId;
    var groupId = profile?.groupId;

    // "Probar conexión" state, owned by the sheet: null = never run.
    String? testResult;
    var testOk = false;
    var testing = false;

    showAdaptiveSheet(
      context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      heightFactor: 0.95,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          ConnectionProfile buildProfile() => ConnectionProfile(
                id: draftId,
                name: nameController.text,
                host: hostController.text,
                port: int.tryParse(portController.text) ?? 22,
                username: usernameController.text,
                password: passwordController.text.isEmpty
                    ? null
                    : passwordController.text,
                privateKey: privateKeyController.text.trim().isEmpty
                    ? null
                    : privateKeyController.text.trim(),
                groupId: groupId,
                tunnels: tunnels,
                useTmux: useTmux,
                useDeviceKey: useDeviceKey,
                colorHex: colorHex,
                isProduction: isProduction,
                jumpProfileId: jumpProfileId,
              );

          bool complete() =>
              nameController.text.isNotEmpty &&
              hostController.text.isNotEmpty &&
              usernameController.text.isNotEmpty;

          Future<void> runTest() async {
            if (!complete()) {
              ScaffoldMessenger.of(sheetCtx).showSnackBar(
                SnackBar(content: Text(tr('Completa los campos requeridos'))),
              );
              return;
            }
            setSheetState(() {
              testing = true;
              testResult = null;
            });
            final state = Provider.of<AppState>(sheetCtx, listen: false);
            final outcome = await state.testProfile(buildProfile());
            if (!sheetCtx.mounted) return;
            setSheetState(() {
              testing = false;
              testOk = outcome.ok;
              testResult = outcome.message;
            });
          }

          return Padding(
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
                  Text(
                      isEditing
                          ? tr('EDITAR PERFIL SSH')
                          : tr('NUEVO PERFIL SSH'),
                      style: AppText.label(10,
                          color: AppColors.bone, spacing: 1.6)),
                  const SizedBox(height: 4),
                  Hairline(),
                  const SizedBox(height: 16),

                  // ---- Paste full ssh command -> autofill ------------------
                  Text(tr('PEGAR COMANDO SSH'),
                      style: AppText.label(9,
                          color: AppColors.muted, spacing: 1.4)),
                  const SizedBox(height: 6),
                  _field(commandController,
                      tr('ssh -L 3000:localhost:3000 usuario@host'),
                      mono: true),
                  const SizedBox(height: 8),
                  GhostButton(
                    label: tr('Autocompletar desde el comando'),
                    icon: Icons.auto_fix_high,
                    dense: true,
                    onPressed: () {
                      final parsed =
                          ConnectionProfile.parseCommand(commandController.text);
                      if (parsed == null) {
                        ScaffoldMessenger.of(sheetCtx).showSnackBar(
                          SnackBar(
                              content: Text(tr(
                                  'No se pudo leer el comando. Verifica el formato.'))),
                        );
                        return;
                      }
                      setSheetState(() {
                        hostController.text = parsed.host;
                        if (parsed.username != null) {
                          usernameController.text = parsed.username!;
                        }
                        portController.text = (parsed.port ?? 22).toString();
                        if (parsed.tunnels.isNotEmpty) {
                          tunnels
                            ..clear()
                            ..addAll(parsed.tunnels);
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

                  _field(nameController, tr('NOMBRE DEL PERFIL')),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child:
                            _field(hostController, tr('HOST / IP'), mono: true),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 1,
                        child: _field(portController, tr('PUERTO'),
                            mono: true, number: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _field(usernameController, tr('USUARIO'), mono: true),
                  const SizedBox(height: 12),
                  _field(passwordController, tr('CONTRASEÑA (OPCIONAL)'),
                      obscure: true),
                  const SizedBox(height: 6),
                  // Say where the secret goes. The app does the right thing
                  // (Keystore on Android, libsecret on Linux — see SecureStore)
                  // and never told anyone, which is worth nothing to a user
                  // deciding whether to type a production password into it.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_outline, size: 12, color: AppColors.faint),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          tr('La contraseña y la llave se guardan cifradas en el almacén seguro del dispositivo, no junto al resto de ajustes.'),
                          style: AppText.label(8.5,
                              color: AppColors.faint, spacing: 0.3),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // ---- Public-key auth -------------------------------------
                  ToggleRow(
                    label: tr('USAR LLAVE DEL DISPOSITIVO'),
                    description: tr(
                        'Autentica con la llave SSH del teléfono (se genera en Ajustes). Requiere su llave pública en el servidor.'),
                    value: useDeviceKey,
                    onChanged: (v) => setSheetState(() => useDeviceKey = v),
                  ),
                  _field(privateKeyController,
                      tr('LLAVE PRIVADA DEL PERFIL (PEM, OPCIONAL)'),
                      mono: true, maxLines: 3),
                  const SizedBox(height: 8),

                  // ---- Persistent session (tmux) ---------------------------
                  ToggleRow(
                    label: tr('SESIÓN PERSISTENTE (TMUX)'),
                    description: tr(
                        'Los agentes y procesos siguen corriendo si se corta la conexión; al reconectar vuelves donde estabas. Requiere tmux en el servidor.'),
                    value: useTmux,
                    onChanged: (v) => setSheetState(() => useTmux = v),
                  ),
                  const SizedBox(height: 8),

                  // ---- Jump host (ProxyJump) ------------------------------
                  // Placed with the connection details, not with the extras:
                  // for a machine behind a bastion this is as much part of
                  // "how do I reach it" as the host and the port.
                  _jumpField(
                    sheetCtx,
                    draftId: draftId,
                    jumpProfileId: jumpProfileId,
                    onPick: (id) => setSheetState(() => jumpProfileId = id),
                  ),
                  const SizedBox(height: 16),

                  // ---- Signal color + production marker --------------------
                  // Sits right after the connection details because it answers
                  // a question about the machine ("which one is this?"), not
                  // about how to reach it.
                  Text(tr('COLOR E IDENTIDAD'),
                      style: AppText.label(9,
                          color: AppColors.muted, spacing: 1.4)),
                  const SizedBox(height: 8),
                  Text(
                    tr('El color marca esta máquina en la lista, en la barra de sesiones y sobre la propia terminal.'),
                    style: AppText.body(11, color: AppColors.muted),
                  ),
                  const SizedBox(height: 10),
                  ProfileColorPicker(
                    selectedHex: colorHex,
                    onChanged: (hex) => setSheetState(() => colorHex = hex),
                  ),
                  const SizedBox(height: 12),
                  ToggleRow(
                    label: tr('MÁQUINA DE PRODUCCIÓN'),
                    description: tr(
                        'Añade una etiqueta PROD y, si no elegiste color, pinta esta máquina en rojo.'),
                    value: isProduction,
                    onChanged: (v) => setSheetState(() => isProduction = v),
                  ),
                  const SizedBox(height: 8),

                  // ---- Group ----------------------------------------------
                  _groupField(sheetCtx, groupId,
                      (id) => setSheetState(() => groupId = id)),
                  const SizedBox(height: 8),

                  // ---- Port-forward tunnels (-L / -D / -R) -----------------
                  Text(tr('TÚNELES · PORT FORWARDING'),
                      style: AppText.label(9,
                          color: AppColors.muted, spacing: 1.4)),
                  const SizedBox(height: 8),
                  if (tunnels.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        tr('Sin túneles. Puedes abrir un servicio del servidor en este teléfono, usar el servidor como proxy o publicar algo tuyo en él.'),
                        style: AppText.body(11, color: AppColors.muted),
                      ),
                    ),
                  for (int i = 0; i < tunnels.length; i++)
                    _tunnelRow(
                      tunnels[i],
                      onEdit: () async {
                        final edited = await showTunnelEditor(sheetCtx,
                            initial: tunnels[i]);
                        if (edited != null) {
                          setSheetState(() => tunnels[i] = edited);
                        }
                      },
                      onRemove: () => setSheetState(() => tunnels.removeAt(i)),
                    ),
                  GhostButton(
                    label: tr('Añadir túnel'),
                    icon: Icons.add,
                    dense: true,
                    onPressed: () async {
                      final created = await showTunnelEditor(sheetCtx);
                      if (created != null) {
                        setSheetState(() => tunnels.add(created));
                      }
                    },
                  ),
                  const SizedBox(height: 20),

                  // ---- Test before saving ----------------------------------
                  // Without this the only way to find out a profile is wrong is
                  // to connect with it and read an error in the terminal.
                  GhostButton(
                    label: testing
                        ? tr('Probando…')
                        : tr('Probar conexión'),
                    icon: Icons.wifi_tethering,
                    dense: true,
                    onPressed: testing ? null : runTest,
                  ),
                  if (testResult != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                            testOk
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                            size: 14,
                            color:
                                testOk ? AppColors.accent : AppColors.danger),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(testResult!,
                              style: AppText.body(11,
                                  color: testOk
                                      ? AppColors.bone
                                      : AppColors.danger)),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 14),

                  InvertedButton(
                    label: isEditing
                        ? tr('Guardar cambios')
                        : tr('Conectar y guardar'),
                    expand: true,
                    onPressed: () {
                      if (!complete()) {
                        ScaffoldMessenger.of(sheetCtx).showSnackBar(
                          SnackBar(
                              content:
                                  Text(tr('Completa los campos requeridos'))),
                        );
                        return;
                      }

                      final newProfile = buildProfile();
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
          );
        },
      ),
    );
  }

  /// Group selector inside the profile form: a row of chips, so assigning a
  /// group costs one tap and is visible without opening anything.
  /// "Conectar a través de" — OpenSSH's `ProxyJump`.
  ///
  /// A tappable row into a picker rather than a chip strip: the candidate list
  /// is every other profile, which is thirty rows for the kind of user who
  /// needs a bastion in the first place.
  Widget _jumpField(
    BuildContext context, {
    required String draftId,
    required String? jumpProfileId,
    required ValueChanged<String?> onPick,
  }) {
    final state = Provider.of<AppState>(context, listen: false);
    final candidates = JumpChain.candidatesFor(draftId, state.profiles);
    final selected =
        state.profiles.where((p) => p.id == jumpProfileId).firstOrNull;

    // The referenced profile is gone (deleted, or a backup restored without
    // it). Say so in the field instead of showing "Directo", which would be a
    // lie about what this profile is configured to do.
    final dangling = jumpProfileId != null && selected == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('CONECTAR A TRAVÉS DE (SALTO)'),
            style: AppText.label(9, color: AppColors.muted, spacing: 1.4)),
        const SizedBox(height: 6),
        Text(
          tr('Para máquinas que solo son accesibles desde otro servidor. Equivale a ssh -J.'),
          style: AppText.body(11, color: AppColors.muted),
        ),
        const SizedBox(height: 8),
        if (candidates.isEmpty && !dangling)
          Text(
            tr('Necesitas otro perfil guardado para usarlo como salto.'),
            style: AppText.body(11, color: AppColors.faint),
          )
        else
          InkWell(
            onTap: () => _showJumpPicker(context, draftId, jumpProfileId, onPick),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(
                    color: dangling ? AppColors.danger : AppColors.hairline,
                    width: 1),
              ),
              child: Row(
                children: [
                  Icon(
                      selected == null
                          ? (dangling ? Icons.link_off : Icons.trending_flat)
                          : Icons.alt_route,
                      size: 15,
                      color: dangling ? AppColors.danger : AppColors.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      dangling
                          ? tr('El salto guardado ya no existe')
                          : selected == null
                              ? tr('Directo (sin salto)')
                              : '${selected.name}  ·  ${selected.username}@${selected.host}:${selected.port}',
                      style: AppText.body(12,
                          color: dangling ? AppColors.danger : AppColors.bone),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(Icons.expand_more, size: 16, color: AppColors.muted),
                ],
              ),
            ),
          ),
        // The full route, once there is more than one hop to show.
        if (selected != null) ...[
          const SizedBox(height: 6),
          Builder(builder: (_) {
            final route = JumpChain.describe(
              ConnectionProfile(
                id: draftId,
                name: '',
                host: '',
                port: 22,
                username: '',
                jumpProfileId: jumpProfileId,
              ),
              state.profiles,
            );
            if (route == null) return const SizedBox.shrink();
            return Text(
              tr('Ruta: {0} → este servidor', [route]),
              style: AppText.mono(9, color: AppColors.faint, spacing: 0.4),
            );
          }),
        ],
      ],
    );
  }

  void _showJumpPicker(BuildContext context, String draftId,
      String? jumpProfileId, ValueChanged<String?> onPick) {
    final state = Provider.of<AppState>(context, listen: false);
    // Only legal hops are listed: anything that would close a loop, point at
    // itself, run through the local terminal or overflow the hop limit is not
    // offered, so an unusable chain cannot be saved in the first place.
    final candidates = JumpChain.candidatesFor(draftId, state.profiles);

    showAdaptiveSheet(
      context,
      backgroundColor: AppColors.panel,
      maxWidth: 460,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sheetTitle(tr('SERVIDOR DE SALTO')),
            Hairline(),
            _actionTile(sheetCtx, Icons.trending_flat, tr('DIRECTO (SIN SALTO)'),
                () => onPick(null),
                selected: jumpProfileId == null),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: candidates.length,
                separatorBuilder: (_, _) => Hairline(),
                itemBuilder: (ctx, i) {
                  final hop = candidates[i];
                  final depth = JumpChain.depthOf(hop.id, state.profiles);
                  return LayerRow(
                    glyph: const Icon(Icons.alt_route),
                    title: hop.name,
                    meta: depth > 1
                        ? '${hop.username}@${hop.host}:${hop.port}  ·  ${tr('{0} saltos', [depth])}'
                        : '${hop.username}@${hop.host}:${hop.port}',
                    active: hop.id == jumpProfileId,
                    tint: profileTint(hop),
                    onTap: () {
                      onPick(hop.id);
                      Navigator.of(sheetCtx).pop();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupField(
      BuildContext context, String? groupId, ValueChanged<String?> onPick) {
    final state = Provider.of<AppState>(context, listen: false);
    if (state.groups.isEmpty) return const SizedBox.shrink();

    Widget chip(String label, bool selected, VoidCallback onTap) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? AppColors.accent : Colors.transparent,
              border: Border.all(
                  color: selected ? AppColors.accent : AppColors.hairline,
                  width: 1),
            ),
            child: Text(label.toUpperCase(),
                style: AppText.label(9,
                    color: selected ? AppColors.ink : AppColors.muted,
                    spacing: 1.0)),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('GRUPO'),
            style: AppText.label(9, color: AppColors.muted, spacing: 1.4)),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              chip(tr('Sin grupo'), groupId == null, () => onPick(null)),
              for (final g in state.groups)
                chip(g.name, groupId == g.id, () => onPick(g.id)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tunnelRow(SshTunnel tunnel,
      {required VoidCallback onEdit, required VoidCallback onRemove}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onEdit,
        child: Row(
          children: [
            MonoTag(tunnel.kind.flag, bordered: true),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tunnel.label.isEmpty ? tunnel.describe() : tunnel.label,
                    style: AppText.mono(12, color: AppColors.bone),
                  ),
                  if (tunnel.label.isNotEmpty)
                    Text(tunnel.describe(),
                        style: AppText.mono(10, color: AppColors.muted)),
                  if (tunnel.exposeToLan && tunnel.kind.listensOnDevice)
                    Text(tr('EXPUESTO A LA RED LOCAL'),
                        style: AppText.label(8,
                            color: AppColors.danger, spacing: 1.0)),
                ],
              ),
            ),
            IconTapTarget(
              icon: Icons.close,
              label: tr('Quitar túnel'),
              size: 14,
              min: 34,
              color: AppColors.danger,
              onTap: onRemove,
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label,
      {bool mono = false,
      bool number = false,
      bool obscure = false,
      int maxLines = 1}) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enableIMEPersonalizedLearning: !obscure,
      keyboardType: number
          ? TextInputType.number
          : (maxLines > 1 ? TextInputType.multiline : null),
      maxLines: maxLines,
      decoration: InputDecoration(
          labelText: label, alignLabelWithHint: maxLines > 1),
      style: mono
          ? AppText.mono(maxLines > 1 ? 10 : 13, color: AppColors.bone)
          : AppText.body(13, color: AppColors.bone),
    );
  }
}
