#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/n8n-install.log"
DOCKER_LOG="/var/log/n8n-docker.log"

exec > >(tee -a "$LOG_FILE") 2>&1

# ==============================
# SPINNER
# ==============================
spinner() {
    local pid=$1
    local spin='-\|/'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[%c] Working..." "${spin:$i:1}"
        sleep 0.2
    done
    printf "\r"
}

# ==============================
# SAFE BACKGROUND RUNNER
# ==============================
run_step_bg() {
    DESC="$1"
    shift

    echo ""
    echo "======================================"
    echo "[...] $DESC"
    echo "======================================"

    "$@" >> "$LOG_FILE" 2>&1 &
    PID=$!

    spinner $PID

    if wait $PID; then
        echo "[OK] $DESC"
    else
        echo "[ERROR] $DESC gagal"
        echo "[INFO] Check log: $LOG_FILE"
        exit 1
    fi
}

# ==============================
# FOREGROUND STEP (WAJIB untuk critical)
# ==============================
run_step_fg() {
    DESC="$1"
    shift

    echo ""
    echo "======================================"
    echo "[...] $DESC"
    echo "======================================"

    if "$@" | tee -a "$LOG_FILE"; then
        echo "[OK] $DESC"
    else
        echo "[ERROR] $DESC gagal"
        echo "[INFO] Check log: $LOG_FILE"
        exit 1
    fi
}

clear
echo "----------------------------------------"
echo "   N8N INSTALLER + WIZARD"
echo "----------------------------------------"

# ==============================
# CONFIRM
# ==============================
read -p "Start wizard? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && exit 0

# ==============================
# WAIT APT LOCK (PAKAI SPINNER)
# ==============================
echo "[INFO] Waiting apt lock..."

(
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        sleep 2
    done
) &

spinner $!
wait $!

echo "[OK] apt ready"

# ==============================
# INSTALL DOCKER (CRITICAL → FG)
# ==============================
run_step_bg "Download Docker" curl -fsSL https://get.docker.com -o get-docker.sh

run_step_fg "Install Docker" sh get-docker.sh

echo "[INFO] Starting Docker..."
systemctl start docker || service docker start || true
sleep 2
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

INSTALL_DIR="/opt/n8n"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ==============================
# CLONE REPO
# ==============================
run_step_bg "Clone repo" git clone https://github.com/KnowLedZ/n8n-http.git . || true

IP=$(hostname -I | awk '{print $1}')

# ==============================
# ENV
# ==============================
echo "[INFO] Creating .env"

cat <<EOF > .env
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD

FQDN=$IP

RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN
EOF

echo "[OK] .env ready"

# ==============================
# START DOCKER (CRITICAL → FG)
# ==============================
echo ""
echo "[INFO] Starting containers..."

docker compose up -d | tee -a "$DOCKER_LOG"

# ==============================
# WAIT POSTGRES
# ==============================
echo "[INFO] Waiting PostgreSQL..."

for i in {1..40}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' n8n-postgres-1 2>/dev/null || echo "starting")

    printf "\r[INFO] Postgres: %-10s (%d/40)" "$STATUS" "$i"

    [[ "$STATUS" == "healthy" ]] && break
    sleep 3
done

echo ""

# ==============================
# ENSURE RUNNING
# ==============================
docker compose up -d >> "$DOCKER_LOG" 2>&1

# ==============================
# WAIT N8N
# ==============================
echo "[INFO] Waiting n8n..."

for i in {1..40}; do
    RUNNING=$(docker ps --format '{{.Names}}' | grep -c n8n-n8n-1 || true)

    printf "\r[INFO] n8n: %d (%d/40)" "$RUNNING" "$i"

    [[ "$RUNNING" -ge 1 ]] && break
    sleep 3
done

echo ""

# ==============================
# CLEANUP (PINDAH KE AKHIR)
# ==============================
echo "[INFO] Cleaning up..."
rm -f /root/get-docker.sh

echo "[OK] Cleanup done"

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
echo "$INSTALL_DIR"

echo ""
echo "LOG:"
echo "$LOG_FILE"
echo "$DOCKER_LOG"
