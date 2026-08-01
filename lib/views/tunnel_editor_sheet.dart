import 'package:flutter/material.dart';

import '../models/ssh_tunnel.dart';
import '../theme/app_theme.dart';
import '../widgets/swiss.dart';

/// Bottom sheet to create or edit a single [SshTunnel].
///
/// Shared by the profile form and the console's tunnel sheet, so a tunnel is
/// built exactly the same way wherever it's added. Returns the tunnel, or null
/// if the user backed out.
Future<SshTunnel?> showTunnelEditor(BuildContext context,
    {SshTunnel? initial}) {
  return showModalBottomSheet<SshTunnel>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.panel,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height -
          MediaQuery.of(context).padding.top -
          12,
    ),
    builder: (sheetCtx) => _TunnelEditor(initial: initial),
  );
}

class _TunnelEditor extends StatefulWidget {
  final SshTunnel? initial;
  const _TunnelEditor({this.initial});

  @override
  State<_TunnelEditor> createState() => _TunnelEditorState();
}

class _TunnelEditorState extends State<_TunnelEditor> {
  late final TextEditingController _label;
  late final TextEditingController _listenPort;
  late final TextEditingController _destHost;
  late final TextEditingController _destPort;
  final _spec = TextEditingController();

  late TunnelKind _kind;
  late bool _autoStart;
  late bool _exposeToLan;
  String? _error;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _kind = t?.kind ?? TunnelKind.local;
    _autoStart = t?.autoStart ?? true;
    _exposeToLan = t?.exposeToLan ?? false;
    _label = TextEditingController(text: t?.label ?? '');
    _listenPort = TextEditingController(
        text: t == null ? '' : t.listenPort.toString());
    _destHost = TextEditingController(text: t?.destHost ?? 'localhost');
    _destPort =
        TextEditingController(text: t == null || t.destPort == 0 ? '' : '${t.destPort}');
  }

  @override
  void dispose() {
    _label.dispose();
    _listenPort.dispose();
    _destHost.dispose();
    _destPort.dispose();
    _spec.dispose();
    super.dispose();
  }

  /// Builds the tunnel from the current form state, reusing the original id so
  /// an edit keeps its live runtime instead of starting a new one.
  SshTunnel _build() => SshTunnel(
        id: widget.initial?.id,
        label: _label.text.trim(),
        kind: _kind,
        listenPort: int.tryParse(_listenPort.text.trim()) ?? 0,
        destHost: _kind.hasDestination ? _destHost.text.trim() : 'localhost',
        destPort:
            _kind.hasDestination ? int.tryParse(_destPort.text.trim()) ?? 0 : 0,
        autoStart: _autoStart,
        exposeToLan: _exposeToLan && _kind.listensOnDevice,
      );

  void _applySpec() {
    final parsed = SshTunnel.parseSpec(_spec.text);
    if (parsed == null) {
      setState(() => _error =
          'No se pudo leer el túnel. Ejemplos: -L 8080:localhost:80, -D 1080, '
          '-R 8080:localhost:3000');
      return;
    }
    setState(() {
      _error = null;
      _kind = parsed.kind;
      _listenPort.text = '${parsed.listenPort}';
      _destHost.text = parsed.destHost;
      _destPort.text = parsed.destPort == 0 ? '' : '${parsed.destPort}';
      _exposeToLan = parsed.exposeToLan;
      _spec.clear();
    });
  }

  /// A SOCKS proxy bound to 0.0.0.0 is an open proxy for the whole wifi — the
  /// one combination worth a hard stop rather than a warning line.
  Future<bool> _confirmOpenProxy() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text('PROXY ABIERTO',
            style: AppText.label(11, color: AppColors.bone, spacing: 1.4)),
        content: Text(
          'Un proxy SOCKS expuesto a la red local deja que cualquier '
          'dispositivo del wifi navegue a través de tu servidor, sin '
          'contraseña. Úsalo sólo en redes de confianza.',
          style: AppText.body(12, color: AppColors.muted),
        ),
        actions: [
          GhostButton(
            label: 'Cancelar',
            dense: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          GhostButton(
            label: 'Entiendo el riesgo',
            dense: true,
            danger: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _save() async {
    final tunnel = _build();
    final invalid = tunnel.validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    if (tunnel.kind == TunnelKind.dynamicSocks && tunnel.exposeToLan) {
      if (!await _confirmOpenProxy()) return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(tunnel);
  }

  @override
  Widget build(BuildContext context) {
    final preview = _build();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 18,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.initial == null ? 'NUEVO TÚNEL' : 'EDITAR TÚNEL',
                style: AppText.label(10, color: AppColors.bone, spacing: 1.6)),
            const SizedBox(height: 4),
            Hairline(),
            const SizedBox(height: 16),

            // ---- Kind picker ---------------------------------------------
            Text('TIPO', style: _sectionStyle),
            const SizedBox(height: 8),
            for (final kind in TunnelKind.values) ...[
              _KindOption(
                kind: kind,
                selected: _kind == kind,
                onTap: () => setState(() {
                  _kind = kind;
                  _error = null;
                  if (!kind.listensOnDevice) _exposeToLan = false;
                }),
              ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 10),

            // ---- Ports ----------------------------------------------------
            Text(_kind == TunnelKind.remote ? 'PUERTO EN EL SERVIDOR' : 'PUERTO EN ESTE TELÉFONO',
                style: _sectionStyle),
            const SizedBox(height: 6),
            _field(_listenPort, _kind == TunnelKind.dynamicSocks ? '1080' : '8080',
                number: true),
            if (_kind.hasDestination) ...[
              const SizedBox(height: 12),
              Text(
                  _kind == TunnelKind.local
                      ? 'DESTINO (VISTO DESDE EL SERVIDOR)'
                      : 'DESTINO (EN ESTE TELÉFONO)',
                  style: _sectionStyle),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _field(_destHost, 'localhost'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: _field(_destPort, 'PUERTO', number: true),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _field(_label, 'NOMBRE (OPCIONAL)', mono: false),
            const SizedBox(height: 8),

            // ---- Options ---------------------------------------------------
            ToggleRow(
              label: 'ARRANCAR AL CONECTAR',
              description:
                  'El túnel se abre solo cada vez que esta conexión se establece.',
              value: _autoStart,
              onChanged: (v) => setState(() => _autoStart = v),
            ),
            if (_kind.listensOnDevice)
              ToggleRow(
                label: 'EXPONER A LA RED LOCAL',
                description:
                    'Por defecto el túnel sólo es accesible desde este teléfono. '
                    'Al activarlo, cualquier dispositivo del wifi podrá usarlo.',
                value: _exposeToLan,
                onChanged: (v) => setState(() => _exposeToLan = v),
              ),
            if (_kind == TunnelKind.remote)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Abre un puerto en el servidor. Para que sea accesible desde '
                  'fuera, su sshd necesita «GatewayPorts yes» y el firewall '
                  'abierto.',
                  style: AppText.body(11, color: AppColors.muted),
                ),
              ),
            const SizedBox(height: 12),

            // ---- Live OpenSSH preview -------------------------------------
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.ink,
                border: Border.all(color: AppColors.hairline),
              ),
              child: Row(
                children: [
                  MonoTag('equivale a'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('ssh ${preview.toSpec()} …',
                        style: AppText.mono(11, color: AppColors.bone)),
                  ),
                ],
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: AppText.body(11, color: AppColors.danger)),
            ],
            const SizedBox(height: 16),

            // ---- Paste a spec ---------------------------------------------
            Text('O PEGA UN ARGUMENTO SSH', style: _sectionStyle),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _field(_spec, '-L 8080:localhost:80', mono: true),
                ),
                const SizedBox(width: 8),
                GhostButton(
                  label: 'Usar',
                  icon: Icons.auto_fix_high,
                  dense: true,
                  onPressed: _applySpec,
                ),
              ],
            ),
            const SizedBox(height: 20),

            InvertedButton(
              label: widget.initial == null ? 'Añadir túnel' : 'Guardar túnel',
              expand: true,
              onPressed: _save,
            ),
            const SizedBox(height: 18),
          ],
        ),
      ),
    );
  }

  TextStyle get _sectionStyle =>
      AppText.label(9, color: AppColors.muted, spacing: 1.4);

  Widget _field(TextEditingController controller, String label,
      {bool mono = true, bool number = false}) {
    return TextField(
      controller: controller,
      keyboardType: number ? TextInputType.number : null,
      decoration: InputDecoration(labelText: label),
      style: mono
          ? AppText.mono(13, color: AppColors.bone)
          : AppText.body(13, color: AppColors.bone),
      onChanged: (_) => setState(() => _error = null),
    );
  }
}

/// One selectable tunnel kind: flag, name and a plain-language explanation.
class _KindOption extends StatelessWidget {
  final TunnelKind kind;
  final bool selected;
  final VoidCallback onTap;

  const _KindOption({
    required this.kind,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.ink : AppColors.bone;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.bone : AppColors.ink,
          border: Border.all(
              color: selected ? AppColors.bone : AppColors.hairline, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 30,
              child: Text(kind.flag,
                  style: AppText.mono(13, color: fg, weight: FontWeight.w700)),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kind.title,
                      style: AppText.label(9,
                          color: selected ? AppColors.ink : AppColors.bone,
                          spacing: 1.2)),
                  const SizedBox(height: 4),
                  Text(kind.blurb,
                      style: AppText.body(11,
                          color: selected ? AppColors.ink : AppColors.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
