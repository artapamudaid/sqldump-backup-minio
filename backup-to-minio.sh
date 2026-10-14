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
BACKUP_LOG_FILE=""
BACKUP_LOG_UPLOADED=0
CURRENT_LOG_OBJECT_FOLDER=""
CURRENT_LOG_PRODUCT=""
BACKUP_SUCCESS_COUNT=0
BACKUP_TOTAL_BYTES=0
BACKUP_FOLDERS=()
declare -A BACKUP_FOLDER_COUNTS=()
declare -A BACKUP_FOLDER_BYTES=()
declare -A BACKUP_FOLDER_LINES=()

log() {
  local line

  line="$(printf '[%s] %s' "$(date '+%F %T')" "$*")"
  if [[ -n "$BACKUP_LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$BACKUP_LOG_FILE"
  fi
}

status_success() {
  printf 'BERHASIL: database %s berhasil di-backup. Ukuran awal: %s, ukuran akhir: %s.\n' "$1" "$2" "$3" >&2
}

status_failed() {
  printf 'GAGAL: %s\n' "$1" >&2
}

die_database() {
  local database_name="$1"
  local reason="$2"

  die "database ${database_name} gagal di-backup. Alasan: ${reason}"
}

die() {
  local message

  message="GAGAL: backup database ke MinIO gagal di host $(hostname). Error: $*"
  log "ERROR: $*"
  status_failed "$*"
  append_backup_log_section "Ringkasan gagal" "$message"
  upload_backup_log_to_minio
  send_telegram_log_file "$message"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Perintah '$1' tidak ditemukan."
}

cleanup_failed_backup() {
  local temporary_file="$1"
  rm -f -- "$temporary_file"
}

cleanup_backup_log_file() {
  if [[ -n "$BACKUP_LOG_FILE" ]]; then
    rm -f -- "$BACKUP_LOG_FILE"
  fi
  BACKUP_LOG_FILE=""
  BACKUP_LOG_UPLOADED=0
  CURRENT_LOG_OBJECT_FOLDER=""
  CURRENT_LOG_PRODUCT=""
}

init_backup_log_file() {
  local product="$1"
  local container="$2"

  cleanup_backup_log_file

  BACKUP_LOG_FILE="$(mktemp "/tmp/backup-to-minio-${TIMESTAMP}.XXXXXX.txt")"
  BACKUP_LOG_UPLOADED=0
  CURRENT_LOG_PRODUCT="$product"
  CURRENT_LOG_OBJECT_FOLDER="${MINIO_BUCKET}/${product}/${DATE_FOLDER}"
  trap cleanup_backup_log_file EXIT
  {
    printf 'Log backup database ke MinIO\n'
    printf 'Host: %s\n' "$(hostname)"
    printf 'Waktu: %s\n' "$(date '+%F %T %Z')"
    printf 'Bucket: %s\n' "$MINIO_BUCKET"
    printf 'Target: %s\n' "$product"
    printf 'Container: %s\n' "$container"
    printf '\n'
  } >>"$BACKUP_LOG_FILE"
}

upload_backup_log_to_minio() {
  local log_object_path

  [[ -n "$BACKUP_LOG_FILE" && -f "$BACKUP_LOG_FILE" ]] || return 0
  [[ -n "$CURRENT_LOG_OBJECT_FOLDER" && -n "$CURRENT_LOG_PRODUCT" ]] || return 0
  (( BACKUP_LOG_UPLOADED == 0 )) || return 0

  log_object_path="${MINIO_ALIAS}/${CURRENT_LOG_OBJECT_FOLDER}/backup-to-minio-${TIMESTAMP}_${CURRENT_LOG_PRODUCT}.txt"

  if mc mb --ignore-existing "${MINIO_ALIAS}/${MINIO_BUCKET}" >/dev/null 2>&1 \
    && mc cp "$BACKUP_LOG_FILE" "$log_object_path" >/dev/null 2>&1; then
    BACKUP_LOG_UPLOADED=1
  else
    printf '[%s] WARNING: File log gagal diunggah ke MinIO: %s\n' "$(date '+%F %T')" "$log_object_path" >&2
  fi
}

notify_telegram() {
  local message="$1"

  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 0

  [[ -n "$BACKUP_LOG_FILE" ]] || return 0

  {
    printf '\n%s\n' "$message"
  } >>"$BACKUP_LOG_FILE"

  send_telegram_log_file "$message"
}

append_backup_log_section() {
  local title="$1"
  local body="$2"

  [[ -n "$BACKUP_LOG_FILE" ]] || return 0

  {
    printf '\n%s\n' "$title"
    printf '%s\n' "$body"
  } >>"$BACKUP_LOG_FILE"
}

send_telegram_log_file() {
  local caption="$1"
  local -a curl_args

  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 0
  [[ -n "$BACKUP_LOG_FILE" && -f "$BACKUP_LOG_FILE" ]] || return 0

  if (( ${#caption} > 900 )); then
    caption="${caption:0:897}..."
  fi

  curl_args=(
    -fsS
    -X POST
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument"
    -F "chat_id=${TELEGRAM_CHAT_ID}"
    -F "caption=${caption}"
    -F "document=@${BACKUP_LOG_FILE};filename=backup-to-minio-${TIMESTAMP}_${CURRENT_LOG_PRODUCT}.txt"
  )

  if [[ -n "$TELEGRAM_THREAD_ID" ]]; then
    curl_args+=(-F "message_thread_id=${TELEGRAM_THREAD_ID}")
  fi

  curl "${curl_args[@]}" >/dev/null || log "WARNING: File log Telegram gagal dikirim."
}

human_size() {
  local bytes="$1"

  awk -v bytes="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ")
    size = bytes + 0
    unit_index = 1
    while (size >= 1024 && unit_index < 5) {
      size = size / 1024
      unit_index++
    }
    if (unit_index == 1) {
      printf "%d %s", size, unit[unit_index]
    } else {
      printf "%.2f %s", size, unit[unit_index]
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

reset_target_summary() {
  BACKUP_SUCCESS_COUNT=0
  BACKUP_TOTAL_BYTES=0
  BACKUP_FOLDERS=()
  BACKUP_FOLDER_COUNTS=()
  BACKUP_FOLDER_BYTES=()
  BACKUP_FOLDER_LINES=()
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
  local summary

  summary="$(build_success_summary_message)"
  append_backup_log_section "Ringkasan sukses" "$summary"

  for folder in "${BACKUP_FOLDERS[@]}"; do
    folder_size="$(human_size "${BACKUP_FOLDER_BYTES[$folder]}")"
    message="$(printf 'List database: %s\nTotal DB: %s\nTotal SQL.GZ: %s\n\n%s' "$folder" "${BACKUP_FOLDER_COUNTS[$folder]}" "$folder_size" "${BACKUP_FOLDER_LINES[$folder]}")"
    append_backup_log_section "Detail ${folder}" "$message"
  done

  send_telegram_log_file "$summary"
}

require_command docker
require_command mc
require_command gzip
require_command awk
require_command stat
require_command mktemp
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

  reset_target_summary
  init_backup_log_file "$local_product" "$local_container"

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
      die_database "$database_name" "gagal membaca ukuran dari container '$local_container'."
    fi
    [[ "$database_bytes" =~ ^[0-9]+$ ]] \
      || die_database "$database_name" "ukuran dari container '$local_container' tidak valid: ${database_bytes}"
    database_size="$(human_size "$database_bytes")"

    log "Membuat dump ${database_name} dari ${local_container}..."
    if ! docker exec -e "MARIADB_USER=${local_db_user}" -e "MYSQL_PWD=${local_db_password}" "$local_container" sh -c \
      "exec mysqldump -u\"\$MARIADB_USER\" --databases \"${database_name}\" --single-transaction --routines --events --triggers --hex-blob --skip-lock-tables" \
      | gzip -c >"$temporary_file"; then
      cleanup_failed_backup "$temporary_file"
      die_database "$database_name" "dump dari container '$local_container' gagal."
    fi

    mv -- "$temporary_file" "$final_file"
    backup_bytes="$(stat -c '%s' "$final_file")"
    backup_size="$(human_size "$backup_bytes")"
    log "Mengunggah ${file_name} ke ${object_path}..."
    if ! mc cp "$final_file" "$object_path"; then
      die_database "$database_name" "upload ke MinIO gagal. Salinan lokal dipertahankan di '$final_file'."
    fi

    log "Backup berhasil: ${object_path}"
    status_success "$database_name" "$database_size" "$backup_size"
    BACKUP_SUCCESS_COUNT=$((BACKUP_SUCCESS_COUNT + 1))
    BACKUP_TOTAL_BYTES=$((BACKUP_TOTAL_BYTES + backup_bytes))
    track_folder_summary "$object_folder" "$backup_bytes"
    track_folder_database_line "$object_folder" "- ${database_name}: SQL.GZ ${backup_size}, DB ${database_size}, file ${file_name}"
    if [[ "$KEEP_LOCAL_BACKUP" != "1" ]]; then
      rm -f -- "$final_file"
    fi
  done

  notify_success_telegram
  upload_backup_log_to_minio
  cleanup_backup_log_file
done
