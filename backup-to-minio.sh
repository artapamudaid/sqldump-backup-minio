#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(TZ=Asia/Jakarta date +%Y%m%dT%H%M%S%z)"
readonly DATE_FOLDER="$(TZ=Asia/Jakarta date +%F)"

MINIO_ALIAS="${MINIO_ALIAS:-minio-local}"
MINIO_BUCKET="${MINIO_BUCKET:-database-backups}"
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/backups}"
KEEP_LOCAL_BACKUP="${KEEP_LOCAL_BACKUP:-0}"
MARIADB_USER="${MARIADB_USER:-root}"
MARIADB_PASSWORD="${MARIADB_PASSWORD:-${MARIADB_ROOT_PASSWORD:-rootpassword}}"
BACKUP_TARGETS="${BACKUP_TARGETS:-mariadb-server-1:server-1 mariadb-server-2:server-2}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_THREAD_ID="${TELEGRAM_THREAD_ID:-}"
BACKUP_SUCCESS_COUNT=0
BACKUP_TOTAL_BYTES=0
BACKUP_FOLDERS=()
declare -A BACKUP_FOLDER_COUNTS=()
declare -A BACKUP_FOLDER_BYTES=()
declare -A BACKUP_FOLDER_LINES=()

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  log "ERROR: $*"
  notify_telegram "GAGAL: backup database ke MinIO gagal di host $(hostname). Error: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Perintah '$1' tidak ditemukan."
}

cleanup_failed_backup() {
  local temporary_file="$1"
  rm -f -- "$temporary_file"
}

notify_telegram() {
  local message="$1"
  local line
  local chunk=""
  local max_length=3500

  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ${#chunk} > 0 && ${#chunk} + ${#line} + 1 > max_length )); then
      notify_telegram_chunk "$chunk"
      chunk=""
    fi

    if (( ${#chunk} == 0 )); then
      chunk="$line"
    else
      chunk+=$'\n'"$line"
    fi
  done <<<"$message"

  if [[ -n "$chunk" ]]; then
    notify_telegram_chunk "$chunk"
  fi
}

notify_telegram_chunk() {
  local message="$1"
  local -a curl_args

  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 0

  curl_args=(
    -fsS
    -X POST
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    -d "chat_id=${TELEGRAM_CHAT_ID}"
    -d "text=${message}"
  )

  if [[ -n "$TELEGRAM_THREAD_ID" ]]; then
    curl_args+=(-d "message_thread_id=${TELEGRAM_THREAD_ID}")
  fi

  curl "${curl_args[@]}" >/dev/null || log "WARNING: Notifikasi Telegram gagal dikirim."
}

human_size() {
  local bytes="$1"

  awk -v bytes="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ")
    size = bytes + 0
    index = 1
    while (size >= 1024 && index < 5) {
      size = size / 1024
      index++
    }
    if (index == 1) {
      printf "%d %s", size, unit[index]
    } else {
      printf "%.2f %s", size, unit[index]
    }
  }'
}

database_size_bytes() {
  local container="$1"
  local database_name="$2"
  local db_user="$3"
  local db_password="$4"

  docker exec -e "MARIADB_USER=${db_user}" -e "MYSQL_PWD=${db_password}" -e "DATABASE_NAME=${database_name}" "$container" sh -c \
    'exec mysql -u"$MARIADB_USER" -Nse "SELECT COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0) FROM information_schema.TABLES WHERE TABLE_SCHEMA = \"$DATABASE_NAME\";"'
}

build_success_summary_message() {
  local total_size
  local message
  local folder
  local folder_size

  total_size="$(human_size "$BACKUP_TOTAL_BYTES")"
  message="$(printf 'SUKSES: backup database ke MinIO selesai.\nHost: %s\nBucket: %s\nTanggal folder: %s\nTotal database/file: %s\nTotal ukuran SQL.GZ: %s' "$(hostname)" "$MINIO_BUCKET" "$DATE_FOLDER" "$BACKUP_SUCCESS_COUNT" "$total_size")"

  message+=$'\n\n'"Ringkasan folder:"
  for folder in "${BACKUP_FOLDERS[@]}"; do
    folder_size="$(human_size "${BACKUP_FOLDER_BYTES[$folder]}")"
    message+=$'\n'"- ${folder}: ${BACKUP_FOLDER_COUNTS[$folder]} DB, SQL.GZ ${folder_size}"
  done

  printf '%s' "$message"
}

track_folder_summary() {
  local folder="$1"
  local bytes="$2"

  if [[ -z "${BACKUP_FOLDER_COUNTS[$folder]+x}" ]]; then
    BACKUP_FOLDERS+=("$folder")
    BACKUP_FOLDER_COUNTS["$folder"]=0
    BACKUP_FOLDER_BYTES["$folder"]=0
    BACKUP_FOLDER_LINES["$folder"]=""
  fi

  BACKUP_FOLDER_COUNTS["$folder"]=$((BACKUP_FOLDER_COUNTS["$folder"] + 1))
  BACKUP_FOLDER_BYTES["$folder"]=$((BACKUP_FOLDER_BYTES["$folder"] + bytes))
}

track_folder_database_line() {
  local folder="$1"
  local line="$2"

  if [[ -z "${BACKUP_FOLDER_LINES[$folder]}" ]]; then
    BACKUP_FOLDER_LINES["$folder"]="$line"
  else
    BACKUP_FOLDER_LINES["$folder"]+=$'\n'"$line"
  fi
}

notify_success_telegram() {
  local folder
  local folder_size
  local message

  notify_telegram "$(build_success_summary_message)"

  for folder in "${BACKUP_FOLDERS[@]}"; do
    folder_size="$(human_size "${BACKUP_FOLDER_BYTES[$folder]}")"
    message="$(printf 'List database: %s\nTotal DB: %s\nTotal SQL.GZ: %s\n\n%s' "$folder" "${BACKUP_FOLDER_COUNTS[$folder]}" "$folder_size" "${BACKUP_FOLDER_LINES[$folder]}")"
    notify_telegram "$message"
  done
}

require_command docker
require_command mc
require_command gzip
require_command awk
require_command stat
if [[ -n "$TELEGRAM_BOT_TOKEN" || -n "$TELEGRAM_CHAT_ID" ]]; then
  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] \
    || die "TELEGRAM_BOT_TOKEN dan TELEGRAM_CHAT_ID harus diisi keduanya."
  require_command curl
fi

docker info >/dev/null 2>&1 || die "Docker daemon tidak dapat diakses."
mc ls "$MINIO_ALIAS" >/dev/null 2>&1 || die "Alias MinIO '$MINIO_ALIAS' tidak dapat diakses."

mkdir -p -- "$BACKUP_DIR"
mc mb --ignore-existing "${MINIO_ALIAS}/${MINIO_BUCKET}" >/dev/null

for target in $BACKUP_TARGETS; do
  IFS=':' read -r -a target_parts <<<"$target"
  [[ ${#target_parts[@]} -ge 2 ]] \
    || die "Target '$target' tidak valid. Format yang didukung: container:produk[:database[,database...]][:user[:password]]."

  local_container="${target_parts[0]}"
  local_product="${target_parts[1]}"
  local_requested_databases="${target_parts[2]:-}"
  local_db_user="${MARIADB_USER}"
  local_db_password="${MARIADB_PASSWORD}"

  case ${#target_parts[@]} in
    2)
      ;;
    3)
      local_requested_databases="${target_parts[2]}"
      ;;
    4)
      local_requested_databases="${target_parts[2]}"
      local_db_user="${target_parts[3]}"
      ;;
    5)
      local_requested_databases="${target_parts[2]}"
      local_db_user="${target_parts[3]}"
      local_db_password="${target_parts[4]}"
      ;;
    *)
      die "Target '$target' terlalu banyak bagian. Gunakan format container:produk[:database[,database...]][:user[:password]]."
      ;;
  esac

  [[ -n "$local_container" && -n "$local_product" ]] \
    || die "Target '$target' tidak valid. Gunakan container:produk[:database[,database...]][:user[:password]]."
  [[ "$local_product" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "Nama produk '$local_product' hanya boleh berisi huruf, angka, titik, garis bawah, atau strip."

  docker inspect --type container "$local_container" >/dev/null 2>&1 \
    || die "Container '$local_container' tidak ditemukan."

  if [[ -z "$local_requested_databases" || "$local_requested_databases" == "all" || "$local_requested_databases" == "all-databases" ]]; then
    database_list="$(docker exec -e "MARIADB_USER=${local_db_user}" -e "MYSQL_PWD=${local_db_password}" "$local_container" sh -c 'exec mysql -u"$MARIADB_USER" -Nse "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN (\"information_schema\", \"mysql\", \"performance_schema\", \"sys\") ORDER BY SCHEMA_NAME;"')"
  else
    database_list="${local_requested_databases//,/ }"
  fi
  [[ -n "$database_list" ]] || die "Tidak ada database pengguna pada container '$local_container'."

  for database_name in $database_list; do
    [[ "$database_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "Nama database '$database_name' hanya boleh berisi huruf, angka, titik, garis bawah, atau strip."

    file_name="${TIMESTAMP}_${database_name}.sql.gz"
    final_file="${BACKUP_DIR}/${local_product}/${file_name}"
    temporary_file="${final_file}.partial"
    object_path="${MINIO_ALIAS}/${MINIO_BUCKET}/${local_product}/${DATE_FOLDER}/${file_name}"
    object_folder="${MINIO_BUCKET}/${local_product}/${DATE_FOLDER}"
    mkdir -p -- "$(dirname -- "$final_file")"

    if ! database_bytes="$(database_size_bytes "$local_container" "$database_name" "$local_db_user" "$local_db_password")"; then
      die "Gagal membaca ukuran database '$database_name' dari '$local_container'."
    fi
    [[ "$database_bytes" =~ ^[0-9]+$ ]] \
      || die "Ukuran database '$database_name' dari '$local_container' tidak valid: ${database_bytes}"
    database_size="$(human_size "$database_bytes")"

    log "Membuat dump ${database_name} dari ${local_container}..."
    if ! docker exec -e "MARIADB_USER=${local_db_user}" -e "MYSQL_PWD=${local_db_password}" "$local_container" sh -c \
      "exec mysqldump -u\"\$MARIADB_USER\" --databases \"${database_name}\" --single-transaction --routines --events --triggers --hex-blob --skip-lock-tables" \
      | gzip -c >"$temporary_file"; then
      cleanup_failed_backup "$temporary_file"
      die "Dump database '$database_name' dari '$local_container' gagal."
    fi

    mv -- "$temporary_file" "$final_file"
    backup_bytes="$(stat -c '%s' "$final_file")"
    backup_size="$(human_size "$backup_bytes")"
    log "Mengunggah ${file_name} ke ${object_path}..."
    if ! mc cp "$final_file" "$object_path"; then
      die "Upload gagal. Salinan lokal dipertahankan di '$final_file'."
    fi

    log "Backup berhasil: ${object_path}"
    BACKUP_SUCCESS_COUNT=$((BACKUP_SUCCESS_COUNT + 1))
    BACKUP_TOTAL_BYTES=$((BACKUP_TOTAL_BYTES + backup_bytes))
    track_folder_summary "$object_folder" "$backup_bytes"
    track_folder_database_line "$object_folder" "- ${database_name}: SQL.GZ ${backup_size}, DB ${database_size}, file ${file_name}"
    if [[ "$KEEP_LOCAL_BACKUP" != "1" ]]; then
      rm -f -- "$final_file"
    fi
  done
done

notify_success_telegram
