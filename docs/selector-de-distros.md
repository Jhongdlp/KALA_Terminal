# Plan: Selector de distribución Linux (Alpine / Ubuntu / Debian)

> **Estado:** propuesta / pendiente de implementar
> **Objetivo:** permitir, desde **Ajustes**, elegir qué distro Linux usa la terminal local — manteniendo Alpine empaquetado (instantáneo) y ofreciendo Ubuntu/Debian **descargables** bajo demanda.

---

## 1. Idea general

- **Alpine** sigue **empaquetado en el APK** → la app abre y funciona al instante, sin internet.
- **Ubuntu / Debian** se **descargan bajo demanda** desde Ajustes (pesan demasiado para incluirlos en el APK).
- El usuario puede **cambiar entre distros** sin perder la otra (cada una en su carpeta).

Lo mejor de ambos mundos: **liviano por defecto, potente bajo demanda.**

---

## 2. UX propuesta (Ajustes › Entorno Linux)

```
AJUSTES › Entorno Linux
┌─────────────────────────────────────────┐
│  Distribución                            │
│                                          │
│  ◉  Alpine        Instalado · 9 MB       │
│        Ligero y rápido (musl · apk)      │
│                                          │
│  ○  Ubuntu 24.04        ↓ Descargar      │
│        Compatible y familiar (glibc·apt) │
│        ~45 MB                            │
│                                          │
│  ○  Debian 12           ↓ Descargar      │
│        Estable (glibc · apt)  ~40 MB     │
└─────────────────────────────────────────┘
```

Estados visibles por distro: **Instalado** / **Descargar** / **Descargando… (%)** / **Activa**.
Acciones: seleccionar (activar), descargar, **borrar** la que no se use (liberar espacio).

Principios de diseño:
- Alpine por defecto (cero fricción al abrir la app).
- Mostrar **tamaño** y **estado** claramente.
- Avisar que la descarga necesita Wi-Fi la primera vez.

---

## 3. Arquitectura

La base ya está lista: `DistroService` (`lib/services/distro_service.dart`) ya abstrae **instalar** y **lanzar** vía proot. Solo hay que **generalizarlo** de "Alpine fijo" a "N distros".

### 3.1. Descriptor de distro

```dart
class Distro {
  final String id;            // 'alpine' | 'ubuntu' | 'debian'
  final String name;          // 'Ubuntu 24.04'
  final String description;   // 'Compatible y familiar (glibc · apt)'
  final DistroSource source;  // asset empaquetado o URL de descarga
  final PackageManager pm;    // apk | apt  (para el wrapper `pkg`)
  final int approxSizeMb;
}
```

- `DistroSource`: `BundledAsset('assets/distro/alpine-...tar.gz')` **o** `RemoteTarball('https://.../ubuntu-base-...-arm64.tar.gz')`.
- Cada distro se instala en su **propia carpeta**: `<support>/distros/<id>/rootfs`.
- Un ajuste persistido guarda la **distro activa** (`shared_preferences`).

### 3.2. Generalizar `pkg`

El wrapper `pkg` (Termux-style) se genera según el gestor:
- **Alpine (apk):** `pkg install` → `apk add`, etc. (ya hecho).
- **Ubuntu/Debian (apt):** `pkg install` → `apt-get install -y`, `pkg update` → `apt-get update`, etc.

### 3.3. Lanzamiento (proot)

Sin cambios de fondo. Mismos args/flags que ya funcionan, apuntando a `rootfs` de la distro activa. El MOTD de **KALA** se mantiene igual.

---

## 4. Pasos de implementación (checklist)

- [ ] Definir `Distro` + catálogo (Alpine bundled, Ubuntu 24.04, Debian 12).
- [ ] Ajuste persistido `active_distro` en `AppState` + getters.
- [ ] Generalizar `DistroService`:
  - [ ] rutas por distro (`<support>/distros/<id>/...`).
  - [ ] `install()` que acepte asset **o** descarga con progreso.
  - [ ] wrapper `pkg` parametrizado por gestor (apk/apt).
  - [ ] `apk update` / `apt-get update` automático según distro.
- [ ] Descarga de tarball con **barra de progreso** + manejo de errores/reintento.
- [ ] UI en **Ajustes**: lista de distros, estado, descargar, activar, borrar.
- [ ] Al cambiar de distro activa: reiniciar la sesión local para que tome la nueva.
- [ ] Probar en dispositivo (igual que con Alpine): `pkg install`, `cd`, `ls`, Python.

---

## 5. Detalles técnicos a cuidar

- **Fuente del rootfs:**
  - Ubuntu: imagen oficial `ubuntu-base` arm64 (cdimage) **o** los tarballs de `proot-distro` (ya probados bajo proot).
  - Debian: rootfs de `proot-distro` o debootstrap pre-armado.
- **apt bajo proot:**
  - `DEBIAN_FRONTEND=noninteractive` para evitar prompts.
  - A veces hace falta `proot --link2symlink` por los **hardlinks** de dpkg.
  - `/etc/resolv.conf` con DNS (igual que en Alpine).
  - Puede requerir `apt-get update` antes del primer install.
- **glibc vs musl:** Ubuntu/Debian usan **glibc** → mayor compatibilidad con binarios precompilados y *wheels* de pip (`manylinux`). Es la principal ventaja sobre Alpine.
- **Espacio:** Ubuntu ocupa bastante más (extraído puede ser 150 MB+). Avisar y permitir borrar.
- **Red:** la descarga necesita conexión; manejar offline y reanudación.
- **targetSdk 28:** se mantiene (proot se ejecuta desde el data dir). Ver nota de proyecto sobre el pin de targetSdk.

---

## 6. Trade-offs (resumen)

| | Alpine (actual) | Ubuntu / Debian (descargable) |
|---|---|---|
| Tamaño | ~9 MB | ~150 MB+ extraído |
| Arranque | Instantáneo, sin internet | Requiere descarga la 1ª vez |
| libc | musl | **glibc** (más compatible) |
| Paquetes | `apk` (rápido, ~24k pkgs) | `apt` (familiar, ecosistema enorme) |
| Ideal para | Uso ligero, por defecto | Compatibilidad máxima / software que asume glibc |

---

## 7. Recomendación

- **Alpine = predeterminado** (app liviana, arranque instantáneo).
- **Ubuntu/Debian = "entorno completo" descargable** para quien quiera glibc/apt.
- Empezar la implementación por **Ubuntu 24.04** y probar en dispositivo paso a paso (como se hizo con Alpine).

---

## 8. Contexto / dónde está cada cosa

- Servicio del entorno: `lib/services/distro_service.dart`
- Integración del shell local: `_initLocalSession` en `lib/providers/app_state.dart`
- Assets actuales (Alpine): `assets/distro/` (proot, loader, libtalloc, libandroid-shmem, rootfs)
- Pin de `targetSdk 28`: `android/app/build.gradle.kts` (necesario para que proot se ejecute)
