#!/bin/bash

set -e

LOG_FILE="/var/log/n8n-full-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

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

clear

echo "----------------------------------------"
echo "   N8N INSTALLER + WIZARD"
echo "----------------------------------------"
echo ""

# ==============================
# WIZARD CONFIRM
# ==============================
read -p "Start configuration wizard? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Cancelled." && exit 0

# ==============================
# INSTALL DOCKER
# ==============================
echo "[INFO] Waiting for apt/dpkg lock..."

while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "[WAIT] apt is running... retry in 5s"
    sleep 5
done

while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "[WAIT] apt lists lock... retry in 5s"
    sleep 5
done

echo "[OK] apt is ready"

run_step "[1/6] Download Docker installer" curl -fsSL https://get.docker.com -o get-docker.sh
run_step "[2/6] Install Docker" sh get-docker.sh

echo "[...] Starting Docker service"
systemctl start docker || service docker start || true
sleep 3
echo "[OK] Docker ready"

# ==============================
# INPUT
# ==============================
read -p "Enter domain name (ex: n8n.domain.com): " DOMAIN

echo "=== PostgreSQL ==="

read -p "POSTGRES_USER: " POSTGRES_USER

# 🔐 PASSWORD VALIDATION LOOP
while true; do
    read -s -p "POSTGRES_PASSWORD: " POSTGRES_PASSWORD; echo ""
    read -s -p "Re-enter POSTGRES_PASSWORD: " POSTGRES_PASSWORD_CONFIRM; echo ""

    if [[ "$POSTGRES_PASSWORD" != "$POSTGRES_PASSWORD_CONFIRM" ]]; then
        echo "[ERROR] Password tidak sama, ulangi!"
    elif [[ -z "$POSTGRES_PASSWORD" ]]; then
        echo "[ERROR] Password tidak boleh kosong!"
    else
        break
    fi
done

read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER

# 🔐 NON ROOT PASSWORD VALIDATION
while true; do
    read -s -p "POSTGRES_NON_ROOT_PASSWORD: " POSTGRES_NON_ROOT_PASSWORD; echo ""
    read -s -p "Re-enter POSTGRES_NON_ROOT_PASSWORD: " POSTGRES_NON_ROOT_PASSWORD_CONFIRM; echo ""

    if [[ "$POSTGRES_NON_ROOT_PASSWORD" != "$POSTGRES_NON_ROOT_PASSWORD_CONFIRM" ]]; then
        echo "[ERROR] Password tidak sama, ulangi!"
    elif [[ -z "$POSTGRES_NON_ROOT_PASSWORD" ]]; then
        echo "[ERROR] Password tidak boleh kosong!"
    else
        break
    fi
done

# VALIDATION
if [[ -z "$POSTGRES_USER" || -z "$POSTGRES_DB" ]]; then
    echo "[ERROR] PostgreSQL config wajib diisi!"
    exit 1
fi

# TOKEN
RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)

INSTALL_DIR="/opt/n8n"

echo ""
echo "[INFO] Starting deployment..."

# ==============================
# SETUP DIR
# ==============================
run_step "[3/6] Prepare directory" mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ==============================
# CLONE
# ==============================
run_step "[4/6] Clone repo" git clone https://github.com/n8n-io/n8n-hosting.git . || true

# ==============================
# GET IP
# ==============================
IP=$(hostname -I | awk '{print $1}')

# ==============================
# ENV
# ==============================
echo "[...] Creating .env"

cat <<EOF > .env
N8N_VERSION=stable

POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB

POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD

RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN

FQDN=$IP:
EOF

echo "[OK] .env ready"

# ==============================
# DOCKER RUN
# ==============================
run_step "[5/6] Start containers" docker compose -f docker-compose/withPostgres/docker-compose.yml up -d

# ==============================
# WAIT
# ==============================
echo "[INFO] Waiting services..."

for i in {1..30}; do
    sleep 5
    RUNNING=$(docker ps --format '{{.Names}}' | grep -E "n8n|postgres" | wc -l)
    echo "[INFO] $RUNNING/2 running ($i/30)"

    [[ "$RUNNING" -ge 2 ]] && break
done

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
echo "LOG:"
echo "$LOG_FILE"
