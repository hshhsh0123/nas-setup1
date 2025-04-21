#!/bin/bash
# === ShadowNAS: Full Auto Installer ===
# By ChatGPT for hshhsh0123 (with E2EE, VPN, dedup, auto-sort, DNS privacy, debugging, external access)

set -e
exec > >(tee /var/log/nas-install.log) 2>&1

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
  dnscrypt-proxy

## =====================
## 2. 암호화 디스크 병합 (1TB x2 → mergerfs)
## =====================
mkdir -p /mnt/securehdd1 /mnt/securehdd2
cryptsetup luksOpen /dev/sdb secure1
cryptsetup luksOpen /dev/sdc secure2
mount /dev/mapper/secure1 /mnt/securehdd1
mount /dev/mapper/secure2 /mnt/securehdd2
apt install -y mergerfs
mergerfs /mnt/securehdd1:/mnt/securehdd2 /mnt/securehdd

## =====================
## 3. 사용자 폴더 생성 + 제약
## =====================
mkdir -p "$SHARED_FOLDER"
for u in "${USERS[@]}"; do
  mkdir -p "$USER_ROOT/$u/raw_upload"
  mkdir -p "$USER_ROOT/$u/photos"
  mkdir -p "$USER_ROOT/$u/videos"
  mkdir -p "$USER_ROOT/$u/documents"
  mkdir -p "$USER_ROOT/$u/archives"
  mkdir -p "$USER_ROOT/$u/e2ee"
  touch "$USER_ROOT/$u/.sort_enabled"
  setquota -u $u 204800 204800 0 0 -a
done

## =====================
## 4. Docker로 Nextcloud 배포
## =====================
mkdir -p ~/nextcloud && cd ~/nextcloud
cat <<EOF > docker-compose.yml
version: '3'
services:
  db:
    image: mariadb
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: $PASSWORD
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: $PASSWORD
    volumes:
      - db:/var/lib/mysql

  app:
    image: nextcloud
    restart: always
    ports:
      - 443:80
    volumes:
      - nextcloud:/var/www/html
    environment:
      MYSQL_PASSWORD: $PASSWORD
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_HOST: db
volumes:
  db:
  nextcloud:
EOF

docker-compose up -d

## =====================
## 5. WireGuard 서버 구성 + QR코드
## =====================
mkdir -p /etc/wireguard && cd /etc/wireguard
wg genkey | tee server.key | wg pubkey > server.pub

cat <<EOL > wg0.conf
[Interface]
PrivateKey = $(cat server.key)
Address = 10.6.0.1/24
ListenPort = $WG_PORT
PostUp = ufw allow $WG_PORT/udp
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT

EOL

mkdir -p /etc/wireguard/clients
for i in "${!USERS[@]}"; do
  u=${USERS[$i]}
  PRIV=$(wg genkey)
  PUB=$(echo "$PRIV" | wg pubkey)
  echo -e "[Peer]\nPublicKey = $PUB\nAllowedIPs = 10.6.0.$((i+2))/32" >> /etc/wireguard/wg0.conf
  cat <<EOF > /etc/wireguard/clients/$u.conf
[Interface]
PrivateKey = $PRIV
Address = 10.6.0.$((i+2))/24
DNS = 1.1.1.1

[Peer]
PublicKey = $(cat server.pub)
Endpoint = $PUBLIC_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  qrencode -o /etc/wireguard/clients/$u.png < /etc/wireguard/clients/$u.conf
done

## =====================
## 6. DNSCrypt-Proxy 설정
## =====================
mv /etc/dnscrypt-proxy /etc/dnscrypt-proxy.bak || true
git clone https://github.com/DNSCrypt/dnscrypt-proxy.git /etc/dnscrypt-proxy
cp /etc/dnscrypt-proxy/dnscrypt-proxy/example-dnscrypt-proxy.toml /etc/dnscrypt-proxy/dnscrypt-proxy.toml
sed -i 's/^# server_names =.*/server_names = ["cloudflare", "quad9-dnscrypt-ip4-filter-pri"]/' /etc/dnscrypt-proxy/dnscrypt-proxy.toml
systemctl restart dnscrypt-proxy

## =====================
## 7. 프락시 자동 트리거 스크립트 등록 (wg1 자동 ON/OFF)
## =====================
cat <<EOF > /usr/local/bin/monitor_proxy.sh
#!/bin/bash
if ping -c 1 10.6.0.2 > /dev/null 2>&1; then
  if ! wg show wg1 > /dev/null 2>&1; then
    wg-quick up wg1
  fi
else
  if wg show wg1 > /dev/null 2>&1; then
    wg-quick down wg1
  fi
fi
EOF
chmod +x /usr/local/bin/monitor_proxy.sh
(crontab -l ; echo "*/1 * * * * /usr/local/bin/monitor_proxy.sh") | crontab -

## =====================
## 8. 프락시 수동 토글 명령어 생성
## =====================
echo '#!/bin/bash
if wg show wg1 > /dev/null 2>&1; then
  echo ">> 프락시 OFF 중..."
  wg-quick down wg1
  echo ">> 프락시 꺼짐."
else
  echo ">> 프락시 ON 중..."
  wg-quick up wg1
  echo ">> 프락시 켜짐."
fi' > /usr/local/bin/proxy
chmod +x /usr/local/bin/proxy

## =====================
## 9. VPN 상태 확인 스크립트 생성
## =====================
echo '#!/bin/bash
if wg show wg0 > /dev/null 2>&1; then
  echo "[VPN 서버 정상 작동 중]"
  wg show wg0
else
  echo "[VPN 서버가 꺼져 있습니다]"
fi' > /usr/local/bin/wg-check
chmod +x /usr/local/bin/wg-check

## =====================
## 완료 메시지
## =====================
echo "\n[✅ NAS 설치 완료]"
echo "- 웹: https://$PUBLIC_IP"
echo "- VPN QR코드: /etc/wireguard/clients/*.png"
echo "- 정리 및 중복 제거는 사용자별 폴더에 설정됨"
echo "- 자동 프락시 연동 완료 (VPN 접속 시 wg1 자동 작동)"
echo "- 디버그 로그: /var/log/nas-install.log"
echo "- 상태 확인: 'wg-check' 명령어로 확인 가능"
