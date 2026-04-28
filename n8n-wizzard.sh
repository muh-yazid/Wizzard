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
# WAIT APT LOCK
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
echo "   N8N WIZARD INSTALLER"
echo "----------------------------------------"

read -p "Start N8N configuration wizard? (Y/n): " CONFIRM
CONFIRM=${CONFIRM:-y}

[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

# ==============================
# INSTALL DOCKER
# ==============================
wait_apt

run_bg "Download Docker" curl -fsSL https://get.docker.com -o get-docker.sh
run_bg "Install Docker" sh get-docker.sh
run_bg "Start Docker" bash -c "systemctl start docker || service docker start || true"

# ==============================
# INPUT
# ==============================
echo ""
read -p "Domain: " DOMAIN

echo "=== PostgreSQL ==="
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
INSTALL_DIR="/opt/n8n"

# ==============================
# PREPARE
# ==============================
run_bg "Prepare directory" mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

run_bg "Clone repo" git clone https://github.com/KnowLedZ/n8n-http.git . || true

# ==============================
# ENV
# ==============================
IP=$(hostname -I | awk '{print $1}')

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
run_bg "Starting containers" docker compose up -d

# ==============================
# WAIT POSTGRES
# ==============================
echo "[INFO] Waiting PostgreSQL..."

for i in {1..60}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
        $(docker ps -a --format '{{.Names}}' | grep postgres | head -n1) \
        2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s (%d/60)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 2
done

echo ""
echo "[OK] PostgreSQL ready"

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

echo "Domain : http://$DOMAIN"
echo "IP     : http://$IP:5678"

echo ""
echo "TOKEN:"
echo "$RUNNERS_AUTH_TOKEN"

echo ""
echo "LOG:"
echo "$MAIN_LOG"
echo "$DOCKER_LOG"
