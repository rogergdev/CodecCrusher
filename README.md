![CodecCrusher](https://github.com/user-attachments/assets/6defddad-17fc-448e-960f-ddea6d877046)

**CodecCrusher** es un script en Bash diseñado para automatizar la transcodificación de archivos de vídeo usando `HandBrakeCLI`, `ffmpeg`, `ffprobe` y diversas herramientas de monitoreo y notificaciones vía Telegram. Su propósito principal es comprimir y optimizar el tamaño de archivos de vídeo (especialmente si no están en formato H.265/HEVC o si su bitrate de H.264 es excesivamente alto), conservando la calidad en un nivel aceptable.

## Tabla de Contenidos

1. [Características Principales](#características-principales)  
2. [Requisitos](#requisitos)  
3. [Cómo Funciona](#cómo-funciona)  
4. [Uso](#uso)  
5. [Ejemplos de Uso y Flujos de Trabajo](#ejemplos-de-uso-y-flujos-de-trabajo)  
    - [1. Escaneo y Transcodificación](#1-escaneo-y-transcodificación)  
    - [2. Ejemplo de Notificaciones por Telegram](#2-ejemplo-de-notificaciones-por-telegram)  
    - [3. Ejemplo de Películas](#3-ejemplo-de-películas)  
6. [Ejemplos de Errores y Soluciones](#ejemplos-de-errores-y-soluciones)  
7. [Base de Datos Interna (SQLite)](#base-de-datos-interna-sqlite)  
8. [Archivos de Log y Rotación](#archivos-de-log-y-rotación)  
9. [Instrucciones de Servicio (systemd)](#instrucciones-de-servicio-systemd)  
10. [Roadmap / Próximas Mejoras](#roadmap--próximas-mejoras)

---

## Características Principales

- **Automatización completa**: El script se ejecuta en bucle, monitoriza la carga de CPU, temperatura del sistema y espacio en disco.  
- **Transcodificación inteligente**:  
  - Solo transcodifica archivos que estén en H.264 con un bitrate mayor a 2000 kbps.  
  - Los archivos en H.265/HEVC se marcan como *“completados”* sin reconversión.  
  - Otros formatos (AVI, MOV, etc.) se marcan como *“saltado_no_h264_hevc”* (por defecto) para evitar sobrecargar el sistema.  
- **Monitor de salud de discos** mediante `smartctl`, enviando alertas de estado (PASSED/FAILED).  
- **Notificaciones por Telegram** para cada etapa (inicio, final, errores, etc.).  
- **Registro en base de datos** (SQLite) de cada archivo con su tamaño original, final y porcentaje de ahorro.  
- **Rotación automática** de logs e informes diarios.

---

## Requisitos

1. **Dependencias** que deben estar instaladas:
   - `HandBrakeCLI`  
   - `ffmpeg`, `ffprobe`  
   - `sqlite3`  
   - `smartctl`  
   - `sensors` (para temperatura)  
   - `curl` (para notificaciones Telegram)  
   - `bc`, `awk`, `sed`, `grep`, `find`, `du`, `stat`, `nice`, `ionice`  

2. **Variables de entorno** para notificaciones de Telegram, en `~/.codeccrusher_env`:
   ```bash
   export BOT_TOKEN="TU_BOT_TOKEN"
   export CHAT_ID="TU_CHAT_ID"
   ```
   (con tus datos reales de Bot Token y Chat ID).

3. **Rutas y directorios** a escanear, configurados en el script (`RUTAS`, `discos`).

---

## Cómo Funciona

1. **Escanea** las rutas definidas en la variable `RUTAS`.  
2. Para cada archivo con extensión `mp4`, `mkv`, `avi` o `mov`:  
   - Verifica que no haya sido ya transcodificado (consulta `codeccrusher.db`).  
   - Chequea espacio libre en disco.  
   - Verifica el códec de vídeo y bitrate.  
3. Si cumple criterios (H.264 > 2000 kbps):  
   - **Transcodifica** a H.265/HEVC mediante `HandBrakeCLI`.  
4. **Registra** cada acción (transcodificado, ignorado, interrumpido...) en la base de datos.  
5. Envía **notificaciones** a Telegram para cada evento (inicio, fin, reintentos, errores, etc.).  
6. **Repite** el proceso en bucle, monitoreando carga de CPU, temperatura y espacio en disco.

---

## Uso

1. **Clona** o descarga este repositorio.  
2. Concede permisos de ejecución al script:
   ```bash
   chmod +x codeccrusher.sh
   ```
3. **Edita** las secciones de variables (RUTAS, parámetros de transcodificación, etc.) y tu archivo de entorno `~/.codeccrusher_env`.
4. **Ejecuta**:
   ```bash
   ./codeccrusher.sh run
   ```
5. ¡Listo! El script comenzará a procesar los archivos en las rutas indicadas, enviando notificaciones a tu bot de Telegram.

---

## Ejemplos de Uso y Flujos de Trabajo

### 1. Escaneo y Transcodificación

Supongamos que tienes una carpeta `/media/roger/Disco1/MisPeliculas` con los siguientes archivos:

```
- ElPadrino.mkv (H.264, bitrate alto)
- ForrestGump.mp4 (H.265)
- MiVideoCasero.avi (Xvid)
```

- **ElPadrino.mkv** se transcodificará a H.265, ya que es H.264 con bitrate superior a 2000 kbps.  
- **ForrestGump.mp4** se deja tal cual, está en H.265.  
- **MiVideoCasero.avi** se marca como “saltado_no_h264_hevc”.

### 2. Ejemplo de Notificaciones por Telegram

- Iniciando la transcodificación:
  ```
  🎬 Transcodificando:
  🖥️ Disco 1
  📄 ElPadrino.mkv
  ```
- Al completarse:
  ```
  ✅ Transcodificación completada:
  📄 ElPadrino.mkv
  📏 Tamaño original: 5.00 GB
  📏 Tamaño final: 2.50 GB
  📉 Ahorro: 50%
  ⏱ Tiempo transcurrido: 00:10:35
  ```
- Alertas de espacio insuficiente:
  ```
  ⚠️ Espacio insuficiente (~1GB, min: 5GB).
  ```
- Si se detecta **temperatura alta**:
  ```
  ⚠️ Temperatura alta (87°C). Pausando 1 min.
  ```

### 3. Ejemplo de Películas

- **Titanic.mkv**  
  - Códec detectado: `h264`  
  - Bitrate: 4500 kbps  
  - Resultado: se transcodifica a H.265, reduciendo de ~8 GB a ~4 GB  
- **ElSeñorDeLosAnillos.mkv**  
  - Códec: `hevc`  
  - Bitrate: 1800 kbps  
  - Resultado: *completado*, sin transcodificar  
- **KillBill.avi**  
  - Códec: `xvid`  
  - Resultado: marcado como “saltado_no_h264_hevc”

---

## Base de Datos Interna (SQLite)

El script crea un archivo `codeccrusher.db` en tu `$HOME`. La tabla `transcodificados` registra información de cada archivo:
- `archivo`  
- `fecha_transcodificacion`  
- `estado`  
- `size_original`, `size_final`  
- ... entre otros campos

Puedes consultar manualmente con:
```sql
sqlite3 ~/codeccrusher.db "SELECT * FROM transcodificados LIMIT 10;"
```

---

## Archivos de Log y Rotación

- **Logs**: se almacenan en `~/codeccrusher_logs/transcode.log`.  
- **Rotación**: cuando supera ~10 MB, el log se mueve a `~/codeccrusher_backup/transcode_YYYYmmdd_HHMMSS.log`.  
- **Limpieza**: se eliminan logs con más de 30 días para evitar acumulaciones excesivas.

---

## Instrucciones de Servicio (systemd)

Puedes crear un servicio en `/etc/systemd/system/codeccrusher.service`:
```ini
[Unit]
Description=CodecCrusher Service
After=network.target

[Service]
User=TU_USUARIO
WorkingDirectory=/ruta/al/script
ExecStart=/ruta/al/script/codeccrusher.sh run
Restart=always
Type=simple

[Install]
WantedBy=multi-user.target
```

Luego:
```bash
sudo systemctl daemon-reload
sudo systemctl enable codeccrusher.service
sudo systemctl start codeccrusher.service
```
- **Ver progreso**:
  ```bash
  tail -f /home/tranquilamami/codeccrusher_logs/transcode.log
  ```
- **Parar** el servicio:
  ```bash
  sudo systemctl stop codeccrusher.service
  ```

---
---

## 📜 **Licencia**
Este proyecto está licenciado bajo la Licencia MIT. Consulta el archivo [LICENSE](LICENSE) para más detalles.

---

**</> con ❤️ por Roger.**
