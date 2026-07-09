# Compendio de Ideas y Mejoras para KALA

Este documento recopila las ideas, funciones y mejoras propuestas para transformar **KALA** en un ecosistema de desarrollo móvil y administración de VPS avanzado, diseñado para la integración con Agentes de IA.

---

## 🗺️ Visión del Proyecto

El objetivo es evolucionar KALA de un cliente de terminal móvil simple a una herramienta completa para administradores de sistemas y desarrolladores web. El foco está puesto en la **automatización, la portabilidad y la inteligencia artificial**.

---

## 1. Módulo de Gestión de VPS Avanzada (VPS Dashboard)
Proporcionar una interfaz gráfica que se comunique con el VPS a través de SSH en segundo plano, ejecutando comandos del sistema y parseando sus resultados para no requerir la instalación de ningún agente pesado en el servidor.

* **Panel de Métricas:** Gráficos visuales del uso de CPU, memoria RAM, almacenamiento en disco y tráfico de red en tiempo real.
* **Administrador de Procesos:** Tabla visual interactiva (parseada de `ps aux` o `top`) que permita ordenar procesos por consumo de recursos y terminarlos (`kill`) con un toque.
* **Gestor de Servicios Systemd:** Interfaz gráfica para listar, iniciar, detener, reiniciar y visualizar los últimos logs de servicios de sistema (ej. Nginx, Docker, PostgreSQL).
* **Biblioteca de Scripts Automatizados:** Scripts en un clic para tareas de inicialización (ej. configurar firewall, instalar Docker, certificar dominios SSL con Let's Encrypt).

---

## 2. Integración de Agentes de IA (AI Native Companion)
Llevar la IA al núcleo del cliente Flutter para automatizar tareas repetitivas o complejas.

* **Copiloto en la Terminal:** Si un comando falla (código de retorno distinto de 0), ofrecer un botón para "Explicar error" o "Sugerir corrección" mediante IA.
* **Agentes de Autonomía VPS:** Un flujo en el que indicas en lenguaje natural qué quieres hacer (ej. *"Instala Node 20 y monta mi servidor Express en el puerto 5000"*), y el agente realiza la secuencia de comandos por SSH, adaptándose y corrigiendo errores sobre la marcha.
* **Host MCP Portátil (Model Context Protocol):**
  - KALA actúa como un servidor MCP local para IAs externas (como Claude Desktop).
  - Permite delegar tareas a la IA de tu computadora para que acceda al VPS de forma segura mediante KALA, utilizando la biometría del móvil para autorizar comandos delicados sin exponer llaves privadas.
* **Copiloto de Editor de Código:** Autocompletado de tipo "ghost text" y refactorizaciones guiadas directamente en el editor móvil.

---

## 3. Mejoras del Núcleo y Estabilidad (Core & UX)
* **Persistencia de Sesión (Foreground Service):** Evitar desconexiones de terminales activas o túneles de red cuando la aplicación se envíe al segundo plano en Android.
* **Editor Multi-pestañas:** Soportar la edición de múltiples archivos abiertos de manera simultánea en el editor de código.
* **Git Integrado:** Integración básica con comandos de control de versiones locales y remotos para mostrar visualmente el estado del repositorio.

---

## 4. Refactorización para la Escalabilidad
Para que el código fuente sea mantenible a gran escala:
* **Separación de `AppState`:** Dividir el actual monolito `AppState` (71KB) en sub-proveedores específicos:
  - `TerminalSessionProvider`
  - `FileManagerProvider`
  - `VpsMetricsProvider`
  - `CodeEditorProvider`
  - `AiAgentProvider`
* **Arquitectura de Carpetas:** Organizar el proyecto bajo una estructura más modular por capas (`core`, `providers`, `services`, `views`, `widgets`).
