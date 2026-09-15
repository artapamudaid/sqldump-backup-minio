#!/usr/bin/env bash
# Backup setiap database MariaDB ke MinIO dalam format .sql.gz.
#
# Prasyarat:
#   - Docker dan MinIO Client (mc) tersedia di host.
#   - Alias mc telah dikonfigurasi, misalnya:
#       mc alias set minio-local http://127.0.0.1:9110 USER_MINIO PASSWORD_MINIO
#
# Contoh:
#   MINIO_BUCKET=database-backups ./backup-to-minio.sh
#   KEEP_LOCAL_BACKUP=1 ./backup-to-minio.sh
#
# Format BACKUP_TARGETS: nama-container:produk[:database[,database...]]
# Contoh:
#   BACKUP_TARGETS="mariadb-hris:hris" ./backup-to-minio.sh
#   BACKUP_TARGETS="mariadb-hris:hris:hris_db" ./backup-to-minio.sh
# Hasil: database-backups/hris/20260915T010203Z_hris_db.sql.gz

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
readonly DATE_FOLDER="$(TZ=Asia/Jakarta date +%F)"

MINIO_ALIAS="${MINIO_ALIAS:-minio-local}"
MINIO_BUCKET="${MINIO_BUCKET:-database-backups}"
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/backups}"
KEEP_LOCAL_BACKUP="${KEEP_LOCAL_BACKUP:-0}"
BACKUP_TARGETS="${BACKUP_TARGETS:-mariadb-server-1:server-1 mariadb-server-2:server-2}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Perintah '$1' tidak ditemukan."
}

cleanup_failed_backup() {
  local temporary_file="$1"
  rm -f -- "$temporary_file"
}

list_databases() {
  local container="$1"
  docker exec "$container" sh -c \
    'exec mysql -uroot -p"$MARIADB_ROOT_PASSWORD" -Nse "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN (\"information_schema\", \"mysql\", \"performance_schema\", \"sys\") ORDER BY SCHEMA_NAME;"'
}

require_command docker
require_command mc
require_command gzip

docker info >/dev/null 2>&1 || die "Docker daemon tidak dapat diakses."
mc ls "$MINIO_ALIAS" >/dev/null 2>&1 || die "Alias MinIO '$MINIO_ALIAS' tidak dapat diakses."

mkdir -p -- "$BACKUP_DIR"
mc mb --ignore-existing "${MINIO_ALIAS}/${MINIO_BUCKET}" >/dev/null

for target in $BACKUP_TARGETS; do
  IFS=':' read -r container product requested_databases <<<"$target"
  [[ -n "$container" && -n "$product" ]] \
    || die "Target '$target' tidak valid. Gunakan container:produk[:database[,database...]]."
  [[ "$product" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "Nama produk '$product' hanya boleh berisi huruf, angka, titik, garis bawah, atau strip."

  docker inspect --type container "$container" >/dev/null 2>&1 \
    || die "Container '$container' tidak ditemukan."

  if [[ -z "$requested_databases" || "$requested_databases" == "all" || "$requested_databases" == "all-databases" ]]; then
    database_list="$(list_databases "$container")"
  else
    database_list="${requested_databases//,/ }"
  fi
  [[ -n "$database_list" ]] || die "Tidak ada database pengguna pada container '$container'."

  for database_name in $database_list; do
    [[ "$database_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "Nama database '$database_name' hanya boleh berisi huruf, angka, titik, garis bawah, atau strip."

    file_name="${TIMESTAMP}_${database_name}.sql.gz"
    final_file="${BACKUP_DIR}/${product}/${file_name}"
    temporary_file="${final_file}.partial"
    object_path="${MINIO_ALIAS}/${MINIO_BUCKET}/${product}/${DATE_FOLDER}/${file_name}"
    mkdir -p -- "$(dirname -- "$final_file")"

    log "Membuat dump ${database_name} dari ${container}..."
    if ! docker exec "$container" sh -c \
      "exec mysqldump -uroot -p\"\$MARIADB_ROOT_PASSWORD\" --databases \"${database_name}\" --single-transaction --routines --events --triggers --hex-blob --skip-lock-tables" \
      | gzip -c >"$temporary_file"; then
      cleanup_failed_backup "$temporary_file"
      die "Dump database '$database_name' dari '$container' gagal."
    fi

    mv -- "$temporary_file" "$final_file"
    log "Mengunggah ${file_name} ke ${object_path}..."
    if ! mc cp "$final_file" "$object_path"; then
      die "Upload gagal. Salinan lokal dipertahankan di '$final_file'."
    fi

    log "Backup berhasil: ${object_path}"
    if [[ "$KEEP_LOCAL_BACKUP" != "1" ]]; then
      rm -f -- "$final_file"
    fi
  done
done
