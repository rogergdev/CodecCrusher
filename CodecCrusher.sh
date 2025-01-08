#!/usr/bin/env bash

##############################################################################
# Ver el progreso:
#   tail -f /home/roger/codeccrusher_logs/transcode.log
##############################################################################

# Cargar variables de entorno para Telegram (seguridad)
source "$HOME/.codeccrusher_env"

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

# Configuración de HandBrakeCLI y parámetros
PRESET="Fast 1080p30"
RF=21
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

#--------------------- FUNCIÓN: verificar_dependencias -------------------------
verificar_dependencias() {
    local dependencias=("HandBrakeCLI" "ffmpeg" "ffprobe" "sqlite3" "smartctl" "sensors" "curl" "bc" "awk" "sed" "grep" "find" "du" "stat" "nice" "ionice")
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

#--------------------- FUNCIÓN: obtener_temperatura ---------------------------
obtener_temperatura() {
    local temp_c

    # Intentar obtener la temperatura usando diferentes patrones
    temp_c=$(sensors | awk '
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
        temp_c=$(sensors | awk '
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

    if [[ -z "$temp_c" || ! "$temp_c" =~ ^[0-9]+$ ]]; then
        echo "N/A"
    else
        echo "$temp_c"
    fi
}

#--------------------- FUNCIÓN: registrar_transcodificado ---------------------
registrar_transcodificado() {
    local archivo="$1"
    local estado="$2"
    local fecha
    fecha=$(date '+%Y-%m-%d %H:%M:%S')

    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS transcodificados (
    archivo TEXT PRIMARY KEY,
    fecha_transcodificacion TEXT,
    estado TEXT
);
CREATE INDEX IF NOT EXISTS idx_archivo ON transcodificados (archivo);
EOF

    sqlite3 "$DB_FILE" <<EOF
INSERT INTO transcodificados (archivo, fecha_transcodificacion, estado)
VALUES ('$archivo', '$fecha', '$estado')
ON CONFLICT(archivo) DO UPDATE SET fecha_transcodificacion='$fecha', estado='$estado';
EOF
}

#--------------------- FUNCIÓN: obtener_codec_video --------------------------
obtener_codec_video() {
    local archivo="$1"
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$archivo" | tr '[:upper:]' '[:lower:]'
}

#--------------------- FUNCIÓN: obtener_bitrate_video -------------------------
obtener_bitrate_video() {
    local archivo="$1"
    local bitrate
    bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 "$archivo")
    if [[ -z "$bitrate" || "$bitrate" == "N/A" ]]; then
        local size_bytes duration_sec
        size_bytes=$(stat -c%s "$archivo")
        duration_sec=$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$archivo")
        bitrate=$(echo "scale=0; ($size_bytes * 8) / ($duration_sec * 1000)" | bc -l)
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

    # Obtener pistas de audio
    while IFS= read -r linea; do
        local lang=$(echo "$linea" | grep -oP 'language=\K\w+')
        local title=$(echo "$linea" | grep -oP 'title=\K[^,]*')

        if [[ -n "$title" ]]; then
            idiomas+="$title ($lang), "
        else
            idiomas+="$lang, "
        fi
    done < <(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language,title -of default=noprint_wrappers=1:nokey=1 "$archivo")

    # Obtener pistas de subtítulos
    while IFS= read -r linea; do
        local lang=$(echo "$linea" | grep -oP 'language=\K\w+')
        local title=$(echo "$linea" | grep -oP 'title=\K[^,]*')

        if [[ -n "$title" ]]; then
            subtitulos+="$title ($lang), "
        else
            subtitulos+="$lang, "
        fi
    done < <(ffprobe -v error -select_streams s -show_entries stream=index:stream_tags=language,title -of default=noprint_wrappers=1:nokey=1 "$archivo")

    # Limpiar las comas finales
    idiomas=${idiomas%, }
    subtitulos=${subtitulos%, }

    # Valores por defecto si no hay pistas detectadas
    [ -z "$idiomas" ] && idiomas="Desconocido"
    [ -z "$subtitulos" ] && subtitulos="Desconocido"

    echo "$idiomas|$subtitulos"
}

#--------------------- FUNCIÓN: cargar_transcodificados -----------------------
cargar_transcodificados() {
    declare -A transcodificados_map
    while IFS= read -r archivo; do
        transcodificados_map["$archivo"]=1
    done < <(sqlite3 "$DB_FILE" "SELECT archivo FROM transcodificados WHERE estado='completado';")
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
    local archivo="$1" partition free_gb
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

    # Enviar temperatura después del SMART Check
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
    local archivo="$1"
    local tmp="${archivo%.*}_temp.mkv"

    # Capturar el PID del proceso actual para manejo de señales
    trap "interrumpir_transcodificacion '$archivo' '$tmp'" SIGINT SIGTERM

    local codec bitrate
    codec=$(obtener_codec_video "$archivo")
    if [[ "$codec" == "hevc" ]]; then
        registrar_transcodificado "$archivo" "completado"
        return
    elif [[ "$codec" != "h264" ]]; then
        enviar_telegram "ℹ️ No H.264/H.265: $(basename "$archivo")"
        registrar_transcodificado "$archivo" "saltado_no_h264_hevc"
        return
    fi

    bitrate=$(obtener_bitrate_video "$archivo")
    if [ "$bitrate" -le "$MAX_BITRATE_H264" ]; then
        enviar_telegram "ℹ️ Optimizado: $(basename "$archivo") - ${bitrate} kbps"
        registrar_transcodificado "$archivo" "completado"
        return
    fi

    local size_bytes size_gb est_size_gb
    size_bytes=$(stat -c%s "$archivo")
    size_gb=$(awk "BEGIN {printf \"%.2f\", $size_bytes/1073741824}")

    # Cálculo del tamaño estimado (bitrate objetivo de 2200 kbps)
    # local duration
    # duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$archivo")
    # est_size_gb=$(awk "BEGIN {printf \"%.2f\", ($duration * 2200 * 1000) / 8 / 1073741824}")

    # Obtener el nombre del disco basado en la ruta del archivo
    for ruta in "${RUTAS[@]}"; do
        if [[ "$archivo" == $ruta/* ]]; then
            disco="${discos[$ruta]}"
            break
        fi
    done


    # Tiempo de inicio
    local start_time=$(date +%s)

    enviar_telegram "🎬 Transcodificando:\n🖥️ $disco\n📄 $(basename "$archivo")"
    #\n📏Tamaño estimado: ${est_size_gb} GB"

    verificar_espacio "$archivo" || return

    local idiomas_subs idiomas subtitulos
    idiomas_subs=$(obtener_idiomas_y_subtitulos "$archivo")
    idiomas=$(echo "$idiomas_subs" | cut -d '|' -f1)
    subtitulos=$(echo "$idiomas_subs" | cut -d '|' -f2)

    registrar_transcodificado "$archivo" "en proceso"
    local intentos=0 max_intentos=3

    while [ $intentos -lt $max_intentos ]; do
    nice -n 19 ionice -c3 HandBrakeCLI \
        --input "$archivo" \
        --output "$tmp" \
        --encoder x265 \
        --quality "$RF" \
        --preset="$PRESET" \
        --x265-preset="$SPEED" \
        --optimize \
        --all-audio \
        --aencoder "copy" \
        --audio-copy-mask "aac,ac3,dts,eac3,truehd" \
        --audio-fallback "av_aac" \
        --all-subtitles \
        < /dev/null >> "$LOG_FILE" 2>&1

        if [ $? -eq 0 ] && [ -f "$tmp" ]; then
            mv "$tmp" "${archivo%.*}.mkv"
            local final_bytes final_gb ahorro
            final_bytes=$(stat -c%s "${archivo%.*}.mkv")
            final_gb=$(awk "BEGIN {printf \"%.2f\", $final_bytes/1073741824}")
            ahorro=$(( (size_gb - final_gb) * 100 / size_gb ))

            # Tiempo de fin
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            # Convertir tiempo a formato legible
            local hours=$((duration / 3600))
            local minutes=$(( (duration % 3600) / 60 ))
            local seconds=$((duration % 60))
            local tiempo_transcurrido=$(printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds")

            enviar_telegram "✅ Transcodificación completada:\n📄 $(basename "${archivo%.*}.mkv")\n📏 Tamaño original: ${size_gb} GB\n📏 Tamaño final: ${final_gb} GB\n📉 Ahorro: ${ahorro}%\n⏱ Tiempo transcurrido: ${tiempo_transcurrido}"
            registrar_transcodificado "${archivo%.*}.mkv" "completado"
            limpiar_temporal "$tmp"
            
             # Enviar temperatura tras la transcodificación
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
        enviar_telegram "🔄 Reintento $intentos de $max_intentos: $(basename "$archivo")"
        sleep $((intentos * 10))
    done

    enviar_telegram "❌ Fallo crítico en: $(basename "$archivo") tras $max_intentos intentos."
    registrar_transcodificado "$archivo" "fallido_permanente"
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
    while IFS= read -r archivo; do
        transcodificados_map["$archivo"]=1
    done < <(cargar_transcodificados)

    for ruta in "${RUTAS[@]}"; do
        find "$ruta" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" \) \
             ! -iname "*_temp.*" -print0 | while IFS= read -r -d '' archivo; do
            if [[ ${transcodificados_map["$archivo"]+exists} ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Archivo ya transcodificado: $archivo" >> "$LOG_FILE"
                continue
            fi
            if ! verificar_espacio "$archivo"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Espacio insuficiente para: $archivo" >> "$LOG_FILE"
                continue
            fi
            archivos_pendientes=$((archivos_pendientes + 1))
            transcodificar "$archivo"
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Señal de terminación recibida. Finalizando..." >> "$LOG_FILE"
    enviar_telegram "🔴 *CodecCrusher detenido.*"
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
    local fecha_actual
    fecha_actual=$(date '+%Y-%m-%d %H:%M:%S')  # Fecha en formato original para la consulta

    # Obtener estadísticas de la base de datos
    local archivos_transcodificados
    archivos_transcodificados=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM transcodificados WHERE estado='completado' AND DATE(fecha_transcodificacion) = DATE('now', 'localtime');")

    # Calcular tamaños de archivos
    local espacio_original espacio_final
    espacio_original=0
    espacio_final=0

    while IFS='|' read -r archivo fecha estado; do
        if [[ "$estado" == "completado" && -f "$archivo" ]]; then
            if original_size=$(stat --format="%s" "$archivo" 2>/dev/null || stat -f "%z" "$archivo" 2>/dev/null) && \
               final_size=$(stat --format="%s" "${archivo%.*}.mkv" 2>/dev/null || stat -f "%z" "${archivo%.*}.mkv" 2>/dev/null); then
                espacio_original=$((espacio_original + original_size))
                espacio_final=$((espacio_final + final_size))
            else
                echo "⚠️ Archivo no encontrado: $archivo" >> "$LOG_FILE"
            fi
        fi
    done < <(sqlite3 "$DB_FILE" "SELECT archivo, fecha_transcodificacion, estado FROM transcodificados WHERE DATE(fecha_transcodificacion) = DATE('now', 'localtime');")

    # Verificar si se han encontrado archivos para evitar división por cero
    if (( espacio_original == 0 )); then
        enviar_telegram "📋 *Informe Diario:* No se encontraron transcodificaciones completadas hoy."
        return
    fi

    # Convertir a GB
    espacio_original=$(awk "BEGIN { printf \"%.2f\", $espacio_original / 1073741824 }")
    espacio_final=$(awk "BEGIN { printf \"%.2f\", $espacio_final / 1073741824 }")

    # Calcular ahorro
    local espacio_ahorrado ahorro_total
    espacio_ahorrado=$(awk "BEGIN { printf \"%.2f\", $espacio_original - $espacio_final }")
    ahorro_total=$(awk "BEGIN { printf \"%.2f\", ($espacio_ahorrado > 0 ? ($espacio_ahorrado / $espacio_original) * 100 : 0) }")

    # Convertir la fecha al formato español (DD/MM/YYYY)
    local fecha_formato_espana
    fecha_formato_espana=$(date -d "$fecha_actual" '+%d/%m/%Y')

    # Concatenar todo el informe en una sola variable
    local informe
    informe="📊 *Informe diario de CodecCrusher*\n\n📅 *Fecha:* ${fecha_formato_espana}\n✅ *Archivos transcodificados:* ${archivos_transcodificados}\n💾 *Espacio total ahorrado:* ${espacio_ahorrado} GB\n📏 *Tamaño original:* ${espacio_original} GB\n📉 *Tamaño final:* ${espacio_final} GB\n🔻 *Ahorro total:* ${ahorro_total}%"

    # Enviar el informe completo en un solo mensaje
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

    # Programar el informe diario
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
trap manejador_senal SIGINT SIGTERM EXIT

case "$1" in
    run)
        main
        ;;
    *)
        echo "Uso: $0 run"
        exit 2
        ;;
esac