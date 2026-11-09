#!/usr/bin/env bash
#
# setup-vpn.sh — одной командой разворачивает на VPS:
#   1) apt update && upgrade
#   2) Docker (get.docker.com)
#   3) Docker Compose plugin
#   4) папки l2tp/ и pptp/ с готовыми compose.yaml
#   5) поднимает оба контейнера
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

BASE_DIR="${VPN_BASE_DIR:-/opt/vpn}"
VPN_USER="${VPN_USER:-user}"
VPN_IPSEC_PSK="${VPN_IPSEC_PSK:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c20)}"
VPN_PASSWORD="${VPN_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c20)}"
PPTP_PASSWORD="${PPTP_PASSWORD:-$VPN_PASSWORD}"
VPN_DNS_SRV1="${VPN_DNS_SRV1:-8.8.8.8}"
VPN_DNS_SRV2="${VPN_DNS_SRV2:-1.0.0.1}"

echo "==> 1/6: apt update && upgrade"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "==> 2/6: установка Docker"
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
else
    echo "    Docker уже установлен, пропускаю."
fi
systemctl enable --now docker

echo "==> 3/6: проверка Docker Compose"
if docker compose version >/dev/null 2>&1; then
    echo "    Docker Compose plugin уже доступен (docker compose)."
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    echo "    docker-compose уже установлен."
    COMPOSE_CMD="docker-compose"
else
    echo "    Ставлю docker-compose-plugin..."
    apt-get install -y docker-compose-plugin
    COMPOSE_CMD="docker compose"
fi

echo "==> 4/6: создание папок и файлов"
mkdir -p "${BASE_DIR}/l2tp" "${BASE_DIR}/pptp"

# ---- l2tp/compose.yaml ----
cat > "${BASE_DIR}/l2tp/compose.yaml" <<'EOF'
version: "3.8"

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

# ---- l2tp/vpn.env ----
cat > "${BASE_DIR}/l2tp/vpn.env" <<EOF
VPN_IPSEC_PSK=${VPN_IPSEC_PSK}
VPN_USER=${VPN_USER}
VPN_PASSWORD=${VPN_PASSWORD}
VPN_DNS_SRV1=${VPN_DNS_SRV1}
VPN_DNS_SRV2=${VPN_DNS_SRV2}
EOF
chmod 600 "${BASE_DIR}/l2tp/vpn.env"

# ---- pptp/compose.yaml ----
cat > "${BASE_DIR}/pptp/compose.yaml" <<'EOF'
version: "3.8"

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

# ---- pptp/chap-secrets ----
cat > "${BASE_DIR}/pptp/chap-secrets" <<EOF
# client      server    secret         IP addresses
${VPN_USER}          pptpd     ${PPTP_PASSWORD}      *
EOF
chmod 600 "${BASE_DIR}/pptp/chap-secrets"

echo "==> 5/6: запуск l2tp"
(cd "${BASE_DIR}/l2tp" && ${COMPOSE_CMD} up -d)

echo "==> 6/6: запуск pptp"
(cd "${BASE_DIR}/pptp" && ${COMPOSE_CMD} up -d)

echo
echo "================= ГОТОВО ================="
echo "Папки:        ${BASE_DIR}/l2tp  и  ${BASE_DIR}/pptp"
echo "VPN_USER:     ${VPN_USER}"
echo "VPN_IPSEC_PSK:${VPN_IPSEC_PSK}"
echo "VPN_PASSWORD: ${VPN_PASSWORD}"
echo "PPTP_PASSWORD:${PPTP_PASSWORD}"
echo "============================================"
echo "Сохраните эти значения — они сгенерированы один раз и больше нигде не выводятся."
