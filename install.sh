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
    umount -lf $dev || true
    MNTS=$(lsblk -no MOUNTPOINT $dev | grep -v '^$' || true)
    for mnt in $MNTS; do
        umount -lf "$mnt" || true
    done
    dmsetup remove $(basename $(lsblk -no NAME $dev | tail -1)) || true
    wipefs -a $dev || true
    echo "[+] $dev 정리 완료"
    sleep 1
done

### 디스크 강제 초기화 안내
echo "[경고] $DISK1, $DISK2의 모든 데이터가 삭제됩니다. 5초 후 진행합니다. Ctrl+C로 중단 가능."
sleep 5

### LUKS 포맷 강제 진행 (비밀번호 자동 입력)
echo "초기화중..."
echo "$ADMIN_PASS" | cryptsetup luksFormat $DISK1 --batch-mode --type luks2 --cipher aes-xts-plain64 --key-size 512 --iter-time 5000 --force-password --key-file=-
echo "$ADMIN_PASS" | cryptsetup luksOpen $DISK1 hdd1_crypt --key-file=-
echo "초기화 성공"

echo "초기화중.."
echo "$ADMIN_PASS" | cryptsetup luksFormat $DISK2 --batch-mode --type luks2 --cipher aes-xts-plain64 --key-size 512 --iter-time 5000 --force-password --key-file=-
echo "$ADMIN_PASS" | cryptsetup luksOpen $DISK2 hdd2_crypt --key-file=-
echo "초기화 성공"

mkfs.ext4 /dev/mapper/hdd1_crypt
mkfs.ext4 /dev/mapper/hdd2_crypt
mkdir -p $MOUNT_PATH/hdd1 $MOUNT_PATH/hdd2
mount /dev/mapper/hdd1_crypt $MOUNT_PATH/hdd1
mount /dev/mapper/hdd2_crypt $MOUNT_PATH/hdd2
mkdir -p $MERGE_PATH
mergerfs -o nonempty "$MOUNT_PATH/hdd1:$MOUNT_PATH/hdd2" $MERGE_PATH

### 쿼터 설정 준비
quotaoff $MOUNT_PATH/hdd1 || true
quotaoff $MOUNT_PATH/hdd2 || true
quotacheck -cumf $MOUNT_PATH/hdd1
quotacheck -cumf $MOUNT_PATH/hdd2
quotaon $MOUNT_PATH/hdd1
quotaon $MOUNT_PATH/hdd2

### 사용자 폴더 구성
mkdir -p $MERGE_PATH/{shared,users}
for user in "${USER_LIST[@]}"; do
    useradd -m $user || true
    mkdir -p $MERGE_PATH/users/$user
    chown $user:$user $MERGE_PATH/users/$user
    setquota -u $user 209715200 209715200 0 0 $MOUNT_PATH/hdd1
    echo "$user:$user" | chpasswd
    echo "$user 계정 생성됨" | tee -a /var/log/shadownas.log
    notify_discord "[NAS] 사용자 계정 생성됨: $user"
done

### 관리자 계정 구성
useradd -m admin -G sudo || true
echo "admin:$ADMIN_PASS" | chpasswd
notify_discord "[NAS] 관리자 계정 생성 완료"

### Samba 설정
cat >> /etc/samba/smb.conf <<EOF
[shared]
   path = $MERGE_PATH/shared
   browseable = yes
   writable = yes
   guest ok = yes

[homes]
   comment = 사용자 홈
   browseable = no
   writable = yes
EOF
systemctl restart smbd
notify_discord "[NAS] Samba 공유 설정 완료"

### WireGuard VPN 설정
mkdir -p /etc/wireguard
cd /etc/wireguard
wg genkey | tee privatekey | wg pubkey > publickey
PRIVATE_KEY=$(cat privatekey)
cat > wg0.conf <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = 51820
SaveConfig = true
EOF
systemctl enable wg-quick@wg0 && systemctl start wg-quick@wg0
notify_discord "[NAS] VPN 설정 완료 (포트 51820)"

### 보안 모듈 설정
systemctl enable smartd && systemctl start smartd
rkhunter --update
rkhunter --propupd
notify_discord "[NAS] 스마트 디스크 감시 및 루트킷 헌터 활성화됨"
systemctl enable fail2ban && systemctl start fail2ban
notify_discord "[NAS] Fail2Ban 활성화 완료"

### 상태 모니터링 크론잡 설정
cat > /etc/cron.d/shadownas_monitor <<EOF
* * * * * root echo "[\$(date)] Disk 사용량: \$(df -h $MERGE_PATH | tail -1)" >> /var/log/shadownas.log
* * * * * root grep -E "Failed|error" /var/log/auth.log | tail -n 5 | while read line; do curl -s -H "Content-Type: application/json" -X POST -d "{\"content\": \"[NAS 보안 경고] \$line\"}" $DISCORD_WEBHOOK; done
EOF
notify_discord "[NAS] 상태 모니터링 및 보안 경고 등록 완료"

### Nextcloud 설치
NEXTCLOUD_DIR=/var/www/html/nextcloud
mkdir -p $NEXTCLOUD_DIR
cd /tmp && curl -LO https://download.nextcloud.com/server/releases/latest.zip
unzip latest.zip -d /var/www/html
chown -R www-data:www-data /var/www/html/nextcloud

cat > /etc/nginx/sites-available/nextcloud <<EOF
server {
    listen 80;
    server_name _;
    root /var/www/html/nextcloud;

    location / {
        index index.php index.html;
        try_files \$uri \$uri/ /index.php;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }

    location ~* \.(?:css|js|woff2?|svg|gif)$ {
        try_files \$uri /index.php\$is_args\$args;
        access_log off;
        expires 6M;
        add_header Cache-Control "public";
    }
}
EOF
ln -s /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud
rm /etc/nginx/sites-enabled/default
systemctl restart nginx
notify_discord "[NAS] Nextcloud 설치 및 웹 서버 설정 완료"

notify_discord "[NAS] 전체 설치 완료! NAS가 정상 작동 중입니다. 접속: http://<NAS_IP>/nextcloud"
echo "[완료] NAS 설치가 끝났습니다. 브라우저에서 http://<NAS_IP>/nextcloud 로 접속하세요."
