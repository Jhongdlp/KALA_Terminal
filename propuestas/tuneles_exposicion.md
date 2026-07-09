# Propuesta Detallada: Túneles de Exposición y Port Forwarding

Este documento detalla la funcionalidad y el diseño técnico propuesto para implementar túneles de red y exposición de puertos en **KALA**, diferenciándolos de la configuración básica de SSH disponible actualmente.

---

## 1. Contexto y Objetivos

Actualmente, KALA permite definir port forwarding local estático (`-L`) dentro del perfil de conexión antes de iniciar la sesión. Esto redirige un puerto remoto a `localhost` en el teléfono móvil de manera interna.

El objetivo de esta propuesta es añadir:
1. **Túneles en Caliente (On-the-fly):** Habilidad de abrir y cerrar túneles SSH locales y remotos dinámicamente durante una sesión activa, sin tener que desconectarse.
2. **Exposición Pública (Cloudflare Tunnels / Ngrok):** Generar una URL web HTTPS pública y temporal con un solo switch para probar servicios expuestos (tanto en el VPS como en la terminal local Alpine de la app) desde cualquier dispositivo con internet.

---

## 2. Diferencias con el Port Forwarding Estático Actual

| Característica | Port Forwarding Estático Actual (`-L`) | Exposición Pública y Dinámica (Nueva Propuesta) |
| :--- | :--- | :--- |
| **Acceso** | **Privado:** Solo accesible desde el dispositivo móvil (`localhost:puerto`). | **Público:** Enlace HTTPS accesible por cualquier usuario o servicio en internet. |
| **Interactividad** | **Estática:** Requiere desconectar y editar el perfil de conexión. | **En Caliente:** Se activa/desactiva mediante un switch en la UI durante la sesión. |
| **Protocolo** | TCP / SSH crudo. | HTTPS seguro con certificado SSL automático y QR. |
| **Caso de uso** | Acceder a base de datos de producción desde el cliente DB del móvil. | Exponer una web a un cliente, testear en varios dispositivos o probar Webhooks (Stripe, etc.). |
| **Dirección** | Mapea puerto de VPS -> Móvil. | Mapea VPS o Alpine local -> Internet pública. |

---

## 3. Arquitectura e Implementación Técnica

### A. Túneles SSH Dinámicos (Port Forwarding en caliente)
Utilizando la librería `dartssh2` ya integrada en la app:
* **Túnel Local (`-L`):** KALA escucharará en un puerto del móvil y enviará las conexiones por el canal SSH activo.
* **Túnel Remoto (`-R`):** KALA configurará el canal SSH remoto para reenviar un puerto del VPS al puerto local del Alpine en el teléfono.
* *Lógica:* Se implementa un gestor dinámico de puertos vinculados al `SSHClient` activo en el `AppState`.

### B. Exposición Pública (Cloudflare / Ngrok)
1. **En el VPS Remoto:**
   - KALA ejecuta un comando en segundo plano sobre la sesión SSH activa.
   - Descarga un binario estático y liviano de `cloudflared` (Cloudflare Tunnel client) en `/tmp/` del VPS.
   - Ejecuta: `/tmp/cloudflared tunnel --url http://localhost:<puerto>`.
   - Parsea la consola del comando en segundo plano mediante expresiones regulares para extraer la URL pública generada (ej. `https://*.trycloudflare.com`).
   - Muestra la URL en la interfaz con botón de copiar y un código QR generado localmente.
   - Al apagar el switch, KALA envía la señal de terminación (SIGINT/SIGKILL) al proceso `cloudflared`.

2. **En la Terminal Local del Móvil (Alpine/proot):**
   - KALA preinstala o descarga bajo demanda el binario de `cloudflared` para la arquitectura correspondiente (aarch64).
   - Cuando el usuario levanta un servicio local (ej. Python, Node), puede ir al panel de red en KALA, elegir el puerto local y activar la exposición pública.
   - KALA ejecuta el túnel dentro de Alpine y expone la URL al internet.

---

## 4. Diseño de la Interfaz de Usuario (Mockup)

```
┌──────────────────────────────────────────────┐
│  🌐 RED Y TÚNELES (VPS: Hetzner-1)           │
├──────────────────────────────────────────────┤
│  TÚNELES SSH ACTIVOS (Privados)              │
│  ● 5432 -> localhost:5432 (Postgres)  [🗑️]   │
│  [+] Añadir túnel en caliente                │
├──────────────────────────────────────────────┤
│  EXPOSICIÓN PÚBLICA (HTTPS Web)              │
│  Puerto local en VPS: [ 3000 ]               │
│                                              │
│  [ Switch: Habilitar URL Pública ] (Activo)  │
│                                              │
│  🔗 Enlace temporal:                         │
│  https://servidor-kala-xyz.trycloudflare.com │
│                                              │
│  [  Copiar Enlace  ]    [  Ver Código QR  ]  │
└──────────────────────────────────────────────┘
```

Esta característica transformará la forma en que los desarrolladores interactúan con puertos y APIs, ofreciendo una experiencia visual y fluida directamente desde su dispositivo móvil.
