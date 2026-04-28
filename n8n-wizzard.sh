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
# RUN BG
# ==============================
run_bg() {
    STEP="$1"
    shift

    echo ""
    echo "======================================"
    echo "$STEP"
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
# WAIT APT
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
# 1. INSTALL DOCKER
# ==============================
wait_apt

run_bg "[1/10] Download Docker" curl -fsSL https://get.docker.com -o get-docker.sh
run_bg "[2/10] Install Docker" sh get-docker.sh
run_bg "[3/10] Start Docker" bash -c "systemctl start docker || service docker start || true"

# ==============================
# 2. INPUT
# ==============================
echo ""
read -p "[4/10] Domain: " DOMAIN

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

[[ -z "$POSTGRES_USER" || -z "$POSTGRES_DB" ]] && echo "[ERROR] Required field kosong!" && exit 1

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)
INSTALL_DIR="/opt/n8n"

# ==============================
# 3. PREPARE
# ==============================
run_bg "[5/10] Prepare directory" mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

run_bg "[6/10] Clone repo" git clone https://github.com/KnowLedZ/n8n-http.git . || true

# ==============================
# 4. ENV
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
# 5. START DOCKER
# ==============================
run_bg "[7/10] Starting containers" docker compose up -d

# ==============================
# 6. WAIT POSTGRES (FIXED)
# ==============================
echo "[8/10] Waiting PostgreSQL..."

POSTGRES_CONTAINER=$(docker ps -a --format '{{.Names}}' | grep postgres | head -n1)

for i in {1..60}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$POSTGRES_CONTAINER" 2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s (%d/60)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 2
done

echo ""
echo "[OK] PostgreSQL ready"

# ==============================
# 7. WAIT N8N PORT (FIX UTAMA)
# ==============================
echo "[9/10] Waiting n8n (port 5678)..."

for i in {1..60}; do
    if ss -lnt | grep -q ":5678"; then
        echo "[OK] n8n port ready"
        break
    fi

    printf "\r[INFO] Waiting n8n port... (%d/60)" "$i"
    sleep 2
done

echo ""

# ==============================
# 8. VERIFY CONTAINER
# ==============================
RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n || true)

if [ "$RUNNING" -lt 1 ]; then
    echo "[ERROR] n8n container tidak jalan!"
    echo "[INFO] Cek: docker ps -a"
    exit 1
fi

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
echo "PATH:"
echo "/opt/n8n"

echo ""
echo "LOG:"
echo "Main   : $MAIN_LOG"
echo "Docker : $DOCKER_LOG"
