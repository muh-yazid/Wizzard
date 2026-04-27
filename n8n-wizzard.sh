#!/bin/bash

set -e

MAIN_LOG="/var/log/n8n-install.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# HELPER
# ==============================
run_bg() {
    STEP="$1"
    shift

    echo ""
    echo "======================================"
    echo "[...] $STEP"
    echo "======================================"

    "$@" >> "$MAIN_LOG" 2>&1 &
    PID=$!

    SP='-\|/'
    i=0

    while kill -0 $PID 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[INFO] %s... %s" "$STEP" "${SP:$i:1}"
        sleep 0.3
    done

    wait $PID
    STATUS=$?

    echo ""

    if [ $STATUS -ne 0 ]; then
        echo "[ERROR] $STEP failed!"
        echo "[INFO] Check log: $MAIN_LOG"
        exit 1
    fi

    echo "[OK] $STEP"
}

wait_apt() {
    echo "[...] Waiting for apt lock..."

    (
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        sleep 1
    done
    ) &

    PID=$!

    SP='-\|/'
    i=0

    while kill -0 $PID 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[INFO] Waiting apt... %s" "${SP:$i:1}"
        sleep 0.3
    done

    echo ""
    echo "[OK] apt ready"
}

# ==============================
# HEADER
# ==============================
clear
echo "----------------------------------------"
echo "   N8N INSTALLER + WIZARD"
echo "----------------------------------------"
echo ""

read -p "Start configuration wizard? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Cancelled." && exit 0

# ==============================
# DOCKER INSTALL
# ==============================
wait_apt

run_bg "[1/6] Download Docker" curl -fsSL https://get.docker.com -o get-docker.sh
run_bg "[2/6] Install Docker" sh get-docker.sh
run_bg "[3/6] Start Docker" bash -c "systemctl start docker || service docker start || true"

# ==============================
# INPUT
# ==============================
read -p "Enter domain: " DOMAIN

echo "=== PostgreSQL ==="

read -p "POSTGRES_USER: " POSTGRES_USER

while true; do
    read -s -p "POSTGRES_PASSWORD: " P1; echo ""
    read -s -p "Re-enter POSTGRES_PASSWORD: " P2; echo ""

    [[ "$P1" != "$P2" ]] && echo "[ERROR] Not match!" && continue
    [[ -z "$P1" ]] && echo "[ERROR] Empty!" && continue
    POSTGRES_PASSWORD="$P1"
    break
done

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " P1; echo ""
    read -s -p "Re-enter POSTGRES_NON_ROOT_PASSWORD: " P2; echo ""

    [[ "$P1" != "$P2" ]] && echo "[ERROR] Not match!" && continue
    [[ -z "$P1" ]] && echo "[ERROR] Empty!" && continue
    POSTGRES_NON_ROOT_PASSWORD="$P1"
    break
done

[[ -z "$POSTGRES_USER" || -z "$POSTGRES_DB" ]] && echo "[ERROR] Required field kosong!" && exit 1

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)
INSTALL_DIR="/opt/n8n"

# ==============================
# PREPARE
# ==============================
run_bg "[4/6] Prepare directory" mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

run_bg "[5/6] Clone repo" git clone https://github.com/muh-yazid/n8n-http.git . || true

# ==============================
# ENV
# ==============================
IP=$(hostname -I | awk '{print $1}')

echo "[...] Creating .env"

cat <<EOF > .env
N8N_VERSION=stable

POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB

POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD

RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN

FQDN=$IP
EOF

echo "[OK] .env ready"

# ==============================
# DOCKER START
# ==============================
echo "[...] Starting containers"
docker compose up -d >> "$MAIN_LOG" 2>&1 &

PID=$!
SP='-\|/'
i=0

while kill -0 $PID 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\r[INFO] Deploying containers... %s" "${SP:$i:1}"
    sleep 0.3
done

wait $PID
echo ""
echo "[OK] Containers started"

# ==============================
# WAIT POSTGRES
# ==============================
echo "[INFO] Waiting PostgreSQL..."

for i in {1..30}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' $(docker ps -a --format '{{.Names}}' | grep postgres | head -n1) 2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %s (%d/30)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 2
done

echo ""
echo "[OK] PostgreSQL ready"

# ==============================
# ENSURE FINAL
# ==============================
docker compose up -d >> "$MAIN_LOG" 2>&1

# ==============================
# DONE
# ==============================
echo ""
echo "======================================"
echo "        INSTALLATION COMPLETE"
echo "======================================"

echo "URL:"
echo "Domain : http://$DOMAIN"
echo "IP     : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "PATH:"
echo "/opt/n8n"

echo ""
echo "LOG:"
echo "Main   : $MAIN_LOG"
