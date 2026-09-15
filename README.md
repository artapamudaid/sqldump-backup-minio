# Backup MariaDB ke MinIO

Proyek ini menjalankan dua container MariaDB 10.3 dan menyimpan backup setiap database ke MinIO dalam format terkompresi `.sql.gz`.

## Struktur

```text
.
├── docker-compose.yml          # MariaDB 10.3 untuk simulasi
├── InitDB/                     # Data awal database simulasi
├── MinIO/                      # Docker Compose, .env.example, dan konfigurasi MinIO AIStor
├── backup.env.example          # Template konfigurasi target backup
└── backup-to-minio.sh          # Dump, kompres, dan upload backup
```

Hasil upload di MinIO menggunakan struktur berikut:

```text
BUCKET/
└── NAMA_APLIKASI/
    └── YYYY-MM-DD/
        └── YYYYMMDDTHHMMSSZ_nama_database.sql.gz
```

Contoh:

```text
backup-maria-db/app-1/2026-09-15/20260915T170500Z_hris_db.sql.gz
```

Folder tanggal selalu memakai zona waktu `Asia/Jakarta`. Timestamp pada nama file mencegah file tertimpa jika backup dilakukan lebih dari sekali sehari.

## Prasyarat

- Docker Engine dan Docker Compose v2
- `gzip`
- MinIO Client (`mc`)
- Hak akses Docker untuk pengguna yang menjalankan skrip

> Jangan menjalankan `sudo apt install mc`: paket tersebut adalah Midnight Commander, bukan MinIO Client.

Untuk AIStor Client pada Linux AMD64, unduh binary resmi lalu pasang ke PATH:

```bash
curl -fL https://dl.min.io/aistor/mc/release/linux-amd64/mc -o /tmp/mc
chmod +x /tmp/mc
sudo install -m 0755 /tmp/mc /usr/local/bin/mc
mc --version
```

## Menjalankan MariaDB simulasi

Jalankan dari root proyek:

```bash
docker compose up -d
docker compose ps
```

Container simulasi yang tersedia:

| Container | Port host | Database awal |
| --- | ---: | --- |
| `mariadb-server-1` | `3377` | `hris_db`, `finance_db` |
| `mariadb-server-2` | `3388` | `crm_db`, `inventory_db` |

## Menjalankan MinIO

1. Buat konfigurasi lokal dari template:

```bash
cp MinIO/.env.example MinIO/.env
```

2. Edit `MinIO/.env`, lalu ganti seluruh nilai `CHANGE_ME_*`. Jangan commit file ini bila berisi kredensial produksi.
3. Pastikan `${HOME}/minio/minio.license` adalah **file lisensi**, bukan direktori. AIStor memerlukan lisensi yang valid.
4. Jalankan MinIO:

```bash
cd MinIO
docker compose up -d
docker compose logs --tail=50
```

Jika `MINIO_BIND_IP=127.0.0.1`, endpoint hanya dapat diakses dari host yang menjalankan MinIO:

```text
S3 API:  http://127.0.0.1:9110
Console: http://127.0.0.1:9111
```

## Menyiapkan alias MinIO Client

Jalankan dari root proyek. Perintah ini mengambil Access Key dan Secret Key dari `MinIO/.env` tanpa menampilkannya di terminal:

```bash
MINIO_USER=$(sed -n 's/^MINIO_ROOT_USER=//p' MinIO/.env)
MINIO_PASS=$(sed -n 's/^MINIO_ROOT_PASSWORD=//p' MinIO/.env)

mc alias set minio-local http://127.0.0.1:9110 "$MINIO_USER" "$MINIO_PASS"

unset MINIO_USER MINIO_PASS
mc admin info minio-local
```

`minio-local` adalah nama alias. Kredensial alias disimpan oleh `mc` pada `~/.mc/config.json`; skrip backup hanya memerlukan nama alias tersebut.

## Konfigurasi backup

Buat konfigurasi lokal dari template:

```bash
cp backup.env.example backup.env
```

Edit `backup.env`, terutama `BACKUP_DIR` agar memakai path absolut host. File `backup.env` diabaikan oleh Git dan aman digunakan untuk konfigurasi per server.

Arti konfigurasi:

| Variabel | Keterangan |
| --- | --- |
| `MINIO_ALIAS` | Nama alias `mc` yang telah dibuat sebelumnya. |
| `MINIO_BUCKET` | Bucket tujuan; akan dibuat otomatis bila belum ada. |
| `BACKUP_DIR` | Folder sementara untuk file `.sql.gz`. |
| `KEEP_LOCAL_BACKUP` | `1` untuk menyimpan file lokal setelah upload, `0` untuk menghapusnya setelah upload sukses. |
| `BACKUP_TARGETS` | Daftar target dengan format `container:aplikasi[:database[,database...]]`. |

Jika bagian database dihilangkan atau bernilai `all`/`all-databases`, skrip mencari semua database pengguna pada container dan mengecualikan database sistem (`mysql`, `sys`, `information_schema`, dan `performance_schema`).

Contoh satu aplikasi dengan satu database:

```dotenv
BACKUP_TARGETS="mariadb-hris:hris:hris_db"
```

## Menjalankan backup manual

```bash
cd /your/directory/sqldump-backup-minio
set -a
source backup.env
set +a
./backup-to-minio.sh
```

Verifikasi hasil upload:

```bash
mc ls --recursive "${MINIO_ALIAS}/${MINIO_BUCKET}"
```

Skrip menghentikan proses jika dump atau upload gagal. Bila upload gagal, file lokal hasil dump tidak dihapus agar dapat diperiksa atau diunggah ulang.

## Penjadwalan backup setiap 00:05 WIB

Pastikan folder log tersedia:

```bash
mkdir -p /your/directory/sqldump-backup-minio/logs
```

Edit crontab milik pengguna yang memiliki alias `mc` dan akses Docker:

```bash
crontab -e
```

Tambahkan:

```cron
CRON_TZ=Asia/Jakarta
PATH=/usr/local/bin:/usr/bin:/bin

5 0 * * * /usr/bin/flock -n /tmp/backup-to-minio.lock /usr/bin/env bash -c 'set -a; . /your/directory/sqldump-backup-minio/backup.env; set +a; exec /your/directory/sqldump-backup-minio/backup-to-minio.sh' >> /your/directory/sqldump-backup-minio/logs/backup-to-minio.log 2>&1
```

`flock` mencegah dua proses backup berjalan bersamaan. Lihat log dengan:

```bash
tail -f /your/directory/sqldump-backup-minio/logs/backup-to-minio.log
```

## Deployment untuk server database terpisah

Skrip menggunakan `docker exec`, sehingga harus dijalankan **di server yang memiliki container MariaDB**. Untuk beberapa server database:

1. Salin `backup-to-minio.sh` dan `backup.env` ke setiap server.
2. Buat alias `mc` pada setiap server menuju MinIO pusat.
3. Isi `BACKUP_TARGETS` hanya dengan container pada server tersebut.
4. Pasang cron pada setiap server.

Untuk skenario ini, endpoint MinIO tidak boleh hanya dibind ke `127.0.0.1`. Gunakan IP LAN atau domain MinIO yang dapat dijangkau server database, aktifkan TLS untuk produksi, dan buka port S3 hanya untuk server backup yang diizinkan oleh firewall. Hindari Docker Remote API tanpa TLS.

Gunakan service account MinIO khusus untuk tiap server produksi, dengan izin hanya pada bucket/prefix backup yang diperlukan. Jangan gunakan root credentials MinIO untuk otomatisasi produksi.
