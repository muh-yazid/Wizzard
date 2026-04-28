#!/bin/bash

set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# WAIT APT
# ==============================
echo "[STEP 1/6] Waiting apt lock..."

while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    printf "\r[INFO] Waiting apt... "
    sleep 1
done

echo "[OK] apt ready"

# ==============================
# INSTALL DOCKER
# ==============================
echo "[STEP 2/6] Install Docker"

curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

systemctl start docker || service docker start || true
sleep 3

echo "[OK] Docker ready"

# ==============================
# INPUT
# ==============================
read -p "Domain: " DOMAIN
read -p "POSTGRES_USER: " POSTGRES_USER

while true; do
    read -s -p "POSTGRES_PASSWORD: " P1; echo ""
    read -s -p "Re-enter: " P2; echo ""

    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done

POSTGRES_PASSWORD=$P1

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " P1; echo ""
    read -s -p "Re-enter: " P2; echo ""

    [[ "$P1" == "$P2" && -n "$P1" ]] && break
    echo "[ERROR] Password mismatch"
done

POSTGRES_NON_ROOT_PASSWORD=$P1

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)

# ==============================
# SETUP
# ==============================
echo "[STEP 3/6] Prepare directory"

INSTALL_DIR="/opt/n8n"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

git clone https://github.com/KnowLedZ/n8n-http.git . || true

IP=$(hostname -I | awk '{print $1}')

cat <<EOF > .env
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD
RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN
FQDN=$IP
EOF

echo "[OK] Config ready"

# ==============================
# START CONTAINER
# ==============================
echo "[STEP 4/6] Starting containers..."

docker compose up -d >> "$DOCKER_LOG" 2>&1

echo "[OK] Containers created"

# ==============================
# WAIT POSTGRES
# ==============================
echo "[STEP 5/6] Waiting PostgreSQL..."

for i in {1..60}; do
    NAME=$(docker ps -a --format '{{.Names}}' | grep postgres | head -n1)

    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %s (%d/60)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 2
done

echo ""
echo "[OK] PostgreSQL ready"

# ==============================
# WAIT N8N
# ==============================
echo "[STEP 6/6] Waiting n8n..."

for i in {1..60}; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n || true)

    printf "\r[INFO] n8n: %d (%d/60)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 1 ]] && break
    sleep 2
done

echo ""
echo "[OK] n8n running"

# ==============================
# DONE
# ==============================
echo ""
echo "======================================"
echo "        INSTALLATION COMPLETE"
echo "======================================"

echo "Domain : http://$DOMAIN"
echo "IP     : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
