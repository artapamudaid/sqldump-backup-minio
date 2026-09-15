-- Database Pertama di Docker 2
CREATE DATABASE IF NOT EXISTS crm_db;
USE crm_db;
CREATE TABLE pelanggan (id INT AUTO_INCREMENT PRIMARY KEY, nama_perusahaan VARCHAR(100));
INSERT INTO pelanggan (nama_perusahaan) VALUES ('PT Teknologi Kediri'), ('CV Maju Bersama');

-- Database Kedua di Docker 2
CREATE DATABASE IF NOT EXISTS inventory_db;
USE inventory_db;
CREATE TABLE stok_barang (id INT AUTO_INCREMENT PRIMARY KEY, nama_barang VARCHAR(100), jumlah INT);
INSERT INTO stok_barang (nama_barang, jumlah) VALUES ('Server Rack', 5), ('Switch Hub', 20);