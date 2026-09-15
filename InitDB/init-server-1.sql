-- Database Pertama di Docker 1
CREATE DATABASE IF NOT EXISTS hris_db;
USE hris_db;
CREATE TABLE karyawan (id INT AUTO_INCREMENT PRIMARY KEY, nama VARCHAR(100));
INSERT INTO karyawan (nama) VALUES ('Budi Santoso'), ('Siti Aminah');

-- Database Kedua di Docker 1
CREATE DATABASE IF NOT EXISTS finance_db;
USE finance_db;
CREATE TABLE penggajian (id INT AUTO_INCREMENT PRIMARY KEY, jabatan VARCHAR(50), gaji INT);
INSERT INTO penggajian (jabatan, gaji) VALUES ('Manager', 15000000), ('Staff', 7000000);