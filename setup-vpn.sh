#!/usr/bin/env bash
#
# setup-vpn.sh — одной командой разворачивает на VPS:
#   1) apt update && upgrade
#   2) Docker (get.docker.com)
#   3) docker-compose (ставится всегда, независимо от того, что уже есть)
#   4) настройка registry-mirrors на случай недоступности docker.io
#   5) папки /root/l2tp и /root/pptp с готовыми compose.yaml
#   6) поднимает оба контейнера
#
# ВАЖНО ПРО ПАРОЛИ:
# Ничего не захардкожено. Пароли берутся из переменных окружения,
# если они заданы, иначе генерируются случайно и выводятся в конце.
# Это позволяет безопасно держать сам скрипт в публичном репозитории.
#
# Примеры запуска:
#
#   # со своими значениями:
#   VPN_IPSEC_PSK='моёсложноезначение' \
#   VPN_USER='user' \
#   VPN_PASSWORD='моёсложноезначение' \
#   PPTP_PASSWORD='моёсложноезначение' \
#   bash setup-vpn.sh
#
#   # либо просто:
#   bash setup-vpn.sh
#   (скрипт сам сгенерирует пароли и покажет их в конце)
#
set -euo pipefail

VPN_USER="${VPN_USER:-user}"
VPN_IPSEC_PSK="${VPN_IPSEC_PSK:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c20)}"
VPN_PASSWORD="${VPN_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c20)}"
PPTP_PASSWORD="${PPTP_PASSWORD:-$VPN_PASSWORD}"
VPN_DNS_SRV1="${VPN_DNS_SRV1:-8.8.8.8}"
VPN_DNS_SRV2="${VPN_DNS_SRV2:-1.0.0.1}"

echo "==> 0/6: определение публичного IP"
VPN_PUBLIC_IP="${VPN_PUBLIC_IP:-$(curl -4 -fsSL ifconfig.me)}"
echo "    Публичный IP: ${VPN_PUBLIC_IP}"

echo "==> 1/6: apt update && upgrade"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

echo "==> 2/6: установка Docker"
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
else
    echo "    Docker уже установлен, пропускаю."
fi
systemctl enable --now docker

echo "==> 3/6: установка docker-compose (всегда, вне зависимости от того, что уже стоит)"
apt-get install -y docker-compose-plugin
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    # fallback на классический standalone-бинарник, если plugin по какой-то причине не встал
    if ! command -v docker-compose >/dev/null 2>&1; then
        curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    COMPOSE_CMD="docker-compose"
fi
echo "    Будет использоваться: ${COMPOSE_CMD}"

echo "==> 4/6: настройка registry-mirrors (на случай недоступности docker.io)"
# Если VPS не может достучаться до auth.docker.io напрямую (таймауты),
# Docker будет пробовать эти зеркала по очереди перед оригинальным registry.
if [ -f /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
    echo "    Существующий /etc/docker/daemon.json сохранён в .bak — если там были другие настройки, слейте их вручную."
fi
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://mirror.gcr.io",
    "https://docker.m.daocloud.io",
    "https://dockerhub.icu",
    "https://docker.1panel.live"
  ]
}
EOF
systemctl restart docker
sleep 2

echo "==> 5/6: создание папок и файлов в /root"
mkdir -p /root/l2tp /root/pptp

# ---- /root/l2tp/compose.yaml ----
cat > /root/l2tp/compose.yaml <<'EOF'
services:
  ipsec-vpn-server:
    image: hwdsl2/ipsec-vpn-server
    container_name: ipsec-vpn-server
    env_file:
      - ./vpn.env
    restart: always
    privileged: true
    volumes:
      - /lib/modules:/lib/modules:ro
    ports:
      - "500:500/udp"
      - "4500:4500/udp"
EOF

# ---- /root/l2tp/vpn.env ----
cat > /root/l2tp/vpn.env <<EOF
VPN_PUBLIC_IP=${VPN_PUBLIC_IP}
VPN_IPSEC_PSK=${VPN_IPSEC_PSK}
VPN_USER=${VPN_USER}
VPN_PASSWORD=${VPN_PASSWORD}
VPN_DNS_SRV1=${VPN_DNS_SRV1}
VPN_DNS_SRV2=${VPN_DNS_SRV2}
EOF
chmod 600 /root/l2tp/vpn.env

# ---- /root/pptp/compose.yaml ----
cat > /root/pptp/compose.yaml <<'EOF'
services:
  vpn-pptp:
    image: mobtitude/vpn-pptp
    container_name: vpn-pptp
    restart: unless-stopped
    privileged: true
    # ports:
    #   - "1723:1723/tcp"
    volumes:
      - ./chap-secrets:/etc/ppp/chap-secrets
    # Если после поднятия контейнера клиенты не могут подключиться
    # (проблема с GRE-пакетами на некоторых версиях Docker/ядра),
    # раскомментируйте строку ниже и уберите "ports" выше —
    # это переводит контейнер в сетевой стек хоста:
    network_mode: host
EOF

# ---- /root/pptp/chap-secrets ----
cat > /root/pptp/chap-secrets <<EOF
# client      server    secret         IP addresses
${VPN_USER}          pptpd     ${PPTP_PASSWORD}      *
EOF
chmod 600 /root/pptp/chap-secrets

echo "==> 6/6: запуск контейнеров"
(cd /root/l2tp && ${COMPOSE_CMD} up -d)
(cd /root/pptp && ${COMPOSE_CMD} up -d)

echo
echo "================= ГОТОВО ================="
echo "Папки:        /root/l2tp  и  /root/pptp"
echo "Публичный IP: ${VPN_PUBLIC_IP}"
echo "VPN_USER:     ${VPN_USER}"
echo "VPN_IPSEC_PSK:${VPN_IPSEC_PSK}"
echo "VPN_PASSWORD: ${VPN_PASSWORD}"
echo "PPTP_PASSWORD:${PPTP_PASSWORD}"
echo "============================================"
echo "Сохраните эти значения — они сгенерированы один раз и больше нигде не выводятся."
