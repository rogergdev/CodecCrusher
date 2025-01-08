![CodecCrusher](https://github.com/user-attachments/assets/6defddad-17fc-448e-960f-ddea6d877046)

# 🎥 CodecCrusher - Transcodificación Automática con HandBrakeCLI y Notificaciones en Telegram

*¡Automatiza tu biblioteca multimedia como un profesional!*

---

## 📖 Tabla de Contenidos
- [Introducción](#-introducción)
- [Características](#-características)
- [Requisitos](#-requisitos)
- [Escaneo de Directorios](#-escaneo-de-directorios)
- [Extensiones de Archivos Soportadas](#-extensiones-de-archivos-soportadas)
- [Configuración de HandBrakeCLI](#-configuración-de-handbrakecli)
- [Gestión de la Base de Datos](#-gestión-de-la-base-de-datos)
- [Notificaciones en Telegram](#-notificaciones-en-telegram)
- [Funciones Principales](#-funciones-principales)
- [Comandos](#-comandos)
- [Logs y Archivos Temporales](#-logs-y-archivos-temporales)
- [Beneficios](#-beneficios)
- [Ejemplos Prácticos](#-ejemplos-prácticos)
- [Licencia](#-licencia)

---

## 📌 **Introducción**
CodecCrusher es un potente script Bash que automatiza la transcodificación de archivos de video utilizando HandBrakeCLI. Con características avanzadas como notificaciones en tiempo real a través de Telegram, monitoreo del sistema y gestión de base de datos SQLite, CodecCrusher garantiza la optimización de tu biblioteca multimedia de manera eficiente y sin complicaciones.

---

## ✨ **Características**
✅ Transcodificación automática a H.265 utilizando HandBrakeCLI  
✅ Notificaciones en tiempo real a Telegram para actualizaciones de estado y errores  
✅ Base de datos SQLite para registrar el progreso de la transcodificación  
✅ Monitorización de carga del sistema y temperatura para evitar sobrecalentamientos  
✅ Rotación de logs y limpieza automática de archivos temporales  
✅ Informes diarios que resumen los resultados de la transcodificación y el espacio ahorrado  

---

## 📚 **Ejemplos Prácticos**
### 🎬 Ejemplo 1: Transcodificación de una película con múltiples idiomas
**Archivo original:** `Gladiator.2000.BluRay.mkv` (10 GB, H.264, Inglés, Español, Francés)  
**Archivo transcodificado:** `Gladiator.2000.BluRay.mkv` (5.2 GB, H.265, mantiene los idiomas originales)

**Mensaje en Telegram:**
```
🎬 Transcodificación completada:
📄 Gladiator.2000.BluRay.mkv
📏 Tamaño original: 10 GB
📏 Tamaño final: 5.2 GB
📉 Ahorro: 48%
⏱ Tiempo transcurrido: 01:45:10
```

### 🚩 Ejemplo 2: Archivo no válido o corrupto
**Archivo:** `The.Matrix.1999.BluRay.mkv`

**Mensaje en Telegram:**
```
❌ Error crítico: Archivo corrupto o no válido.
📄 The.Matrix.1999.BluRay.mkv
```
**Solución:** Revisa la integridad del archivo antes de intentar transcodificarlo de nuevo.

### 🎥 Ejemplo 3: Archivo ya está en H.265
**Archivo:** `Inception.2010.BluRay.mkv` (5.3 GB, H.265)

**Mensaje en Telegram:**
```
ℹ️ Archivo ya optimizado:
📄 Inception.2010.BluRay.mkv
🎥 Codec: H.265
✅ No se requiere transcodificación.
```

### 🌡️ Ejemplo 4: Pausa por temperatura alta
**Mensaje en Telegram:**
```
⚠️ Temperatura alta (87°C). Pausando transcodificación por 1 minuto.
```
**Solución:** Asegúrate de que el sistema esté bien ventilado y libre de obstrucciones.

### 📋 Ejemplo 5: Informe diario
**Mensaje en Telegram:**
```
📊 Informe diario de CodecCrusher
📅 Fecha: 08/01/2025
✅ Archivos transcodificados: 12
💾 Espacio total ahorrado: 45 GB
📏 Tamaño original: 95 GB
📉 Tamaño final: 50 GB
🔻 Ahorro total: 47%
```

### 🧹 Ejemplo 6: Limpieza de archivos temporales
**Mensaje en Telegram:**
```
🧹 Limpieza de archivos temporales completada.
📄 3 archivos eliminados.
```

---

## 📜 **Licencia**
Este proyecto está licenciado bajo la Licencia MIT. Consulta el archivo [LICENSE](LICENSE) para más detalles.

---

**</> con ❤️ por Roger.**
