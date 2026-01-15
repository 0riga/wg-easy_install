#!/usr/bin/env bash

set -euo pipefail

# Проверка запуска от root
if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Запусти скрипт от root (sudo)"
  exit 1
fi

echo "=== Обновление системы ==="
apt-get update && \
DEBIAN_FRONTEND=noninteractive apt-get \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  upgrade -y

echo "=== Установка Docker ==="
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
else
  echo "Docker уже установлен, пропускаем"
fi

echo
echo "=== Определение внешнего IP ==="
AUTO_IP=$(curl -fsSL https://api.ipify.org || true)

if [[ -n "$AUTO_IP" ]]; then
  WG_HOST="$AUTO_IP"
  echo "Используется внешний IP: $WG_HOST"
else
  echo "⚠️ Не удалось определить внешний IP"
  read -rp "Введите WG_HOST (IP или домен): " WG_HOST
fi

while [[ -z "$WG_HOST" ]]; do
  echo "WG_HOST не может быть пустым"
  read -rp "Введите WG_HOST: " WG_HOST
done

echo
read -p "Введите PASSWORD: " PASSWORD
echo
read -p "Повторите PASSWORD: " PASSWORD_CONFIRM
echo

if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
  echo "❌ Пароли не совпадают"
  exit 1
fi

WG_DIR="/opt/wg-easy"
mkdir -p "$WG_DIR"

echo
echo "=== Запуск контейнера wg-easy ==="
docker run -d \
  --name wg-easy \
  -e WG_HOST="$WG_HOST" \
  -e PASSWORD="$PASSWORD" \
  -v "$WG_DIR:/etc/wireguard" \
  -p 51820:51820/udp \
  -p 51821:51821/tcp \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv4.ip_forward=1 \
  --restart unless-stopped \
  weejewel/wg-easy

echo
echo "✅ wg-easy успешно запущен"
echo "🌐 Web-интерфейс: http://$WG_HOST:51821"