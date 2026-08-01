import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/db_connection_profile.dart';
import '../services/server_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';
import '../l10n/l10n.dart';

/// Database management tab. Integrates Supabase-style table row grid,
/// a custom entity-relationship schema visualizer, and a SQL editor.
class ServerDbTab extends StatefulWidget {
  final ServerController server;
  const ServerDbTab({super.key, required this.server});

  @override
  State<ServerDbTab> createState() => _ServerDbTabState();
}

class _ServerDbTabState extends State<ServerDbTab> {
  // Navigation: 0 = Tablas, 1 = Relaciones, 2 = Consola SQL
  int _dbSubTab = 0;

  final TextEditingController _sqlController = TextEditingController();
  String _sqlOutput = '';

  // Form controllers for adding a DB profile
  bool _showAddForm = false;
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController();
  final TextEditingController _userCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  final TextEditingController _dbNameCtrl = TextEditingController();
  String _engine = 'postgres';
  String? _selectedContainer; // If running in docker

  @override
  void initState() {
    super.initState();
    // Default ports
    _portCtrl.text = '5432';
  }

  @override
  void dispose() {
    _sqlController.dispose();
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _dbNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.server.dbConnected) {
      return _buildConnectionManager();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSubTabBar(),
        Expanded(
          child: widget.server.dbLoading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _buildActiveSubTab(),
        ),
      ],
    );
  }

  Widget _buildSubTabBar() {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Row(
        children: [
          _subTabButton(0, tr('TABLAS'), Icons.table_chart_outlined),
          _subTabButton(1, tr('RELACIONES'), Icons.account_tree_outlined),
          _subTabButton(2, tr('CONSOLA SQL'), Icons.code),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.power_settings_new, size: 16),
            color: AppColors.muted,
            tooltip: tr('Desconectar'),
            onPressed: () {
              widget.server.disconnectFromDatabase();
            },
          ),
        ],
      ),
    );
  }

  Widget _subTabButton(int index, String label, IconData icon) {
    final active = _dbSubTab == index;
    final color = active ? AppColors.accent : AppColors.muted;
    return InkWell(
      onTap: () => setState(() => _dbSubTab = index),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? AppColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: AppText.mono(8.5,
                  color: color, weight: active ? FontWeight.bold : FontWeight.normal),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveSubTab() {
    switch (_dbSubTab) {
      case 0:
        return _buildTableEditor();
      case 1:
        return _buildRelationshipViewer();
      case 2:
        return _buildSqlConsole();
      default:
        return const SizedBox.shrink();
    }
  }

  // ---------------------------------------------------------------------
  // Sub-Tab 0: Table Row Editor & Browser (Supabase-style)
  // ---------------------------------------------------------------------

  Widget _buildTableEditor() {
    final server = widget.server;
    if (server.dbTables.isEmpty) {
      return Center(
        child: Text(tr('Sin tablas públicas detectadas.'),
            style: AppText.body(11, color: AppColors.muted)),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final isLarge = screenWidth > 640;

    final tableList = Container(
      width: isLarge ? 200 : double.infinity,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(
          right: BorderSide(color: isLarge ? AppColors.hairline : Colors.transparent),
          bottom: BorderSide(color: !isLarge ? AppColors.hairline : Colors.transparent),
        ),
      ),
      child: ListView.separated(
        itemCount: server.dbTables.length,
        separatorBuilder: (_, __) => Hairline(),
        itemBuilder: (context, i) {
          final t = server.dbTables[i];
          final active = server.activeDbTable == t;
          return ListTile(
            dense: true,
            selected: active,
            selectedColor: AppColors.accent,
            leading: Icon(Icons.table_rows_outlined,
                size: 14, color: active ? AppColors.accent : AppColors.muted),
            title: Text(
              t,
              style: AppText.mono(10.5,
                  color: active ? AppColors.bone : AppColors.muted,
                  weight: active ? FontWeight.bold : FontWeight.normal),
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              server.fetchTableData(t);
              if (!isLarge) {
                // If on mobile, close the sheet drawer if needed
              }
            },
          );
        },
      ),
    );

    final dataGrid = Expanded(
      child: server.activeDbTable == null
          ? Center(
              child: Text(
                tr('Selecciona una tabla de la lista'),
                style: AppText.body(12, color: AppColors.muted),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTableActionsRow(),
                Expanded(
                  child: server.dbRows.isEmpty
                      ? Center(
                          child: Text(tr('Tabla vacía o sin registros.'),
                              style: AppText.body(11, color: AppColors.muted)),
                        )
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.vertical,
                            child: Theme(
                              data: Theme.of(context).copyWith(
                                dividerColor: AppColors.hairline,
                              ),
                              child: DataTable(
                                headingRowColor: WidgetStateProperty.all(AppColors.panelHi),
                                dataRowColor: WidgetStateProperty.all(AppColors.panel),
                                dividerThickness: 1,
                                horizontalMargin: 12,
                                columnSpacing: 24,
                                showCheckboxColumn: false,
                                columns: server.dbColumns.map((col) {
                                  final isPk = col['is_primary'] == true;
                                  return DataColumn(
                                    label: Row(
                                      children: [
                                        if (isPk)
                                          Padding(
                                            padding: const EdgeInsets.only(right: 4),
                                            child: Icon(Icons.key,
                                                size: 10, color: AppColors.accent),
                                          ),
                                        Text(
                                          col['column_name'] as String,
                                          style: AppText.mono(10,
                                              color: AppColors.bone, weight: FontWeight.bold),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '(${col['data_type']})',
                                          style: AppText.mono(8, color: AppColors.muted),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                                rows: server.dbRows.map((row) {
                                  return DataRow(
                                    onSelectChanged: (_) => _showRowDetails(row),
                                    cells: server.dbColumns.map((col) {
                                      final val = row[col['column_name']];
                                      return DataCell(
                                        Text(
                                          val == null ? 'NULL' : val.toString(),
                                          style: val == null
                                              ? AppText.mono(9.5, color: AppColors.muted)
                                                  .copyWith(fontStyle: FontStyle.italic)
                                              : AppText.mono(9.5, color: AppColors.bone),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      );
                                    }).toList(),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
    );

    if (isLarge) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tableList,
          dataGrid,
        ],
      );
    }

    // Mobile layout: table selector collapses into a dropdown or bottom sheet.
    // For simplicity, we show a top table-picker button on mobile when a table is active.
    if (server.activeDbTable == null) {
      return tableList;
    }

    return Column(
      children: [
        Container(
          height: 38,
          color: AppColors.panelHi,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(Icons.table_rows, size: 14, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                tr('TABLA: {0}', [server.activeDbTable]),
                style: AppText.mono(10, color: AppColors.bone, weight: FontWeight.bold),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => server.activeDbTable = null),
                child: Text(tr('VER LISTADO'), style: AppText.mono(9, color: AppColors.accent)),
              ),
            ],
          ),
        ),
        dataGrid,
      ],
    );
  }

  Widget _buildTableActionsRow() {
    final server = widget.server;
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(
            '${server.activeDbTable?.toUpperCase()}',
            style: AppText.mono(11, color: AppColors.bone, weight: FontWeight.bold),
          ),
          const SizedBox(width: 6),
          Text(
            tr('({0} filas)', [server.dbRows.length]),
            style: AppText.body(9.5, color: AppColors.muted),
          ),
          const Spacer(),
          GhostButton(
            label: tr('Refrescar'),
            icon: Icons.refresh,
            dense: true,
            onPressed: () => server.fetchTableData(server.activeDbTable!),
          ),
          const SizedBox(width: 8),
          InvertedButton(
            label: tr('Insertar Fila'),
            icon: Icons.add,
            dense: true,
            onPressed: _showInsertRowDialog,
          ),
        ],
      ),
    );
  }

  void _showRowDetails(Map<String, dynamic> row) {
    final server = widget.server;
    // Identify primary key(s) or fallback to all fields for deletion filter
    final pks = server.dbColumns.where((c) => c['is_primary'] == true).toList();
    final deleteKeys = <String, dynamic>{};
    if (pks.isNotEmpty) {
      for (final pk in pks) {
        final colName = pk['column_name'] as String;
        deleteKeys[colName] = row[colName];
      }
    } else {
      // Use all columns as unique composite key for delete
      row.forEach((k, v) => deleteKeys[k] = v);
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(tr('DETALLES DEL REGISTRO'),
                      style: AppText.label(11, color: AppColors.bone, spacing: 1.5)),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: AppColors.muted),
                    onPressed: () async {
                      Navigator.pop(sheetCtx);
                      final ok = await server.deleteRow(server.activeDbTable!, deleteKeys);
                      if (ok && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(tr('Registro eliminado correctamente'))),
                        );
                      } else if (server.dbError != null && mounted) {
                        _showErrorDialog(server.dbError!);
                      }
                    },
                  ),
                ],
              ),
              Hairline(),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: server.dbColumns.map((col) {
                    final colName = col['column_name'] as String;
                    final val = row[colName];
                    final isPk = col['is_primary'] == true;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 140,
                            child: Row(
                              children: [
                                if (isPk)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(Icons.key, size: 10, color: AppColors.accent),
                                  ),
                                Expanded(
                                  child: Text(
                                    colName,
                                    style: AppText.mono(9.5,
                                        color: AppColors.muted, weight: FontWeight.bold),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: SelectableText(
                              val == null ? 'NULL' : val.toString(),
                              style: val == null
                                  ? AppText.mono(9.5, color: AppColors.muted)
                                      .copyWith(fontStyle: FontStyle.italic)
                                  : AppText.mono(9.5, color: AppColors.bone),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),
              InvertedButton(
                label: tr('Cerrar'),
                dense: true,
                onPressed: () => Navigator.pop(sheetCtx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showInsertRowDialog() {
    final server = widget.server;
    final rowData = <String, dynamic>{};
    final inputControllers = <String, TextEditingController>{};

    for (final col in server.dbColumns) {
      inputControllers[col['column_name'] as String] = TextEditingController();
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('INSERTAR NUEVA FILA'),
                  style: AppText.label(11, color: AppColors.bone, spacing: 1.5)),
              const SizedBox(height: 4),
              Hairline(),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: server.dbColumns.map((col) {
                    final colName = col['column_name'] as String;
                    final isPk = col['is_primary'] == true;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: TextField(
                        controller: inputControllers[colName],
                        decoration: InputDecoration(
                          labelText: colName.toUpperCase() +
                              (isPk ? tr(' (PRIMARY KEY)') : '') +
                              ' [${col['data_type']}]',
                          hintText: tr('Dejar en blanco para NULL'),
                          labelStyle: AppText.mono(9, color: AppColors.muted),
                        ),
                        style: AppText.mono(10),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: GhostButton(
                      label: tr('Cancelar'),
                      dense: true,
                      onPressed: () {
                        inputControllers.forEach((_, c) => c.dispose());
                        Navigator.pop(sheetCtx);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InvertedButton(
                      label: tr('Guardar'),
                      dense: true,
                      onPressed: () async {
                        inputControllers.forEach((key, controller) {
                          final text = controller.text.trim();
                          if (text.isNotEmpty) {
                            rowData[key] = text;
                          }
                        });
                        inputControllers.forEach((_, c) => c.dispose());
                        Navigator.pop(sheetCtx);
                        final ok = await server.insertRow(server.activeDbTable!, rowData);
                        if (ok && mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(tr('Registro insertado correctamente'))),
                          );
                        } else if (server.dbError != null && mounted) {
                          _showErrorDialog(server.dbError!);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Sub-Tab 1: Entity-Relationship Schema Diagram (Supabase-style)
  // ---------------------------------------------------------------------

  Widget _buildRelationshipViewer() {
    final server = widget.server;
    if (server.dbTables.isEmpty) {
      return Center(
        child: Text(tr('Sin datos para modelar relaciones.'),
            style: AppText.body(11, color: AppColors.muted)),
      );
    }

    // Simple grid layout algorithm for tables in diagram
    final Map<String, Offset> tableOffsets = {};
    const double cardWidth = 170;
    const double cardHeight = 130;
    const double hSpacing = 270;
    const double vSpacing = 190;
    const int cols = 3;

    for (int i = 0; i < server.dbTables.length; i++) {
      final name = server.dbTables[i];
      final col = i % cols;
      final row = (i / cols).floor();
      tableOffsets[name] = Offset(col * hSpacing + 50, row * vSpacing + 50);
    }

    // Build the visual diagram canvas
    return InteractiveViewer(
      constrained: false,
      boundaryMargin: const EdgeInsets.all(500),
      minScale: 0.1,
      maxScale: 2.0,
      child: Container(
        width: 1000,
        height: 1000,
        color: AppColors.ink,
        child: Stack(
          children: [
            // Painter for relationship links between tables (runs underneath cards)
            Positioned.fill(
              child: CustomPaint(
                painter: _RelationshipPainter(
                  relations: server.dbRelations,
                  tablePositions: tableOffsets,
                  cardWidth: cardWidth,
                  cardHeight: cardHeight,
                ),
              ),
            ),
            // Render table node cards
            ...server.dbTables.map((tName) {
              final offset = tableOffsets[tName]!;
              final relatedCount = server.dbRelations
                  .where((r) => r['from_table'] == tName || r['to_table'] == tName)
                  .length;

              return Positioned(
                left: offset.dx,
                top: offset.dy,
                child: Container(
                  width: cardWidth,
                  height: cardHeight,
                  decoration: BoxDecoration(
                    color: AppColors.panel,
                    border: Border.all(color: AppColors.hairline, width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: AppColors.panelHi,
                          border: Border(bottom: BorderSide(color: AppColors.hairline)),
                        ),
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Icon(Icons.table_chart, size: 10, color: AppColors.accent),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                tName.toUpperCase(),
                                style: AppText.mono(9,
                                    color: AppColors.bone, weight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              Text(
                                tr('Relaciones: {0}', [relatedCount]),
                                style: AppText.body(9, color: AppColors.muted),
                              ),
                              Text(
                                tr('Campos de enlace FK/PK:'),
                                style: AppText.body(8.5, color: AppColors.muted),
                              ),
                              // Display PK columns or some info
                              Expanded(
                                child: ListView(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: [
                                    ...server.dbRelations
                                        .where((r) => r['from_table'] == tName)
                                        .map((r) => Text(
                                              '🔗 ${r['from_column']} ➔ ${r['to_table']}',
                                              style: AppText.mono(7.5, color: AppColors.muted),
                                              overflow: TextOverflow.ellipsis,
                                            )),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Sub-Tab 2: SQL Command runner console
  // ---------------------------------------------------------------------

  Widget _buildSqlConsole() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('SENTENCIA SQL'),
            style: AppText.mono(9, color: AppColors.muted, weight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.panel,
                border: Border.all(color: AppColors.hairline),
              ),
              child: TextField(
                controller: _sqlController,
                maxLines: null,
                minLines: 8,
                keyboardType: TextInputType.multiline,
                style: AppText.mono(10.5),
                decoration: InputDecoration(
                  hintText: tr('SELECT * FROM users;\n-- ingresa tu código SQL aquí'),
                  contentPadding: EdgeInsets.all(12),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GhostButton(
                label: tr('Limpiar'),
                dense: true,
                onPressed: () => _sqlController.clear(),
              ),
              const SizedBox(width: 8),
              InvertedButton(
                label: tr('EJECUTAR'),
                icon: Icons.play_arrow,
                dense: true,
                onPressed: () async {
                  final sql = _sqlController.text.trim();
                  if (sql.isEmpty) return;
                  FocusScope.of(context).unfocus();
                  final output = await widget.server.executeCustomSql(sql);
                  setState(() => _sqlOutput = output);
                  // Refresh database tables after query execution in case it created/dropped tables
                  widget.server.fetchTables();
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            tr('RESULTADO'),
            style: AppText.mono(9, color: AppColors.muted, weight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.panelHi,
                border: Border.all(color: AppColors.hairline),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _sqlOutput.isEmpty ? tr('Consola SQL lista. Presiona ejecutar para ver salida.') : _sqlOutput,
                  style: AppText.mono(9.5,
                      color: _sqlOutput.startsWith('Error') ? Colors.redAccent : AppColors.bone),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Base Screen: Connection Manager & Profiler
  // ---------------------------------------------------------------------

  Widget _buildConnectionManager() {
    final server = widget.server;
    final profiles = server.dbProfiles;

    if (_showAddForm) {
      return _buildAddProfileForm();
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('BASES DE DATOS'),
                    style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
                const SizedBox(height: 4),
                Text(tr('Conéctate a PostgreSQL o MySQL para gestionar esquemas'),
                    style: AppText.body(9.5, color: AppColors.muted)),
              ],
            ),
            const Spacer(),
            InvertedButton(
              label: tr('Nuevo Perfil'),
              icon: Icons.add,
              dense: true,
              onPressed: () {
                _nameCtrl.clear();
                _hostCtrl.text = 'localhost';
                _portCtrl.text = '5432';
                _userCtrl.clear();
                _passCtrl.clear();
                _dbNameCtrl.clear();
                setState(() {
                  _showAddForm = true;
                  _engine = 'postgres';
                  _selectedContainer = null;
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Hairline(),
        const SizedBox(height: 12),
        if (server.dbError != null)
          Container(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.1),
              border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, size: 14, color: Colors.redAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    server.dbError!,
                    style: AppText.mono(9, color: Colors.redAccent),
                  ),
                ),
              ],
            ),
          ),
        if (profiles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(
              children: [
                Icon(Icons.storage_outlined, size: 40, color: AppColors.muted),
                const SizedBox(height: 12),
                Text(tr('SIN PERFILES DE BASES DE DATOS'),
                    style: AppText.mono(10, color: AppColors.bone, weight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(
                  tr('Crea un nuevo perfil o asócialo a un contenedor de Docker.'),
                  style: AppText.body(9.5, color: AppColors.muted),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          ...profiles.map((p) {
            final isDocker = p.dockerContainer != null;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.panel,
                border: Border.all(color: AppColors.hairline),
              ),
              child: ListTile(
                dense: true,
                leading: Icon(Icons.storage,
                    color: p.engine == 'postgres' ? Colors.blueAccent : Colors.orangeAccent,
                    size: 18),
                title: Text(
                  p.name.toUpperCase(),
                  style: AppText.mono(10.5, color: AppColors.bone, weight: FontWeight.bold),
                ),
                subtitle: Text(
                  isDocker
                      ? tr('DOCKER: {0} · DB: {1}', [p.dockerContainer, p.databaseName])
                      : tr('CONEXIÓN: {0}:{1} · DB: {2}', [p.host, p.port, p.databaseName]),
                  style: AppText.mono(8.5, color: AppColors.muted),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.delete_outline, size: 16, color: AppColors.muted),
                      onPressed: () => server.deleteDbProfile(p.id),
                    ),
                    const SizedBox(width: 4),
                    InvertedButton(
                      label: tr('Conectar'),
                      dense: true,
                      onPressed: () => server.connectToDatabase(p),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildAddProfileForm() {
    final server = widget.server;
    // Scan containers to autofill docker options
    final dbContainers = server.containers.where((c) {
      final img = c.image.toLowerCase();
      final name = c.name.toLowerCase();
      return img.contains('postgres') ||
          img.contains('mysql') ||
          img.contains('mariadb') ||
          name.contains('postgres') ||
          name.contains('mysql') ||
          name.contains('db');
    }).toList();

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Text(tr('CREAR PERFIL DE BASE DE DATOS'),
                  style: AppText.label(11, color: AppColors.bone, spacing: 1.5)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => _showAddForm = false),
              ),
            ],
          ),
          Hairline(),
          const SizedBox(height: 16),
          
          // Container Detection Quick Fill Panel
          if (dbContainers.isNotEmpty && _selectedContainer == null) ...[
            Text(tr('CONTENEDORES DETECTADOS EN EL SERVIDOR'),
                style: AppText.mono(8.5, color: AppColors.muted, weight: FontWeight.bold)),
            const SizedBox(height: 6),
            ...dbContainers.map((c) {
              final isPg = c.image.toLowerCase().contains('postgres');
              return InkWell(
                onTap: () {
                  setState(() {
                    _selectedContainer = c.name;
                    _engine = isPg ? 'postgres' : 'mysql';
                    _portCtrl.text = isPg ? '5432' : '3306';
                    _nameCtrl.text = '${c.name}_profile';
                    _userCtrl.text = isPg ? 'postgres' : 'root';
                    _dbNameCtrl.text = isPg ? 'postgres' : '';
                    _hostCtrl.text = 'localhost';
                  });
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.panel,
                    border: Border.all(color: AppColors.accent.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.widgets_outlined, size: 14, color: AppColors.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tr('Contenedor: {0} ({1})', [c.name, isPg ? 'Postgres' : 'MySQL/MariaDB']),
                          style: AppText.mono(9, color: AppColors.bone),
                        ),
                      ),
                      Icon(Icons.arrow_forward_ios, size: 10, color: AppColors.muted),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 14),
          ],

          DropdownButtonFormField<String>(
            value: _engine,
            decoration: InputDecoration(labelText: tr('MOTOR DE BASE DE DATOS')),
            dropdownColor: AppColors.panel,
            style: AppText.mono(11, color: AppColors.bone),
            items: const [
              DropdownMenuItem(value: 'postgres', child: Text('POSTGRESQL')),
              DropdownMenuItem(value: 'mysql', child: Text('MYSQL / MARIADB')),
            ],
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _engine = val;
                  _portCtrl.text = val == 'postgres' ? '5432' : '3306';
                });
              }
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _nameCtrl,
            decoration: InputDecoration(labelText: tr('NOMBRE DEL PERFIL (ej: Prod DB)')),
            style: AppText.mono(11),
            validator: (v) => v == null || v.trim().isEmpty ? tr('Obligatorio') : null,
          ),
          const SizedBox(height: 12),
          
          DropdownButtonFormField<String?>(
            value: _selectedContainer,
            decoration: InputDecoration(labelText: tr('DOCKER CONTAINER (OPCIONAL)')),
            dropdownColor: AppColors.panel,
            style: AppText.mono(11, color: AppColors.bone),
            items: [
              DropdownMenuItem(value: null, child: Text(tr('NINGUNO (CONEXIÓN DIRECTA)'))),
              ...server.containers.map((c) => DropdownMenuItem(value: c.name, child: Text(c.name))),
            ],
            onChanged: (val) {
              setState(() {
                _selectedContainer = val;
                if (val != null) {
                  _hostCtrl.text = 'localhost';
                }
              });
            },
          ),
          const SizedBox(height: 12),

          if (_selectedContainer == null) ...[
            TextFormField(
              controller: _hostCtrl,
              decoration: InputDecoration(labelText: tr('HOST DE BASE DE DATOS')),
              style: AppText.mono(11),
              validator: (v) => v == null || v.trim().isEmpty ? tr('Obligatorio') : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _portCtrl,
              decoration: InputDecoration(labelText: tr('PUERTO')),
              keyboardType: TextInputType.number,
              style: AppText.mono(11),
              validator: (v) => v == null || v.trim().isEmpty ? tr('Obligatorio') : null,
            ),
            const SizedBox(height: 12),
          ],

          TextFormField(
            controller: _userCtrl,
            decoration: InputDecoration(labelText: tr('USUARIO')),
            style: AppText.mono(11),
            validator: (v) => v == null || v.trim().isEmpty ? tr('Obligatorio') : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _passCtrl,
            decoration: InputDecoration(labelText: tr('CONTRASEÑA')),
            obscureText: true,
            style: AppText.mono(11),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _dbNameCtrl,
            decoration: InputDecoration(labelText: tr('NOMBRE DE LA BASE DE DATOS')),
            style: AppText.mono(11),
            validator: (v) => v == null || v.trim().isEmpty ? tr('Obligatorio') : null,
          ),
          const SizedBox(height: 20),

          Row(
            children: [
              Expanded(
                child: GhostButton(
                  label: tr('Cancelar'),
                  dense: true,
                  onPressed: () => setState(() => _showAddForm = false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InvertedButton(
                  label: tr('Guardar Perfil'),
                  dense: true,
                  onPressed: () {
                    if (_formKey.currentState!.validate()) {
                      final newProfile = DbConnectionProfile(
                        id: const Uuid().v4(),
                        sshProfileId: server.profile!.id,
                        name: _nameCtrl.text.trim(),
                        engine: _engine,
                        host: _selectedContainer != null ? 'localhost' : _hostCtrl.text.trim(),
                        port: int.parse(_portCtrl.text.trim()),
                        username: _userCtrl.text.trim(),
                        password: _passCtrl.text,
                        databaseName: _dbNameCtrl.text.trim(),
                        dockerContainer: _selectedContainer,
                      );
                      server.saveDbProfile(newProfile);
                      setState(() => _showAddForm = false);
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String error) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(tr('ERROR EN LA OPERACIÓN'),
            style: AppText.mono(11, color: AppColors.bone, weight: FontWeight.bold)),
        content: Text(
          error,
          style: AppText.mono(9.5, color: Colors.redAccent),
        ),
        actions: [
          InvertedButton(
            label: tr('Aceptar'),
            dense: true,
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Custom Painter for ER Diagram Link lines
// ---------------------------------------------------------------------

class _RelationshipPainter extends CustomPainter {
  final List<Map<String, dynamic>> relations;
  final Map<String, Offset> tablePositions;
  final double cardWidth;
  final double cardHeight;

  _RelationshipPainter({
    required this.relations,
    required this.tablePositions,
    required this.cardWidth,
    required this.cardHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.accent.withOpacity(0.55)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.fill;

    for (final rel in relations) {
      final fromTable = rel['from_table'] as String;
      final toTable = rel['to_table'] as String;

      final fromPos = tablePositions[fromTable];
      final toPos = tablePositions[toTable];

      if (fromPos == null || toPos == null) continue;

      // Card centers
      final p1 = Offset(fromPos.dx + cardWidth / 2, fromPos.dy + cardHeight / 2);
      final p2 = Offset(toPos.dx + cardWidth / 2, toPos.dy + cardHeight / 2);

      // Determine closest borders to draw connections nicely
      Offset start;
      Offset end;

      if ((p1.dx - p2.dx).abs() > (p1.dy - p2.dy).abs()) {
        // Horizontal connection
        if (p1.dx < p2.dx) {
          start = Offset(fromPos.dx + cardWidth, fromPos.dy + cardHeight / 2);
          end = Offset(toPos.dx, toPos.dy + cardHeight / 2);
        } else {
          start = Offset(fromPos.dx, fromPos.dy + cardHeight / 2);
          end = Offset(toPos.dx + cardWidth, toPos.dy + cardHeight / 2);
        }
      } else {
        // Vertical connection
        if (p1.dy < p2.dy) {
          start = Offset(fromPos.dx + cardWidth / 2, fromPos.dy + cardHeight);
          end = Offset(toPos.dx + cardWidth / 2, toPos.dy);
        } else {
          start = Offset(fromPos.dx + cardWidth / 2, fromPos.dy);
          end = Offset(toPos.dx + cardWidth / 2, toPos.dy + cardHeight);
        }
      }

      // Draw elegant Bézier curve path
      final path = Path();
      path.moveTo(start.dx, start.dy);

      // Control points offsets
      final double dx = (end.dx - start.dx).abs();
      final double dy = (end.dy - start.dy).abs();
      
      final double cX = start.dx < end.dx ? start.dx + dx / 2 : start.dx - dx / 2;
      final double cY = start.dy < end.dy ? start.dy + dy / 2 : start.dy - dy / 2;

      path.quadraticBezierTo(cX, cY, end.dx, end.dy);
      canvas.drawPath(path, paint);

      // Draw anchor circles on connection ends
      canvas.drawCircle(start, 4.0, dotPaint);
      
      // Draw arrow head at the target
      _drawArrowHead(canvas, start, end, dotPaint);
    }
  }

  void _drawArrowHead(Canvas canvas, Offset start, Offset end, Paint paint) {
    // Basic arrow direction vector
    final double angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    const double arrowSize = 6.0;

    final p1 = Offset(
      end.dx - arrowSize * math.cos(angle - math.pi / 6),
      end.dy - arrowSize * math.sin(angle - math.pi / 6),
    );
    final p2 = Offset(
      end.dx - arrowSize * math.cos(angle + math.pi / 6),
      end.dy - arrowSize * math.sin(angle + math.pi / 6),
    );

    final path = Path()
      ..moveTo(end.dx, end.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
