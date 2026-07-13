# KALA

> Terminal, cliente SSH, explorador de archivos y editor de código — todo en una sola app Flutter para Android y Linux, pensada para móvil.

[Read in English](README.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter)](https://flutter.dev)
[![Plataformas](https://img.shields.io/badge/plataformas-Android%20%7C%20Linux-green)]()
[![PRs Welcome](https://img.shields.io/badge/PRs-bienvenidos-brightgreen.svg)](CONTRIBUTING.md)

KALA convierte tu teléfono en una máquina de desarrollo real. Combina un emulador de terminal multi-sesión, un gestor de conexiones SSH, un explorador de archivos remoto y un editor de código con resaltado de sintaxis, todo bajo una interfaz oscura estilo IDE.

## ✨ Características

- **Gestor de conexiones SSH** — guarda perfiles de conexión (host, puerto, usuario, contraseña o clave privada). Los secretos se guardan en el Keystore de Android / libsecret mediante almacenamiento seguro, nunca en texto plano.
- **Terminales multi-sesión** — ejecuta varias sesiones SSH a la vez, cambia entre ellas con un toque, renómbralas y ciérralas como pestañas de navegador.
- **Pegado de imágenes en la terminal** — pega imágenes directamente desde el portapapeles o teclados como Gboard. Las sube automáticamente vía SFTP como `pasted_image_timestamp.png` en el directorio activo, escribe el nombre del archivo en la entrada de la terminal y actualiza el explorador.
- **Explorador de archivos remoto** — navega el sistema de archivos remoto por SFTP. Abre, navega y edita archivos.
- **Editor de código** — basado en [re_editor](https://pub.dev/packages/re_editor) con resaltado de sintaxis, indicador de cambios sin guardar, y guardado transparente por SFTP para archivos remotos.
- **Panel de control unificado Cloud-Console** — monitorea recursos del sistema (CPU, RAM, disco, servicios) y gestiona por completo contenedores Docker, imágenes, volúmenes, redes, compose y configuraciones del sistema.
- **Visor nativo de documentos Office y externos** — abre archivos de Word, Excel, PowerPoint, EPUB, ZIP y APK de forma nativa usando las aplicaciones del sistema. Los archivos remotos se descargan temporalmente y se eliminan de forma automática al finalizar.
- **Visores integrados** — renderiza archivos Markdown y PDF sin salir de la app.
- **Teclado inteligente** — una fila de acceso rápido sobre la terminal con Ctrl+C, flechas, tab y comandos comunes, diseñada para pantallas táctiles.
- **Tema oscuro estilo IDE** — interfaz plana oscura con Cascadia Code como fuente de terminal.

## 📱 Plataformas

| Plataforma | Estado |
|------------|--------|
| Android    | ✅ Soportada (objetivo principal) |
| Linux      | ✅ Soportada (escritorio) |
| iOS / Windows / macOS | ❌ No configuradas |

## 🚀 Primeros pasos

### Requisitos

- [Flutter](https://docs.flutter.dev/get-started/install) 3.44+ (Dart 3.12+).
  Este repo incluye un SDK de Flutter completo en `sdk/flutter`; si no tienes Flutter en el `PATH`, usa `sdk/flutter/bin/flutter` en lugar de `flutter` en los comandos siguientes.
- Para compilar en Android: Android SDK + un dispositivo o emulador Android.
- Para compilar en Linux: las [dependencias estándar de Flutter para escritorio Linux](https://docs.flutter.dev/platform-integration/linux/setup) (`clang`, `cmake`, `ninja-build`, `libgtk-3-dev`, …).

### Compilar y ejecutar

```bash
git clone https://github.com/Jhongdlp/TerminalAI.git
cd TerminalAI

flutter pub get

# Ejecutar en Linux escritorio
flutter run -d linux

# Ejecutar en Android
flutter run -d <id-del-dispositivo>

# Builds de release
flutter build apk          # Android
flutter build linux       # Linux
```

### Nota sobre `targetSdk` en Android

El `targetSdk` está fijado intencionalmente en **28** en `android/app/build.gradle.kts` para mantener la compatibilidad con el almacenamiento compartido legacy.

## 🏗 Arquitectura

```
lib/
├── main.dart              # Punto de entrada, Provider raíz
├── providers/
│   └── app_state.dart     # ChangeNotifier único con TODO el estado de la app
├── models/                # ConnectionProfile, modelos de sesión/archivos
├── services/
│   ├── secure_store.dart      # Secretos en Keystore/libsecret
│   └── background_service.dart
├── theme/                 # Tema oscuro IDE + temas de resaltado del editor
├── views/                 # Un archivo por pestaña (terminal, explorador, editor…)
└── widgets/
```

Decisiones de diseño clave:

- **Una sola fuente de verdad**: todo el estado vive en `AppState` (`ChangeNotifier` + `provider`). Las funcionalidades nuevas con estado deben extender `AppState`, no añadir estado local de widget que se pierde al cambiar de pestaña.
- **Sesiones**: `AppState` mantiene una lista de `TerminalSession`, cada una con su propio `xterm.Terminal` más un cliente SSH (`dartssh2`). Solo una sesión está activa a la vez.
- **Integración SFTP**: el listado, navegación y edición de archivos se realizan de forma remota a través de SFTP.

Consulta [CLAUDE.md](CLAUDE.md) para un recorrido más profundo por la arquitectura.

## 🗺 Hoja de ruta

- [ ] Selector de distros (Alpine / Ubuntu / Debian) — ver `docs/selector-de-distros.md`
- [ ] Port forwarding / túneles SSH
- [ ] Editor: buscar y reemplazar, pestañas multi-archivo
- [ ] Traducciones (la interfaz actual está en español)
- [ ] Suite de tests real (el `widget_test.dart` actual sigue siendo la plantilla de Flutter)

¿Tienes una idea? [Abre una petición de funcionalidad](../../issues/new/choose).

## 🤝 Contribuir

¡Las contribuciones son muy bienvenidas! Lee [CONTRIBUTING.md](CONTRIBUTING.md) para conocer el flujo de trabajo, las convenciones de código y cómo preparar tu entorno, además de nuestro [Código de Conducta](CODE_OF_CONDUCT.md).

¿Encontraste un problema de seguridad? Sigue [SECURITY.md](SECURITY.md) en lugar de abrir un issue público.

## 📄 Licencia

Este proyecto está licenciado bajo la [Licencia MIT](LICENSE).

### Componentes de terceros incluidos

| Componente | Licencia | Uso |
|------------|----------|-----|
| [Cascadia Code](https://github.com/microsoft/cascadia-code) (`assets/fonts/`) | SIL OFL 1.1 | Fuente de terminal/editor |

Estos componentes se distribuyen junto a la app bajo sus propias licencias.
