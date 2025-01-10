#!/usr/bin/env bash

##############################################################################
# Ver el progreso:
#   tail -f /home/roger/codeccrusher_logs/transcode.log
#
# Parar el servicio:
#   sudo systemctl stop codeccrusher.service
##############################################################################

# Cargar variables de entorno para Telegram (seguridad)
source "$HOME/.codeccrusher_env"

terminando=0  # Variable global para controlar la terminación

##############################################################################
# AJUSTES DE RUTAS Y PARÁMETROS
##############################################################################
# Directorios a escanear
RUTAS=(
    "/media/roger/Disco1"
    "/media/roger/Disco3"
    "/media/roger/Disco4"
    "/mnt/D10TB"
)

# Mapeo de las rutas a los discos
declare -A discos
discos=(
    ["/media/roger/Disco1"]="Disco 1"
    ["/media/roger/Disco3"]="Disco 3"
    ["/media/roger/Disco4"]="Disco 4"
    ["/mnt/D10TB"]="D10TB"
)

EXTENSIONES=("mp4" "mkv" "avi" "mov")

##############################################################################
# CONFIGURACIÓN DE HANDBRAKE (Flatpak) y PARÁMETROS X265
##############################################################################
# Usa la versión 1.9.0 de HandBrake instalada vía Flatpak con la ID: fr.handbrake.HandBrakeCLI
FLATPAK_HANDBRAKE="flatpak run fr.handbrake.HandBrakeCLI"

# Parámetros base de HandBrake (no confundir con x265-preset):
PRESET="Fast 1080p30"

# Valor CRF (RF): a menor valor, mejor calidad pero mayor tamaño
RF=21

##############################################################################
# ⚖️ RESUMEN RÁPIDO SOBRE LOS PRESETS DE x265:
# - medium: ✅ Más rápido, pero genera archivos un poco más grandes.
# - slow: 🚀 Más lento, pero ofrece mejor compresión (archivos más pequeños).
#
# 🔧 RECOMENDACIÓN PERSONAL:
# Mantener el preset en "slow" para maximizar el ahorro de espacio en disco,
# sin comprometer la calidad visual. Cambiar a "medium" solo si la velocidad
# de codificación es una prioridad.
#
# x265 preset => "slow" da mejor compresión (menos tamaño) que "medium"
##############################################################################
SPEED="medium"

DEFAULT_SAMPLE_RATE=48000
DEFAULT_CHANNELS=2
DEFAULT_BITRATE=192000

MIN_FREE_GB=5
TEMPERATURA_UMBRAL=85
MAX_BITRATE_H264=2000

DB_FILE="$HOME/codeccrusher.db"

LOG_DIR="$HOME/codeccrusher_logs"
BACKUP_DIR="$HOME/codeccrusher_backup"
LOG_FILE="$LOG_DIR/transcode.log"
LOCKFILE="$LOG_DIR/codeccrusher.lock"

##############################################################################
# FUNCIONES
##############################################################################

#--------------------- FUNCIÓN: verificar_dependencias -------------------------
verificar_dependencias() {
    local dependencias=("flatpak" "ffmpeg" "ffprobe" "sqlite3" "smartctl" "sensors" "curl" "bc" "awk" "sed" "grep" "find" "du" "stat" "nice" "ionice")
    local faltantes=()

    for cmd in "${dependencias[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            faltantes+=("$cmd")
        fi
    done

    if [ ${#faltantes[@]} -ne 0 ]; then
        echo "⚠️ Las siguientes dependencias faltan: ${faltantes[*]}" | tee -a "$LOG_FILE"
        enviar_telegram "⚠️ *Dependencias faltantes:* ${faltantes[*]}"
        exit 1
    fi
}

#--------------------- FUNCIÓN: enviar_telegram ------------------------------
enviar_telegram() {
    local mensaje="$1"
    mensaje=$(echo -e "$mensaje" | sed ':a;N;$!ba;s/\n/%0A/g')
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
         -d chat_id="${CHAT_ID}" \
         -d parse_mode="Markdown" \
         -d text="${mensaje}" >/dev/null 2>&1
}

#--------------------- FUNCIÓN: obtener_codec_video ---------------------------
obtener_codec_video() {
    local archivo="$1"
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$archivo" 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

#--------------------- FUNCIÓN: obtener_temperatura ---------------------------
obtener_temperatura() {
    local temp_c
    temp_c=$(sensors 2>/dev/null | awk '
        /Core 0:/ {
            for(i=1;i<=NF;i++) {
                if ($i ~ /\+?[0-9]+\.[0-9]+°C/) {
                    gsub(/\+|°C/,"",$i);
                    print int($i);
                    exit;
                }
            }
        }
    ')

    if [[ -z "$temp_c" || ! "$temp_c" =~ ^[0-9]+$ ]]; then
        temp_c=$(sensors 2>/dev/null | awk '
            /Package id 0:/ {
                for(i=1;i<=NF;i++) {
                    if ($i ~ /\+?[0-9]+\.[0-9]+°C/) {
                        gsub(/\+|°C/,"",$i);
                        print int($i);
                        exit;
                    }
                }
            }
        ')
    fi

    [[ -z "$temp_c" || ! "$temp_c" =~ ^[0-9]+$ ]] && temp_c="N/A"
    echo "$temp_c"
}

#--------------------- FUNCIÓN: registrar_transcodificado ---------------------
registrar_transcodificado() {
    local archivo_original="$1"
    local estado="$2"
    local fecha
    fecha=$(date '+%Y-%m-%d %H:%M:%S')

    local size_original=0
    [[ -f "$archivo_original" ]] && size_original=$(stat -c%s "$archivo_original" 2>/dev/null)

    local archivo_transcodificado="${archivo_original%.*}.mkv"
    local size_final=0
    [[ -f "$archivo_transcodificado" ]] && size_final=$(stat -c%s "$archivo_transcodificado" 2>/dev/null)

    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS transcodificados (
    archivo TEXT PRIMARY KEY,
    original_archivo TEXT,
    archivo_transcodificado TEXT,
    fecha_transcodificacion TEXT,
    estado TEXT,
    size_original INTEGER DEFAULT 0,
    size_final INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_original_archivo ON transcodificados (original_archivo);
EOF

    sqlite3 "$DB_FILE" <<EOF
INSERT INTO transcodificados (
    archivo,
    original_archivo,
    archivo_transcodificado,
    fecha_transcodificacion,
    estado,
    size_original,
    size_final
)
VALUES (
    '$archivo_original',
    '$archivo_original',
    '$archivo_transcodificado',
    '$fecha',
    '$estado',
    $size_original,
    $size_final
)
ON CONFLICT(archivo) DO UPDATE SET
    original_archivo='$archivo_original',
    archivo_transcodificado='$archivo_transcodificado',
    fecha_transcodificacion='$fecha',
    estado='$estado',
    size_original=$size_original,
    size_final=$size_final;
EOF
}

#--------------------- FUNCIÓN: obtener_bitrate_video -------------------------
obtener_bitrate_video() {
    local archivo="$1"
    local bitrate
    bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 "$archivo" 2>/dev/null)

    if [[ -z "$bitrate" || "$bitrate" == "N/A" ]]; then
        local size_bytes duration_sec
        size_bytes=$(stat -c%s "$archivo")
        duration_sec=$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$archivo" 2>/dev/null)
        if [[ -n "$duration_sec" && "$duration_sec" =~ ^[0-9.]+$ ]]; then
            bitrate=$(echo "scale=0; ($size_bytes * 8) / ($duration_sec * 1000)" | bc -l)
        else
            bitrate=0
        fi
    else
        bitrate=$(echo "scale=0; $bitrate / 1000" | bc)
    fi

    echo "$bitrate"
}

#--------------------- FUNCIÓN: obtener_idiomas_y_subtitulos -----------------
obtener_idiomas_y_subtitulos() {
    local archivo="$1"
    local idiomas=""
    local subtitulos=""

    while IFS= read -r linea; do
        local lang=$(echo "$linea" | grep -oP 'language=\K\w+')
        local title=$(echo "$linea" | grep -oP 'title=\K[^,]*')
        [[ -n "$title" ]] && idiomas+="$title ($lang), " || idiomas+="$lang, "
    done < <(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language,title \
             -of default=noprint_wrappers=1:nokey=1 "$archivo" 2>/dev/null)

    while IFS= read -r linea; do
        local lang=$(echo "$linea" | grep -oP 'language=\K\w+')
        local title=$(echo "$linea" | grep -oP 'title=\K[^,]*')
        [[ -n "$title" ]] && subtitulos+="$title ($lang), " || subtitulos+="$lang, "
    done < <(ffprobe -v error -select_streams s -show_entries stream=index:stream_tags=language,title \
             -of default=noprint_wrappers=1:nokey=1 "$archivo" 2>/dev/null)

    idiomas=${idiomas%, }
    subtitulos=${subtitulos%, }
    [[ -z "$idiomas" ]] && idiomas="Desconocido"
    [[ -z "$subtitulos" ]] && subtitulos="Desconocido"

    echo "$idiomas|$subtitulos"
}

#--------------------- FUNCIÓN: cargar_transcodificados -----------------------
cargar_transcodificados() {
    declare -A transcodificados_map
    while IFS= read -r archivo_original; do
        [[ -n "$archivo_original" ]] && transcodificados_map["$archivo_original"]=1
    done < <(sqlite3 "$DB_FILE" "SELECT original_archivo FROM transcodificados WHERE estado='completado';")
    echo "${!transcodificados_map[@]}"
}

#--------------------- FUNCIÓN: limpiar_temporal -----------------------------
limpiar_temporal() {
    local archivo_temporal="$1"
    if [[ -f "$archivo_temporal" && "$archivo_temporal" == *"_temp.mkv" ]]; then
        rm -f "$archivo_temporal"
        enviar_telegram "🧹 *Archivo temporal eliminado:*\n📄 $(basename "$archivo_temporal")"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Eliminado temporal: $archivo_temporal" >> "$LOG_FILE"
    fi
}

#--------------------- FUNCIÓN: limpiar_logs_antiguos -------------------------
limpiar_logs_antiguos() {
    local dias_retenidos=30
    find "$BACKUP_DIR" -type f -name "transcode_*.log" -mtime +$dias_retenidos -exec rm -f {} \;
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Limpieza de logs antiguos completada (retenidos $dias_retenidos días)" >> "$LOG_FILE"
}

#--------------------- FUNCIÓN: monitorear_carga -----------------------------
monitorear_carga() {
    local carga nucleos
    carga=$(awk '{print $1}' /proc/loadavg)
    nucleos=$(nproc)
    if echo "$carga > $nucleos" | bc -l | grep -q 1; then
        local pause_time=$((nucleos * 2))
        [ $pause_time -lt 60 ] && pause_time=60
        enviar_telegram "⏸️ *Pausando*: carga alta (${carga}). Reanudación en ${pause_time}s."
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Carga alta (${carga}), pausando ${pause_time}s" >> "$LOG_FILE"
        sleep $pause_time
        return 1
    fi
    return 0
}

#--------------------- FUNCIÓN: monitorear_temperatura -----------------------
monitorear_temperatura() {
    local temp_c
    temp_c=$(obtener_temperatura)

    if [[ "$temp_c" == "N/A" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] No se pudo obtener la temperatura." >> "$LOG_FILE"
        return 0
    fi

    if [ "$temp_c" -gt "$TEMPERATURA_UMBRAL" ]; then
        enviar_telegram "⚠️ *Temperatura alta (${temp_c}°C).* Pausando 1 min."
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Temperatura alta: ${temp_c}°C" >> "$LOG_FILE"
        sleep 60
        return 1
    fi
    return 0
}

#--------------------- FUNCIÓN: verificar_espacio ----------------------------
verificar_espacio() {
    local archivo="$1"
    local partition free_gb
    partition=$(df -P "$archivo" | tail -1 | awk '{print $1}')
    free_gb=$(df -BG "$archivo" | tail -1 | awk '{print $4}' | sed 's/G//')

    if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
        enviar_telegram "⚠️ *Espacio insuficiente* (~${free_gb}GB, min: ${MIN_FREE_GB}GB)."
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Espacio insuficiente en $partition => $free_gb GB" >> "$LOG_FILE"
        return 1
    fi
    return 0
}

#--------------------- FUNCIÓN: smartctl_check -------------------------------
smartctl_check() {
    for disk in /dev/sd?; do
        local output
        output=$(sudo smartctl -H "$disk" 2>/dev/null)
        if echo "$output" | grep -q "PASSED"; then
            enviar_telegram "✅ *SMART Check PASSED* para $disk."
        else
            enviar_telegram "⚠️ *SMART Check FAILED* para $disk. Revisa los discos."
        fi
    done

    local temp_c
    temp_c=$(obtener_temperatura)
    if [[ "$temp_c" != "N/A" ]]; then
        enviar_telegram "🌡️ *Temperatura actual:* ${temp_c}°C"
    else
        enviar_telegram "🌡️ No se pudo obtener la temperatura actual."
    fi
}

#--------------------- FUNCIÓN: rotar_log --------------------------------------
rotar_log() {
    local max_log_size=10485760
    local log_backup_dir="$BACKUP_DIR"
    [ ! -d "$log_backup_dir" ] && mkdir -p "$log_backup_dir"

    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt $max_log_size ]; then
        local timestamp backup_file
        timestamp=$(date '+%Y%m%d_%H%M%S')
        backup_file="${log_backup_dir}/transcode_${timestamp}.log"
        mv "$LOG_FILE" "$backup_file"
        enviar_telegram "📦 *Log rotado:* $backup_file"
        touch "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Log rotado a $backup_file" >> "$LOG_FILE"
    fi

    find "$log_backup_dir" -type f -name "transcode_*.log" -mtime +30 -exec rm -f {} \;
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Limpieza de logs completada" >> "$LOG_FILE"
}

#--------------------- FUNCIÓN: transcodificar -------------------------------
transcodificar() {
    local archivo_original="$1"
    local tmp="${archivo_original%.*}_temp.mkv"

    trap "interrumpir_transcodificacion '$archivo_original' '$tmp'" SIGINT SIGTERM

    local codec bitrate
    codec=$(obtener_codec_video "$archivo_original")

    # Si es HEVC, lo consideramos ya óptimo
    if [[ "$codec" == "hevc" ]]; then
        registrar_transcodificado "$archivo_original" "completado"
        return
    elif [[ "$codec" != "h264" ]]; then
        # Comentado para evitar spam
        # enviar_telegram "ℹ️ No H.264/H.265: $(basename "$archivo_original")"
        registrar_transcodificado "$archivo_original" "saltado_no_h264_hevc"
        return
    fi

    bitrate=$(obtener_bitrate_video "$archivo_original")
    if [ "$bitrate" -le "$MAX_BITRATE_H264" ]; then
        # Comentado para evitar spam de "Optimizado"
        # enviar_telegram "ℹ️ Optimizado: $(basename "$archivo_original") - ${bitrate} kbps"
        registrar_transcodificado "$archivo_original" "completado"
        return
    fi

    local size_bytes size_gb
    size_bytes=$(stat -c%s "$archivo_original")
    size_gb=$(awk "BEGIN {printf \"%.2f\", $size_bytes/1073741824}")

    local disco=""
    for ruta in "${RUTAS[@]}"; do
        if [[ "$archivo_original" == $ruta/* ]]; then
            disco="${discos[$ruta]}"
            break
        fi
    done

    local start_time
    start_time=$(date +%s)
    enviar_telegram "🎬 Transcodificando:\n🖥️ $disco\n📄 $(basename "$archivo_original")"

    verificar_espacio "$archivo_original" || return

    local idiomas_subs idiomas subtitulos
    idiomas_subs=$(obtener_idiomas_y_subtitulos "$archivo_original")
    idiomas=$(echo "$idiomas_subs" | cut -d '|' -f1)
    subtitulos=$(echo "$idiomas_subs" | cut -d '|' -f2)

    registrar_transcodificado "$archivo_original" "en proceso"

    local intentos=0
    local max_intentos=3

    # Sin tune=animation ni advanced flags, para total compatibilidad.
    local X265_OPTS=""
    local TWO_PASS_OPTS=""

    while [ $intentos -lt $max_intentos ]; do
        nice -n 19 ionice -c3 \
        $FLATPAK_HANDBRAKE \
            --input "$archivo_original" \
            --output "$tmp" \
            --encoder x265 \
            --quality "$RF" \
            --preset="$PRESET" \
            --x265-preset="$SPEED" \
            --optimize \
            $X265_OPTS \
            $TWO_PASS_OPTS \
            --all-audio \
            --aencoder "copy" \
            --audio-copy-mask "aac,ac3,dts,eac3,truehd" \
            --audio-fallback "av_aac" \
            --all-subtitles \
            < /dev/null >> "$LOG_FILE" 2>&1

        if [ $? -eq 0 ] && [ -f "$tmp" ]; then
            mv "$tmp" "${archivo_original%.*}.mkv"
            local final_bytes final_gb ahorro
            final_bytes=$(stat -c%s "${archivo_original%.*}.mkv")
            final_gb=$(awk "BEGIN {printf \"%.2f\", $final_bytes/1073741824}")
            ahorro=$(( (size_gb - final_gb) * 100 / size_gb ))

            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            local hours=$((duration / 3600))
            local minutes=$(( (duration % 3600) / 60 ))
            local seconds=$((duration % 60))
            local tiempo_transcurrido
            tiempo_transcurrido=$(printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds")

            enviar_telegram "✅ Transcodificación completada:\n📄 $(basename "${archivo_original%.*}.mkv")\n📏 Tamaño original: ${size_gb} GB\n📏 Tamaño final: ${final_gb} GB\n📉 Ahorro: ${ahorro}%\n⏱ Tiempo transcurrido: ${tiempo_transcurrido}"
            registrar_transcodificado "$archivo_original" "completado"
            limpiar_temporal "$tmp"
            
            local temp_c
            temp_c=$(obtener_temperatura)
            if [[ "$temp_c" != "N/A" ]]; then
                enviar_telegram "🌡️ *Temperatura tras transcodificación:* ${temp_c}°C"
            else
                enviar_telegram "🌡️ No se pudo obtener la temperatura tras transcodificación."
            fi

            return
        fi

        intentos=$((intentos + 1))
        enviar_telegram "🔄 Reintento $intentos de $max_intentos: $(basename "$archivo_original")"
        sleep $((intentos * 10))
    done

    enviar_telegram "❌ Fallo crítico en: $(basename "$archivo_original") tras $max_intentos intentos."
    registrar_transcodificado "$archivo_original" "fallido_permanente"
    limpiar_temporal "$tmp"
}

#--------------------- FUNCIÓN: interrumpir_transcodificacion ----------------------------
interrumpir_transcodificacion() {
    local archivo="$1"
    local archivo_temporal="$2"

    enviar_telegram "❗ Transcodificación interrumpida:\n📄 $(basename "$archivo")"
    registrar_transcodificado "$archivo" "interrumpido"

    if [ -f "$archivo_temporal" ]; then
        rm -f "$archivo_temporal"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Archivo temporal eliminado: $archivo_temporal" >> "$LOG_FILE"
    fi

    exit 1
}

#--------------------- FUNCIÓN: procesar_archivos ----------------------------
procesar_archivos() {
    local archivos_pendientes=0
    declare -A transcodificados_map
    while IFS= read -r archivo_original; do
        [[ -n "$archivo_original" ]] && transcodificados_map["$archivo_original"]=1
    done < <(cargar_transcodificados)

    for ruta in "${RUTAS[@]}"; do
        find "$ruta" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" \) \
             ! -iname "*_temp.*" -print0 | while IFS= read -r -d '' archivo_original; do
            if [[ ${transcodificados_map["$archivo_original"]+exists} ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Archivo ya transcodificado: $archivo_original" >> "$LOG_FILE"
                continue
            fi
            if ! verificar_espacio "$archivo_original"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Espacio insuficiente para: $archivo_original" >> "$LOG_FILE"
                continue
            fi
            archivos_pendientes=$((archivos_pendientes + 1))
            transcodificar "$archivo_original"
        done
    done

    if [ $archivos_pendientes -eq 0 ]; then
        enviar_telegram "🎉 *Transcodificación finalizada.* No quedan archivos pendientes."
    fi
}

#--------------------- FUNCIÓN: limpiar_archivos_temporales -------------------
limpiar_archivos_temporales() {
    local dias_retencion=1
    find "${RUTAS[@]}" -type f -name "*_temp.mkv" -mtime +$dias_retencion -exec rm -f {} \;
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Archivos temporales eliminados" >> "$LOG_FILE"
    enviar_telegram "🧹 Limpieza de archivos temporales completada."
}

#--------------------- FUNCIÓN: manejador_senal -------------------------------
manejador_senal() {
    if [ "$terminando" == "1" ]; then
        exit 0
    fi
    terminando=1

    # Notificación de detención a Telegram
    enviar_telegram "🔴 *CodecCrusher detenido.*"

    # Terminar HandBrakeCLI ejecutado con Flatpak
    flatpak kill fr.handbrake.HandBrakeCLI

    # Matar todos los procesos hijos
    pkill -P $$

    # Eliminar el archivo LOCKFILE
    rm -f "$LOCKFILE"

    exit 0
}

#--------------------- FUNCIÓN: generar_informe_diario -------------------------
generar_informe_diario() {
    local informe
    informe=$(sqlite3 "$DB_FILE" <<EOF
.headers on
.mode column
SELECT archivo, fecha_transcodificacion, estado
FROM transcodificados
WHERE DATE(fecha_transcodificacion) = DATE('now', 'localtime');
EOF
)
    echo "$informe"
}

#--------------------- FUNCIÓN: enviar_informe_diario -------------------------
enviar_informe_diario() {
    local archivos_transcodificados
    archivos_transcodificados=$(sqlite3 "$DB_FILE" "
        SELECT COUNT(*) FROM transcodificados
        WHERE estado='completado'
          AND DATE(fecha_transcodificacion) = DATE('now', 'localtime');
    ")

    local sum_sizes_query="
        SELECT
            IFNULL(SUM(size_original), 0),
            IFNULL(SUM(size_final), 0)
        FROM transcodificados
        WHERE estado='completado'
          AND DATE(fecha_transcodificacion) = DATE('now', 'localtime');
    "

    IFS='|' read -r espacio_original espacio_final <<< "$(sqlite3 "$DB_FILE" "$sum_sizes_query")"

    # Si no hubo transcodificaciones (espacio_original = 0), avisamos y salimos
    if (( espacio_original == 0 )); then
        enviar_telegram "📊 *Informe diario*\n🗓️ Fecha: $(date '+%d/%m/%Y %H:%M:%S')\n✅ No se encontraron transcodificaciones completadas hoy."
        return
    fi

    # Conversión de bytes a GB
    local orig_gb
    orig_gb=$(awk "BEGIN { printf \"%.2f\", $espacio_original / 1073741824 }")

    local final_gb
    final_gb=$(awk "BEGIN { printf \"%.2f\", $espacio_final / 1073741824 }")

    local ahorrado_gb
    ahorrado_gb=$(awk "BEGIN { printf \"%.2f\", ($espacio_original - $espacio_final) / 1073741824 }")

    # Cálculo de porcentaje de ahorro
    local ahorro_total
    ahorro_total=$(awk "BEGIN {
        if ($espacio_original > 0) {
            printf \"%.2f\", (($espacio_original - $espacio_final) / $espacio_original) * 100
        } else {
            print \"0.00\"
        }
    }")

    local ahora
    ahora=$(date '+%d/%m/%Y %H:%M:%S')

    # Construimos el mensaje
    local informe="📊 *Informe diario*\n"
    informe+="🗓️ *Fecha:* $ahora\n"
    informe+="✅ *Archivos transcodificados hoy:* ${archivos_transcodificados}\n"
    informe+="📏 *Tamaño original total:* ${orig_gb} GB\n"
    informe+="📏 *Tamaño final total:* ${final_gb} GB\n"
    informe+="💾 *Espacio ahorrado:* ${ahorrado_gb} GB\n"
    informe+="🔻 *Ahorro total:* ${ahorro_total}%\n"

    # Envío del informe
    enviar_telegram "$informe"
}

#--------------------- FUNCIÓN: programar_informe_diario ----------------------
programar_informe_diario() {
    while true; do
        if [[ "$(date +'%H:%M')" == "00:00" ]]; then
            enviar_informe_diario
            sleep 60
        fi
        sleep 30
    done
}

#--------------------- MAIN LOOP -------------------------------
main() {
    enviar_telegram "🟢 *CodecCrusher iniciado.*"
    rotar_log
    limpiar_logs_antiguos
    limpiar_archivos_temporales

    programar_informe_diario &

    while true; do
        monitorear_temperatura
        monitorear_carga
        smartctl_check
        procesar_archivos
        sleep 60
    done
}

#--------------------- INICIALIZACIÓN Y EJECUCIÓN -------------------------------
verificar_dependencias

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

touch "$LOCKFILE"
chmod 600 "$LOCKFILE"

if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" &>/dev/null; then
    enviar_telegram "⚠️ *CodecCrusher* ya está en ejecución."
    exit 1
fi

echo $$ > "$LOCKFILE"
trap manejador_senal SIGINT SIGTERM

case "$1" in
    run)
        main
        ;;
    *)
        echo "Uso: $0 run"
        exit 2
        ;;
esac
