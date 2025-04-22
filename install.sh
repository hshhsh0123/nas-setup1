#!/bin/bash
# === ShadowNAS: Full Auto Installer ===
# By ChatGPT for hshhsh0123 (with E2EE, VPN, dedup, auto-sort, DNS privacy, debugging, external access)

set -e
sudo mkdir -p /var/log
exec > >(sudo tee /var/log/nas-install.log) 2>&1

## =====================
## 0. 사용자 정의 변수
## =====================
USERS=("jinsik" "sunho" "hyunjung" "seoyoon" "dayan")
PASSWORD="090928sh!"
SHARED_FOLDER="/mnt/securehdd/shared"
USER_ROOT="/mnt/securehdd/users"
WG_PORT=51820
PUBLIC_IP=$(curl -s https://api.ipify.org)

## =====================
## 1. 패키지 설치
## =====================
sudo apt update && sudo apt install -y \
  docker.io docker-compose \
  cryptsetup \
  wireguard \
  curl \
  git \
  ufw \
  rdfind \
  qrencode \
  dnscrypt-proxy \
  age zstd mergerfs

## =====================
## 2. LUKS 디스크 2개 병합 마운트 (1TB x 2)
## =====================
sudo mkdir -p /mnt/securehdd1 /mnt/securehdd2 /mnt/securehdd
sudo cryptsetup luksOpen /dev/sdb secure1
sudo cryptsetup luksOpen /dev/sda secure2
sudo mount /dev/mapper/secure1 /mnt/securehdd1
sudo mount /dev/mapper/secure2 /mnt/securehdd2
sudo mergerfs /mnt/securehdd1:/mnt/securehdd2 /mnt/securehdd

## =====================
## 3. 사용자 폴더 생성 + 제약
## =====================
sudo mkdir -p "$SHARED_FOLDER"
for u in "${USERS[@]}"; do
  sudo mkdir -p "$USER_ROOT/$u/raw_upload"
  sudo mkdir -p "$USER_ROOT/$u/photos"
  sudo mkdir -p "$USER_ROOT/$u/videos"
  sudo mkdir -p "$USER_ROOT/$u/documents"
  sudo mkdir -p "$USER_ROOT/$u/archives"
  sudo mkdir -p "$USER_ROOT/$u/e2ee"
  sudo touch "$USER_ROOT/$u/.sort_enabled"
done

## =====================
## 완료 메시지
## =====================
echo -e "\n[✅ NAS 설치 준비 완료]"
echo "- 병합된 암호화 디스크: /mnt/securehdd"
echo "- 사용자별 폴더 위치: /mnt/securehdd/users/사용자명"
echo "- 공유 폴더: $SHARED_FOLDER"
echo "- 외부 IP: $PUBLIC_IP"
echo "- 설치 로그: /var/log/nas-install.log"
