#!/bin/bash

set -e

LOG_FILE="/var/log/n8n-full-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ==============================
# HELPER
# ==============================
run_step() {
    STEP_NAME="$1"
    shift

    echo ""
    echo "======================================"
    echo "[...] $STEP_NAME"
    echo "======================================"

    if "$@"; then
        echo "[OK] $STEP_NAME"
    else
        echo "[ERROR] $STEP_NAME"
        echo "[INFO] Check log: $LOG_FILE"
        exit 1
    fi
}

spinner_wait() {
    PID=$!
    SP='-\|/'
    i=0
    while kill -0 $PID 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[INFO] Processing... %s" "${SP:$i:1}"
        sleep 0.3
    done
    wait $PID
    echo ""
}

# ==============================
# HEADER
# ==============================
clear
echo "----------------------------------------"
echo "   N8N INSTALLER + WIZARD"
echo "----------------------------------------"
echo ""

# ==============================
# CONFIRM
# ==============================
read -p "Start configuration wizard? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Cancelled." && exit 0

# ==============================
# INSTALL DOCKER
# ==============================
echo "[INFO] Waiting for apt lock..."

while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "[WAIT] apt running..."
    sleep 5
done

echo "[OK] apt ready"

run_step "[1/6] Download Docker" curl -fsSL https://get.docker.com -o get-docker.sh
run_step "[2/6] Install Docker" sh get-docker.sh

echo "[...] Starting Docker"
systemctl start docker || service docker start || true
sleep 3
echo "[OK] Docker ready"

# ==============================
# INPUT
# ==============================
read -p "Enter domain: " DOMAIN

echo "=== PostgreSQL ==="

read -p "POSTGRES_USER: " POSTGRES_USER

while true; do
    read -s -p "POSTGRES_PASSWORD: " POSTGRES_PASSWORD; echo ""
    read -s -p "Re-enter POSTGRES_PASSWORD: " CONFIRM_PASS; echo ""

    [[ "$POSTGRES_PASSWORD" != "$CONFIRM_PASS" ]] && echo "[ERROR] Not match!" && continue
    [[ -z "$POSTGRES_PASSWORD" ]] && echo "[ERROR] Empty!" && continue
    break
done

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " POSTGRES_NON_ROOT_PASSWORD; echo ""
    read -s -p "Re-enter POSTGRES_NON_ROOT_PASSWORD: " CONFIRM_PASS; echo ""

    [[ "$POSTGRES_NON_ROOT_PASSWORD" != "$CONFIRM_PASS" ]] && echo "[ERROR] Not match!" && continue
    [[ -z "$POSTGRES_NON_ROOT_PASSWORD" ]] && echo "[ERROR] Empty!" && continue
    break
done

# VALIDATION
[[ -z "$POSTGRES_USER" || -z "$POSTGRES_DB" ]] && echo "[ERROR] Required field kosong!" && exit 1

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)
INSTALL_DIR="/opt/n8n"

# ==============================
# PREPARE
# ==============================
run_step "[3/6] Prepare directory" mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

run_step "[4/6] Clone repo" git clone https://github.com/muh-yazid/n8n-http.git . || true

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

N8N_SECURE_COOKIE=false
N8N_HOST=$IP:5678
WEBHOOK_URL=http://$IP:5678/
EOF

echo "[OK] .env ready"

# ==============================
# DOCKER START (CLEAN MODE)
# ==============================
echo ""
echo "[...] Starting containers (background)"

docker compose up -d > "$LOG_FILE.docker" 2>&1 &
spinner_wait

echo "[OK] Containers triggered"

# ==============================
# WAIT POSTGRES
# ==============================
echo "[INFO] Waiting PostgreSQL..."

for i in {1..30}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' $(docker ps -a --format '{{.Names}}' | grep postgres | head -n1) 2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %s (%d/30)" "$STATUS" "$i"

    if [[ "$STATUS" == "healthy" ]]; then
        echo ""
        echo "[OK] PostgreSQL ready"
        break
    fi

    sleep 2
done

# ==============================
# ENSURE SERVICES
# ==============================
echo "[...] Ensuring containers up"
docker compose up -d >> "$LOG_FILE" 2>&1

# ==============================
# WAIT FINAL
# ==============================
echo "[INFO] Checking services..."

for i in {1..30}; do
    sleep 3
    RUNNING=$(docker ps --format '{{.Names}}' | grep -E "n8n|postgres" | wc -l)
    printf "\r[INFO] Running: %d/2 (%d/30)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 2 ]] && break
done

echo ""

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
echo "$LOG_FILE"
echo "$LOG_FILE.docker"
