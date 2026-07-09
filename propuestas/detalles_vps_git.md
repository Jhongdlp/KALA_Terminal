# Propuesta de Diseño: Menú Hamburguesa (Drawer) e Integración Git (Tree Slide)

Este documento detalla la arquitectura técnica y el diseño de interfaz para implementar:
1. **Menú Hamburguesa (Drawer lateral):** Reemplazar el botón superior de "Ajustes" por un botón de menú hamburguesa que despliegue un panel lateral conteniendo las opciones de **Servidores** (Dashboard de VPS) y **Ajustes**.
2. **Deslizador Git (Git Status Slider):** Un botón junto al rayo de Prompts en la Consola que despliega un panel deslizante (hoja modal lateral/inferior) con un árbol visual de archivos y carpetas modificados. Al pulsar un archivo en este árbol, la app cambiará a la pestaña de Archivos, navegando a esa ruta exacta para ver el cambio.

---

## 🍔 1. Menú Hamburguesa & Navegación (Drawer)

### A. Estructura de Navegación en `home_view.dart`
Actualmente, [home_view.dart](file:///home/jguadalupeandrade/JhonG/KALA_Terminal/lib/views/home_view.dart) maneja 5 elementos fijos en el menú de navegación superior y un `IndexedStack` con 5 vistas:
0. `ConnectionsTab` (Conexiones)
1. `TerminalTab` (Consola)
2. `ExplorerTab` (Archivos)
3. `EditorTab` (Editor)
4. `SettingsTab` (Ajustes)

#### La Nueva Arquitectura:
Ampliaremos el `IndexedStack` a **6 vistas**, ocultando los botones directos de VPS y Ajustes en el menú superior para reemplazarlos por un botón de menú hamburguesa:

```
Índices del IndexedStack:
0 -> ConnectionsTab (CONEXIONES)
1 -> TerminalTab (CONSOLA)
2 -> ExplorerTab (ARCHIVOS)
3 -> EditorTab (EDITOR)
4 -> VpsTab (NUEVA PESTAÑA: Panel de Servidores)
5 -> SettingsTab (AJUSTES)
```

En la barra de navegación superior, los 5 botones visibles serán:
1. **CONEXIONES** (Icono: `dns_outlined`, activa índice 0)
2. **CONSOLA** (Icono: `terminal_outlined`, activa índice 1)
3. **ARCHIVOS** (Icono: `folder_outlined`, activa índice 2)
4. **EDITOR** (Icono: `code`, activa índice 3)
5. **MENÚ** (Icono: `menu`, abre el `endDrawer` del Scaffold en lugar de cambiar de pestaña)

### B. Implementación del `endDrawer` en [home_view.dart](file:///home/jguadalupeandrade/JhonG/KALA_Terminal/lib/views/home_view.dart)

Añadiremos una clave de Scaffold `final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();` para abrir el menú desde la barra de navegación superior:

```dart
// En _TopNavItem.onTap dentro de home_view.dart:
onTap: () {
  if (spec.label == 'MENÚ') {
    _scaffoldKey.currentState?.openEndDrawer();
  } else {
    context.read<AppState>().setActiveTabIndex(i);
  }
}
```

#### Renderizado del Highlight (Activo) del Menú:
Para que el botón "MENÚ" permanezca seleccionado si el usuario está viendo los Ajustes (índice 5) o el Servidor (índice 4):
```dart
final active = activeTabIndex == i || (i == 4 && (activeTabIndex == 4 || activeTabIndex == 5));
```

#### Diseño del Drawer (`MenuDrawer` en `lib/widgets/menu_drawer.dart`):
El drawer lateral utilizará el diseño oscuro estilo "flat IDE" de KALA (colores planos, fuentes monoespaciadas y bordes sutiles):

```dart
class MenuDrawer extends StatelessWidget {
  const MenuDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final hasRemoteSession = state.connectionStatus == ConnectionStatus.remote;

    return Drawer(
      backgroundColor: AppColors.ink,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cabecera del Menú
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('KALA - MENÚ', style: AppText.label(12, color: AppColors.bone, spacing: 1.5)),
            ),
            Hairline(),
            
            // Opción 1: Servidores (VPS Dashboard)
            ListTile(
              leading: Icon(Icons.dashboard_outlined, color: hasRemoteSession ? AppColors.accent : AppColors.muted),
              title: Text('SERVIDORES (VPS)', style: AppText.mono(11, color: hasRemoteSession ? AppColors.bone : AppColors.muted)),
              subtitle: Text(
                hasRemoteSession ? 'Monitorizar ${state.activeProfileName}' : 'Requiere conexión activa',
                style: AppText.body(9, color: AppColors.muted),
              ),
              onTap: hasRemoteSession ? () {
                Navigator.pop(context); // Cierra el Drawer
                state.setActiveTabIndex(4); // Va al Tab de VPS
              } : null, // Deshabilitado si no hay conexión SSH
            ),
            Hairline(),

            // Opción 2: Ajustes
            ListTile(
              leading: Icon(Icons.tune, color: AppColors.bone),
              title: Text('AJUSTES DE LA APP', style: AppText.mono(11, color: AppColors.bone)),
              onTap: () {
                Navigator.pop(context);
                state.setActiveTabIndex(5); // Va al Tab de Ajustes
              },
            ),
            Hairline(),
          ],
        ),
      ),
    );
  }
}
```

---

## 🌿 2. Deslizador Git (Git Tree Slide)

El deslizador de Git es una herramienta puramente visual diseñada para mostrar qué archivos han cambiado en el repositorio actual del terminal, sirviendo además como un atajo rápido de navegación.

### A. Ubicación del Botón
En la barra de herramientas de la terminal ([terminal_tab.dart](file:///home/jguadalupeandrade/JhonG/KALA_Terminal/lib/views/terminal_tab.dart)), al lado del botón de Prompts (rayo):

```dart
// En _buildToolbar de terminal_tab.dart:
_toolbarIcon(Icons.bolt_outlined, 'Prompts', () => _showPrompts(state)),
_toolbarIcon(Icons.commit, 'Cambios Git', () => _showGitSlider(context, state)),
```

### B. Obtención y Parseo de Datos Git
En `AppState` añadiremos un método para ejecutar `git status --porcelain` en la ruta de la sesión activa:

```dart
class GitChangedFile {
  final String status;        // M (Modificado), ?? (Untracked), A (Agregado), D (Eliminado)
  final String relativePath;  // ej. lib/main.dart
  final String absolutePath;  // ej. /home/user/project/lib/main.dart

  GitChangedFile({required this.status, required this.relativePath, required this.absolutePath});
}

// Dentro de AppState:
Future<List<GitChangedFile>> getGitStatus() async {
  final session = activeSession;
  if (session == null) return [];

  final currentDir = session.currentPath;
  String output = '';

  if (session.connectionStatus == ConnectionStatus.remote) {
    if (session.sshClient == null) return [];
    // Ejecuta el comando en el VPS en la ruta actual
    try {
      final s = await session.sshClient!.execute('cd "$currentDir" && git status --porcelain');
      output = await s.stdout.transform(utf8.decoder).join();
    } catch (e) {
      debugPrint('Error ejecutando git status remoto: $e');
    }
  } else {
    // Ejecuta de forma local (en la terminal Alpine de Android o Linux local)
    try {
      final res = await Process.run('git', ['status', '--porcelain'], workingDirectory: currentDir);
      output = res.stdout as String;
    } catch (e) {
      debugPrint('Error ejecutando git status local: $e');
    }
  }

  // Parsear la respuesta
  final List<GitChangedFile> files = [];
  final lines = const LineSplitter().convert(output);
  for (final line in lines) {
    if (line.length < 4) continue;
    final status = line.substring(0, 2).trim();
    final relative = line.substring(3).trim();
    // Remover comillas si el nombre tiene espacios
    final sanitizedRelative = relative.replaceAll('"', '');
    final absPath = currentDir.endsWith('/') ? '$currentDir$sanitizedRelative' : '$currentDir/$sanitizedRelative';
    
    files.add(GitChangedFile(
      status: status,
      relativePath: sanitizedRelative,
      absolutePath: absPath,
    ));
  }
  return files;
}
```

### C. Estructura de la Interfaz del Slide (Árbol Visual)
Pulsar el botón de Git abrirá una hoja modal inferior (`showModalBottomSheet`) con altura del 60% de la pantalla que contendrá:
1. **Lista jerárquica de cambios:** Agrupada por carpetas.
2. **Acción de Navegación Directa al Pulsar:**
   * Al pulsar un archivo en la lista, el modal se cierra, y llamamos a una función especial en `AppState` que redirige el explorador a ese directorio exacto y abre el archivo en el editor:

```dart
// Método en AppState para redirigir desde Git:
void navigateToGitFile(GitChangedFile file) async {
  // 1. Obtener la carpeta contenedora del archivo
  final parentDir = file.absolutePath.substring(0, file.absolutePath.lastIndexOf('/'));
  
  // 2. Navegar el explorador de archivos a esa carpeta
  await changeDirectory(parentDir);

  // 3. Si el archivo no está eliminado, abrirlo en el editor de código
  if (file.status != 'D') {
    // Buscar la información de entidad de archivo local/remoto para inyectarla al editor
    final fileEntity = FileSystemEntityInfo(
      name: file.relativePath.substring(file.relativePath.lastIndexOf('/') + 1),
      path: file.absolutePath,
      isDirectory: false,
      size: 0, // se leerá al abrir
      modified: DateTime.now(),
    );
    await openFile(fileEntity);
  } else {
    // Si fue eliminado, solo nos quedamos en el explorador
    setActiveTabIndex(2);
  }
}
```

### D. Diseño del Árbol Visual
Para emular un árbol visual en un listado plano, podemos ordenar alfabéticamente las rutas relativas de los archivos y dibujar sangrías (indentaciones) o íconos de rama:

* `lib/`
  * `└─ main.dart` 🟡 (M)
  * `└─ providers/`
    * `└─ app_state.dart` 🟡 (M)
* `propuestas/`
  * `└─ mejoras_productividad.md` 🟢 (??)

Cada estado de archivo tendrá su color correspondiente:
* `M` (Modified) -> Color amarillo/naranja.
* `??` (Untracked) o `A` (Added) -> Color verde.
* `D` (Deleted) -> Color rojo con texto tachado.

Esto proporciona un flujo ágil e inmediato para navegar por los cambios, ideal para pantallas táctiles donde buscar archivos modificados de forma manual es tedioso.
