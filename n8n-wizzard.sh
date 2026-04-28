#!/bin/bash

set -e

MAIN_LOG="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$MAIN_LOG") 2>&1

# ==============================
# SPINNER
# ==============================
spinner() {
    local pid=$1
    local msg=$2
    local spin='-\|/'
    local i=0

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[INFO] %s... %s" "$msg" "${spin:$i:1}"
        sleep 0.2
    done

    printf "\r"
}

# ==============================
# RUN BACKGROUND STEP
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

    spinner $PID "$STEP"
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

# ==============================
# WAIT APT LOCK (FIXED)
# ==============================
wait_apt() {
    SP='-\|/'
    i=0

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do

        i=$(( (i+1) %4 ))
        printf "\r[INFO] Waiting apt... %s" "${SP:$i:1}"
        sleep 1
    done

    echo ""
    echo "[OK] apt ready"
}

# ==============================
# HEADER
# ==============================
clear
echo "----------------------------------------"
echo "   N8N WIZARD INSTALLER   "
echo "----------------------------------------"
echo ""

read -p "Start N8N configuration wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# ==============================
# INSTALL DOCKER
# ==============================
wait_apt

run_bg "[1/6] Download Docker" curl -fsSL https://get.docker.com -o get-docker.sh
run_bg "[2/6] Install Docker" sh get-docker.sh
run_bg "[3/6] Start Docker" bash -c "systemctl start docker || service docker start || true"

# ==============================
# INPUT
# ==============================
echo ""
echo ""
read -p "Enter domain: " DOMAIN

echo ""
echo ""
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
echo ""
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

run_bg "[5/6] Clone repo" git clone https://github.com/KnowLedZ/n8n-http.git . || true

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
# START DOCKER (FIX UTAMA)
# ==============================
echo ""
echo "[...] Starting containers"

docker compose up -d >> "$DOCKER_LOG" 2>&1
echo "[OK] Containers created"

# ==============================
# WAIT POSTGRES (REAL PROGRESS)
# ==============================
echo "[INFO] Waiting PostgreSQL..."

for i in {1..60}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
        $(docker ps -a --format '{{.Names}}' | grep postgres | head -n1) \
        2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s (%d/60)" "$STATUS" "$i"

    if [[ "$STATUS" == "healthy" ]]; then
        break
    fi

    sleep 2
done

echo ""
echo "[OK] PostgreSQL ready"

# ==============================
# FINAL ENSURE
# ==============================
docker compose up -d >> "$DOCKER_LOG" 2>&1

# ==============================
# WAIT N8N
# ==============================
echo "[INFO] Waiting n8n..."

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
echo "Docker : $DOCKER_LOG"
