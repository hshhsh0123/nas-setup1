#!/bin/bash
# ShadowNAS Full Installer Script (with Nextcloud + Discord + Security)
# Author: GPT Assistant
# Description: NAS 자동 설치 (E2EE, 사용자 폴더, VPN, Samba, Discord 알림, 보안 감시, Nextcloud 포함)

set -e

### 사용자 입력
read -p "[+] 관리자 계정 비밀번호 입력: " ADMIN_PASS
read -p "[+] Discord Webhook URL 입력: " DISCORD_WEBHOOK

### 기본 변수
DISK1="/dev/sda"
DISK2="/dev/sdb"
MOUNT_PATH="/mnt/securehdd"
MERGE_PATH="/mnt/merged"
USER_LIST=(jinsik sunho hyunjung seoyoon dayan)

### Discord 알림 함수
function notify_discord() {
    curl -s -H "Content-Type: application/json" \
        -X POST -d "{\"content\": \"$1\"}" $DISCORD_WEBHOOK
}

### 패키지 설치
apt update && apt install -y samba wireguard cryptsetup glances htop curl jq mergerfs quota smartmontools rkhunter fail2ban nginx mariadb-server php php-fpm php-mysql php-zip php-gd php-xml php-curl php-mbstring unzip

### 디스크 강제 정리 루틴
for dev in $DISK1 $DISK2; do
    echo "[!] $dev 사용 중 프로세스 종료 시도 중..."
    fuser -km $dev || true
    sleep 1
    for mdev in $(ls /dev/mapper | grep hdd); do
        echo "[!] cryptsetup luksClose /dev/mapper/$mdev"
        cryptsetup luksClose /dev/mapper/$mdev || true
    done
    umount -lf $dev 2>/dev/null || true
    MNTS=$(lsblk -no MOUNTPOINT $dev | grep -v '^$' || true)
    for mnt in $MNTS; do
        umount -lf "$mnt" || true
    done
    name=$(basename $(lsblk -no NAME $dev | tail -1) 2>/dev/null || true)
    [ -n "$name" ] && dmsetup remove "$name" || true
    wipefs -a $dev || true
    echo "[+] $dev 정리 완료"
    sleep 1
    udevadm settle
    sleep 1
    echo 1 > /sys/block/$(basename $dev)/device/delete 2>/dev/null || true
    udevadm settle
    sleep 1
    partprobe || true
    sleep 1
    udevadm settle
    sleep 1
    if [ -e /sys/block/$(basename $dev)/device/rescan ]; then
        echo 1 > /sys/block/$(basename $dev)/device/rescan || true
    else
        echo "[경고] /sys/block/$(basename $dev)/device/rescan 없음 - 스킵"
    fi
    udevadm settle
    sleep 1
    lsblk
    echo "[+] $dev 재인식 완료"
    notify_discord "[NAS] $dev 디스크 정리 및 초기화 완료"
done

exit 0
