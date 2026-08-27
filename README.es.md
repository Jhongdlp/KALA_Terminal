<div align="center">

<img src="public/icon/iconog.png" width="260" alt="KAMMEL SSH">

# KAMMEL SSH

**Un cliente SSH hecho para manejar agentes de IA desde el móvil.**

Terminal multi-sesión · explorador SFTP · editor de código · consola de Docker y bases de datos — todo en una app Flutter para Android y Linux.

[Read in English](README.md) · [kammel.app](https://www.kammel.app/)

[![Web](https://img.shields.io/badge/web-kammel.app-007AFF)](https://www.kammel.app/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter)](https://flutter.dev)
[![Plataformas](https://img.shields.io/badge/plataformas-Android%20%7C%20Linux-green)]()
[![Última versión](https://img.shields.io/github/v/release/Jhongdlp/Kammel_ssh?label=descargar)](https://github.com/Jhongdlp/Kammel_ssh/releases/latest)
[![PRs Welcome](https://img.shields.io/badge/PRs-bienvenidos-brightgreen.svg)](CONTRIBUTING.md)

</div>

---

## Qué es

Usar `ssh` desde el móvil suele ser un apaño: sin teclado decente, sin avisos, y la sesión se muere en cuanto cambias de app. KAMMEL SSH está construido alrededor del caso donde eso más duele: **ejecutar un agente de código TUI (Claude Code, Codex, Aider, Gemini CLI…) en un servidor remoto** y vigilarlo desde el bolsillo.

Por eso mantiene la shell viva en segundo plano, **te avisa cuando el agente se detiene y necesita respuesta**, y añade teclado táctil, explorador de archivos, editor y panel de git para que nunca tengas que teclear una ruta a mano.

Y si solo quieres una shell, también es un cliente SSH normal y rápido.

## ✨ Características

### Terminal
- **SSH multi-sesión** — varios servidores abiertos a la vez, cambias con un toque, los renombras y cierras como pestañas del navegador. Reconexión en el sitio cuando se cae una sesión.
- **Persistencia con tmux** — actívalo por perfil y, si se cae la conexión, se reengancha a la sesión remota que sigue viva en lugar de perder el trabajo.
- **Sigue vivo en segundo plano** — un servicio en primer plano de Android mantiene todas las shells corriendo mientras estás en otra app (como hace Termux).
- **Teclado inteligente** — fila de teclas rápidas configurable (Ctrl, Esc, Tab, flechas, pipes, comandos frecuentes) con tres distribuciones: clásica de doble fila, o D-pad a la izquierda / a la derecha. Cada tecla es editable, reordenable, y puedes añadir las tuyas.
- **Teclado de verdad** — sugerencias, autocorrección y dictado por voz funcionan dentro de la terminal (el `xterm` original fuerza un teclado "incógnito" que lo desactiva todo; aquí va una copia parcheada).
- **Selección, copiar, pegar y detección de enlaces** — toca una URL de la salida y se abre en el navegador.
- **Adjuntar lo que sea** — eliges un archivo del móvil y su ruta se inserta en el prompt, lista para que el agente la lea.
- **Pegar imágenes en el prompt** — desde el portapapeles o Gboard. La imagen se sube por SFTP como `pasted_image_<timestamp>.png` en el directorio actual y el nombre se escribe solo.

### Soporte para agentes de IA (la razón de ser de la app)
- **Detección de agente** — reconoce Claude Code, Codex, Gemini CLI, Aider, OpenCode, Copilot CLI, Cursor, Qwen Code y Antigravity a partir de la línea de comandos y del título de ventana, incluso a través de envoltorios como `npx`, `sudo` o `uvx`.
- **Avisos de "el agente te necesita"** — cuando una sesión en segundo plano se queda quieta tras un rato de trabajo, hace una pregunta, o suena la campana de la terminal / emite `OSC 9` u `OSC 777`, recibes una notificación con un fragmento de la pantalla y el distintivo del agente. Al tocarla saltas a esa sesión.
- **Intensidad por tipo de aviso** — cada clase de alerta va a su propio canal de Android: emergente, solo sonido, silencioso u off. Puedes silenciar sesiones concretas y enviar notificaciones de prueba desde Ajustes.
- **Tablero de agentes** — una pantalla con cada sesión abierta según lo que está haciendo ahora mismo: esperándote, trabajando, terminada, en el prompt o sin conexión, con la pregunta que te hace, desde hace cuánto y en qué máquina. Ordenado para que la que te necesita quede arriba, con un contador en el menú para saberlo sin abrirlo. Responde `y`/`n`/Enter/Esc o escribe desde la propia tarjeta — si la máquina está marcada como *producción*, te pide confirmación.
- **Lanzadores de agente** — una rejilla con los logos reales detrás del botón AGENTES de la terminal (y del radial del pad táctil). Cada uno lleva su propio comando, así que `claude --dangerously-skip-permissions` es un toque y no una errata en el teclado del móvil; y si sale un agente nuevo, lo añades tú: nombre, comando e icono.
- **Prompts guardados** — guarda instrucciones recurrentes e insértalas con un toque en vez de escribir un párrafo en el teclado del móvil.
- **Dictado por voz** en el compositor de prompts.
- **Panel de git** — ve los cambios pendientes del proyecto, abre un archivo modificado, escribe un commit, o **delega en la IA** ("haz add -A, commit con un mensaje sensato y push") con un solo toque.

### Conexiones
- **Perfiles** — host, puerto, usuario, contraseña o clave privada, guardados y reutilizables.
- **Pegar un comando SSH** — sueltas `ssh -p 2222 user@host -L 8080:localhost:80` y el perfil se rellena solo.
- **Color por máquina** — das a un perfil un color de señal (y una marca opcional de *producción*) y esa máquina queda marcada en todas partes: la lista de conexiones, el selector de sesiones, una franja sobre la propia terminal y la barra de título en escritorio. Cuatro terminales negras idénticas dejan de ser idénticas.
- **Servidores de salto (`ProxyJump`)** — llega a una máquina que solo responde desde dentro, encadenando por un bastión que ya tienes como perfil. Hasta cinco saltos, cada uno autenticado y con su propia llave de host fijada; el selector rechaza los ciclos antes de que puedas guardarlos.
- **Llave SSH del dispositivo** — genera una identidad ed25519 que vive en el almacenamiento seguro del móvil y nunca sale de ahí. Copias la línea pública en el `~/.ssh/authorized_keys` del servidor y entras sin contraseña.
- **Secretos en el keystore del sistema** — contraseñas y claves privadas van al Keystore de Android / libsecret vía `flutter_secure_storage`, no a preferencias en claro.
- **Bloqueo de la app** — desbloqueo opcional con biometría o credencial del dispositivo, al abrir y al volver.
- **Túneles locales** — declara reenvíos `-L` en un perfil y se abren automáticamente con la sesión.

### Archivos y editor
- **Explorador SFTP** — navega, busca, filtra por tipo, muestra u oculta ocultos, selección múltiple, copiar/mover/pegar, borrar y crear.
- **Transferencias en ambos sentidos** — sube archivos desde el móvil y descarga la selección a él, con progreso y detalle de errores por archivo.
- **Editor de código** — `re_editor` con resaltado de sintaxis, indicador de cambios sin guardar y guardado por SFTP. La conexión de edición se captura al abrir, así que cambiar de sesión no rompe el archivo que estás editando.
- **Visores integrados** — Markdown (con zoom y modo previsualización), PDF, imágenes incluido SVG, y **reproducción de vídeo y audio** con `media_kit` y barra de reproducción.
- **Documentos externos** — Word, Excel, PowerPoint, EPUB, ZIP y APK se abren con las apps del sistema; el archivo temporal se limpia después.
- **Sincronía terminal ↔ explorador** — opcionalmente el explorador sigue el directorio de trabajo de la shell, o abres una terminal en cualquier carpeta.

### Consola del servidor
- **Monitor** — carga de CPU, RAM, disco y servicios del sistema de un vistazo.
- **Docker** — contenedores (arrancar/parar/logs/stats), imágenes, volúmenes, redes y stacks de compose.
- **Sistema** — resumen de recursos y configuración, con modo auditoría y analíticas.
- **Bases de datos** — asocia perfiles PostgreSQL / MySQL a un servidor (incluidas instancias dentro de un contenedor) y consúltalas desde la misma consola.

### App
- **Temas** — sistema / claro / oscuro / OLED negro puro, con selector de color de acento.
- **Estilo de terminal** — Dracula, Gruvbox, Nord o "seguir el tema de la app", tamaño de fuente, y elección entre Cascadia Code, JetBrains Mono, Fira Code, Source Code Pro, Inconsolata o Anonymous Pro.
- **Densidad de iconos** y tamaño de las teclas rápidas, para pantallas pequeñas y pulgares grandes.
- **Actualizaciones dentro de la app** — consulta GitHub Releases e instala el nuevo APK por ti.
- **Interfaz en español**.

## 📦 Instalación

**Android:** descarga el APK de la [última release](https://github.com/Jhongdlp/Kammel_ssh/releases/latest). A partir de ahí la app se actualiza sola.

**Linux:** compila desde el código (abajo).

## 📱 Plataformas

| Plataforma | Estado |
|------------|--------|
| Android    | ✅ Soportado (objetivo principal) |
| Linux      | ✅ Soportado (escritorio) |
| iOS / Windows / macOS | ❌ No configurado |

## 🚀 Empezar (desde el código)

### Requisitos

- [Flutter](https://docs.flutter.dev/get-started/install) 3.44+ (Dart 3.12+).
  Este repo incluye un SDK completo de Flutter en `sdk/flutter`; si no tienes `flutter` en el `PATH`, usa `sdk/flutter/bin/flutter` en los comandos de abajo.
- Para Android: SDK de Android + un dispositivo o emulador.
- Para Linux: las [dependencias de escritorio de Flutter](https://docs.flutter.dev/platform-integration/linux/setup) (`clang`, `cmake`, `ninja-build`, `libgtk-3-dev`, …).

### Compilar y ejecutar

```bash
git clone https://github.com/Jhongdlp/Kammel_ssh.git
cd Kammel_ssh

flutter pub get

# Ejecutar en Linux
flutter run -d linux

# Ejecutar en Android
flutter run -d <id-del-dispositivo>

# Builds de release
flutter build apk          # Android
flutter build linux        # Linux
```

### Primera conexión

1. Pestaña **Conexiones** → **+** → rellena host/usuario, o pega un comando `ssh …` completo.
2. Opcionalmente activa la **llave del dispositivo** (Ajustes → *Llave SSH del dispositivo*) y copia la línea pública en el `~/.ssh/authorized_keys` del servidor.
3. Toca el perfil para conectar. Se abre la pestaña de terminal con la sesión.
4. Lanza tu agente (`claude`, `codex`, `aider`, …). Sal de la app: te llegará una notificación cuando te necesite.

### Notas sobre la build de Android

- `targetSdk` está fijado a propósito en **28** en `android/app/build.gradle.kts` por compatibilidad con el almacenamiento compartido legacy.
- `MainActivity` debe seguir siendo un `FlutterFragmentActivity`; `local_auth` lo necesita para el bloqueo de la app.
- La terminal usa una **copia parcheada y vendorizada de `xterm`** en `third_party/xterm`, enganchada por `dependency_overrides`. Las sugerencias de teclado, el dictado y el pegado de imágenes viven ahí, no en el paquete original.

## 🏗 Arquitectura

```
lib/
├── main.dart               # Entrada de la app, Provider raíz
├── providers/
│   └── app_state.dart      # Un único ChangeNotifier con TODO el estado
├── models/                 # ConnectionProfile, SshTunnel, PromptSnippet,
│                           # TerminalShortcut, NotificationPrefs, perfiles de BD
├── services/
│   ├── secure_store.dart       # Secretos en Keystore/libsecret
│   ├── device_key.dart         # Identidad SSH ed25519 en el dispositivo
│   ├── app_lock.dart           # Bloqueo biométrico / por credencial
│   ├── background_service.dart # Servicio en primer plano (mantiene las shells)
│   ├── notification_service.dart # Canales de avisos de agente
│   ├── agent_screen.dart       # Clasificadores puros: ¿trabaja, pregunta o está quieta?
│   ├── agent_monitor.dart      # Estado de agente por sesión (tablero de agentes)
│   ├── server_controller.dart  # Consola de servidor + Docker + BD
│   └── update_service.dart     # Actualizaciones desde GitHub Releases
├── theme/                  # Temas, paletas de terminal, resaltado del editor
├── views/                  # Un archivo por pestaña/pantalla
└── widgets/
```

Decisiones de diseño clave:

- **Una única fuente de verdad**: todo el estado vive en `AppState` (`ChangeNotifier` + `provider`). Las funciones nuevas con estado extienden `AppState`, no usan estado local de widget que muere al cambiar de pestaña.
- **Sesiones**: `AppState` guarda una lista de `TerminalSession`, cada una con su propio `xterm.Terminal` y su cliente `dartssh2`. Solo una está activa; la mayoría de los getters delegan en ella.
- **Todo lo remoto va por SFTP**: listado, navegación, edición y transferencias usan el cliente SFTP de la sesión.
- **La detección de agente es heurística y local** — lee la salida de la propia terminal y los comandos escritos. No se envía nada a ningún sitio.

Para más detalle, ver [CLAUDE.md](CLAUDE.md).

## 🔒 Privacidad

KAMMEL SSH habla con tus servidores y con la API de GitHub Releases (comprobación de actualizaciones). Nada más. No hay telemetría, ni cuenta, ni backend — las credenciales no salen del dispositivo.

## 🗺 Hoja de ruta

Ya hecho desde la última vez que se escribió esta lista:

- [x] Túneles dinámicos (`-D`, SOCKS5) y remotos (`-R`), con cierre por inactividad
- [x] Interfaz traducida por completo: español, inglés y chino simplificado
- [x] Servidores de salto (`ProxyJump`), con la llave de host fijada en cada salto
- [x] Suite de tests real (más de 270; `flutter test`)

Pendiente:

- [ ] Editor: buscar y reemplazar, pestañas multi-archivo
- [ ] Mejoras de autenticación por clave: claves con passphrase, reenvío de agente
- [ ] Responder desde la propia notificación, sin abrir la app
- [ ] Detectar agentes en sesiones `tmux` desprendidas, no solo en pestañas abiertas
- [ ] Transferencias SFTP que se reanuden tras cortarse la conexión

¿Tienes una idea? [Abre un issue](https://github.com/Jhongdlp/Kammel_ssh/issues/new).

## 🤝 Contribuir

¡Las contribuciones son muy bienvenidas! Lee [CONTRIBUTING.md](CONTRIBUTING.md) para el flujo de trabajo, las convenciones de código y cómo preparar el entorno.

¿Has encontrado un fallo de seguridad? Repórtalo en privado por [GitHub Security Advisories](https://github.com/Jhongdlp/Kammel_ssh/security/advisories/new) en vez de abrir un issue público.

## 📄 Licencia

[MIT](LICENSE).

### Componentes de terceros incluidos

| Componente | Licencia | Uso |
|------------|----------|-----|
| [Cascadia Code](https://github.com/microsoft/cascadia-code) (`assets/fonts/`) | SIL OFL 1.1 | Fuente de terminal/editor |
| [xterm.dart](https://github.com/TerminalStudio/xterm.dart) (`third_party/xterm/`, parcheado) | MIT | Emulador de terminal |

Estos componentes se distribuyen junto a la app bajo sus propias licencias.
