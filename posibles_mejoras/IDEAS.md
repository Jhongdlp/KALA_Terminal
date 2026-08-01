# Posibles mejoras — KALA

Catálogo de ideas de funcionalidades para la app. **Restricción de diseño: todo 100% local en el
dispositivo, sin ningún componente de IA ni servicios en la nube.**

Estado: lluvia de ideas / backlog sin priorizar (salvo la sección final).

---

## 1. Conectividad y red

| # | Idea | Notas de implementación |
|---|------|-------------------------|
| 1 | **Túneles SSH (port forwarding)** | Local (`-L`), remoto (`-R`) y SOCKS (`-D`). `dartssh2` expone `forwardLocal`/`forwardRemote`. Panel de túneles activos con toggle por perfil. Ver documento dedicado. |
| 2 | **Escáner de red LAN** | Barrer la subred del wifi, detectar hosts con 22/80/443 abiertos y ofrecer "crear perfil desde este host". Ideal para homelab. |
| 3 | **Ping / traceroute / port check** | Pestaña de herramientas de red; puede ser un wrapper con UI sobre el terminal local (Alpine/proot). |
| 4 | **Wake-on-LAN** | Guardar la MAC en `ConnectionProfile`; botón "despertar" antes de conectar (paquete mágico UDP al broadcast). |
| 5 | **Auto-reconexión + keepalive** | Backoff exponencial y reanudar sesiones al volver del background. Crítico en Android, que mata conexiones agresivamente. |
| 6 | **Perfiles multi-ruta** | "Si estoy en el wifi X conecta por IP local, si no por hostname público". Un perfil, dos rutas de conexión. |

## 2. Credenciales y gestión de perfiles

| # | Idea | Notas de implementación |
|---|------|-------------------------|
| 7 | **Claves SSH generadas en el dispositivo** | ed25519/RSA, almacenadas con `flutter_secure_storage` (Android Keystore). Botón "copiar clave pública" e "instalar en servidor" (append a `~/.ssh/authorized_keys` por SFTP). |
| 8 | **Desbloqueo biométrico** | De la app completa o solo de perfiles marcados como sensibles (`local_auth`). |
| 9 | **Import / export de perfiles** | Archivo cifrado con passphrase. Además, importar hosts desde un `~/.ssh/config`. |
| 10 | **Verificación de host key** | `known_hosts` local + aviso claro ante cambio de fingerprint. Actualmente se acepta cualquier clave: agujero de seguridad real (MITM). |
| 11 | **Carpetas, tags y colores por perfil** | Color de la barra de sesión heredado del perfil, para no confundir producción con desarrollo. |
| 12 | **Jump host / ProxyJump** | Conectar a través de un bastión encadenando clientes SSH. |

> **Deuda técnica relacionada:** hoy las contraseñas se guardan en texto plano en
> `shared_preferences` (ver `CLAUDE.md`). Las ideas 7–10 la resuelven.

## 3. Terminal

| # | Idea | Notas de implementación |
|---|------|-------------------------|
| 13 | **Snippets / comandos guardados** | Con parámetros tipo `{{host}}`, `{{path}}`. Extensión natural de la "smart keyboard" existente. |
| 14 | **Historial de comandos buscable** | Por sesión y global, con re-ejecución de un tap. |
| 15 | **Grabación de sesión** | Estilo asciinema; exportar log a texto plano. |
| 16 | **Split screen / multi-panel** | En landscape o tablet, aprovechando el modelo multi-sesión ya existente. |
| 17 | **Broadcast a varias sesiones** | Escribir un comando y enviarlo a N servidores a la vez (`apt update` en todos). |
| 18 | **Macros al conectar** | Comandos ejecutados automáticamente al abrir sesión (`cd /var/www && tmux attach`). |
| 19 | **Fila rápida personalizable** | Que el usuario defina sus propios botones del teclado inteligente. |
| 20 | **Búsqueda en el scrollback** | Con resaltado de coincidencias. |

## 4. Explorador de archivos (SFTP)

| # | Idea | Notas de implementación |
|---|------|-------------------------|
| 21 | **Cola de transferencias con progreso** | Subida/bajada reanudables, en background con foreground service + notificación. |
| 22 | **Previsualización de medios** | Imágenes, PDF y vídeo remotos leídos por chunks, sin descargar el archivo completo. |
| 23 | **Sincronización de carpetas** | Mirror manual local ↔ remoto con diff por fecha/tamaño. |
| 24 | **Bookmarks de rutas** | Favoritos por perfil + "ir a ruta" rápido. |
| 25 | **Operaciones masivas** | Selección múltiple, `chmod`/`chown` visual, comprimir/descomprimir (`tar`, `zip`) vía comando remoto. |
| 26 | **Búsqueda remota de archivos** | `find` / `grep` con resultados clicables que abren el editor en la línea exacta. |
| 27 | **Papelera / undo** | Mover a `~/.kala-trash` en lugar de `rm` directo. |

## 5. Editor

| # | Idea | Notas de implementación |
|---|------|-------------------------|
| 28 | **Buscar y reemplazar con regex** | Más "ir a línea". |
| 29 | **Resaltado de sintaxis por extensión** | `re_editor` ya trae temas; detectar indentación del archivo. |
| 30 | **Autoguardado + versiones locales** | Copia local antes de cada guardado remoto, para recuperar si algo se rompe. |
| 31 | **Integración git básica** | `status`, `diff`, `add`, `commit`, `push` con UI, ejecutado sobre la sesión SSH. Gran valor para el caso de uso "IDE móvil". |
| 32 | **Diff local vs remoto antes de guardar** | Detecta que otra persona modificó el archivo mientras se editaba. |

## 6. Monitorización (dashboard de servidor)

| # | Idea | Notas de implementación |
|---|------|-------------------------|
| 33 | **Panel de estado del host** | CPU, RAM, disco, uptime, load, top procesos; parseando `/proc`, `df`, `ps` cada X segundos. Muy vistoso y sin dependencias externas. |
| 34 | **Gestor de procesos** | Listar y matar procesos; ver puertos abiertos (`ss -tulpn`). |
| 35 | **Visor de logs en vivo** | `tail -f` con filtros y resaltado de errores, en pestaña propia. |
| 36 | **Alertas locales** | Notificar si el disco supera el 90% o si un host deja de responder (`workmanager` en background). Se combina con las notificaciones ya implementadas. |
| 37 | **Gestor de servicios systemd / Docker** | `docker ps` con UI, start/stop/logs de contenedores. Caso de uso enorme en móvil. |

## 7. Terminal local (Alpine vía proot)

| # | Idea | Notas de implementación |
|---|------|-------------------------|
| 38 | **Gestor de paquetes con UI** | Buscar/instalar paquetes `apk` sin escribir comandos; "packs" recomendados (python, node, git…). |
| 39 | **Servidor de archivos local** | Compartir archivos del móvil por wifi con un QR. |
| 40 | **Acceso al almacenamiento del teléfono** | Montar `/sdcard` dentro del proot, con atajo en el explorador. |
| 41 | **Tareas programadas** | Cron local dentro del proot con UI para ver/editar tareas. |

## 8. Calidad de vida

| # | Idea | Notas de implementación |
|---|------|-------------------------|
| 42 | **Widget / accesos directos** | Conectar a un perfil favorito de un tap desde la pantalla de inicio. |
| 43 | **Temas y tamaño de fuente** | Presets del terminal (Dracula, Nord, Gruvbox). |
| 44 | **Soporte de teclado físico** | Landscape + atajos Ctrl/Alt/Tab con teclados bluetooth. |
| 45 | **Portapapeles compartido** | Entre terminal, editor y explorador, con historial. |
| 46 | **Gestos** | Swipe para cambiar de sesión, pinch para zoom de fuente. |
| 47 | **Modo "producción" / solo lectura** | Confirmación antes de comandos destructivos (`rm -rf`, `reboot`, `dd`). |

---

## Priorización sugerida (valor / esfuerzo)

1. **Claves SSH + almacenamiento seguro + `known_hosts`** (#7, #8, #10) — resuelve la deuda de
   seguridad actual y desbloquea el resto.
2. **Túneles SSH** (#1) — feature estrella y diferenciadora; `dartssh2` ya la soporta.
3. **Snippets y macros de comandos** (#13, #18) — barata y encaja con la smart keyboard existente.
4. **Cola de transferencias con progreso en background** (#21) — el SFTP actual se siente incompleto
   sin esto.
5. **Dashboard de monitorización del host** (#33) — muy vistosa y es pura lectura de `/proc`.
