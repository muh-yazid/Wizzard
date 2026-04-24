#!/bin/bash

# ==============================
# SAFETY & LOGGING
# ==============================
set -e

LOG_FILE="/root/n8n-wizard.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ==============================
# HELPER FUNCTION
# ==============================
run_step() {
    STEP_NAME="$1"
    shift

    echo ""
    echo "[...] $STEP_NAME"

    if "$@" >/dev/null 2>&1; then
        echo "[OK] $STEP_NAME"
    else
        echo "[ERROR] $STEP_NAME (cek log: $LOG_FILE)"
        exit 1
    fi
}

clear

echo "----------------------------------------"
echo "   n8n Wizard Configuration v1.0"
echo "----------------------------------------"
echo ""

# ==============================
# CONFIRMATION
# ==============================
read -p "Do you want to use the configuration wizard? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
  echo "[INFO] Wizard cancelled."
  exit 0
fi

echo ""

# ==============================
# USER INPUT
# ==============================
read -p "Enter domain name (ex: n8n.domain.com): " DOMAIN
read -p "Enter email address: " EMAIL

echo ""
echo "=== PostgreSQL Configuration ==="

read -p "POSTGRES_USER: " POSTGRES_USER
read -p "POSTGRES_PASSWORD: " POSTGRES_PASSWORD
read -p "POSTGRES_DB: " POSTGRES_DB
read -p "POSTGRES_NON_ROOT_USER: " POSTGRES_NON_ROOT_USER
read -p "POSTGRES_NON_ROOT_PASSWORD: " POSTGRES_NON_ROOT_PASSWORD

echo ""
echo "[INFO] Validating input..."

# ==============================
# VALIDATION
# ==============================
if [[ -z "$POSTGRES_USER" || -z "$POSTGRES_PASSWORD" || -z "$POSTGRES_DB" ]]; then
  echo "[ERROR] PostgreSQL config tidak boleh kosong!"
  exit 1
fi

# ==============================
# AUTO GENERATE TOKEN
# ==============================
RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)

INSTALL_DIR="/opt/n8n"

echo ""
echo "[INFO] Starting installation..."

# ==============================
# 1. PREPARE DIRECTORY
# ==============================
run_step "Preparing directory" mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ==============================
# 2. CLONE REPO
# ==============================
run_step "Cloning n8n repository" git clone https://github.com/n8n-io/n8n-hosting.git . || true

# ==============================
# 3. CREATE ENV
# ==============================
echo "[...] Creating .env configuration"

cat <<EOF > .env
N8N_VERSION=stable

POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB

POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD

RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN
EOF

echo "[OK] .env created"

# ==============================
# 4. START DOCKER
# ==============================
run_step "Starting n8n services" docker compose -f docker-compose/withPostgres/docker-compose.yml up -d

# ==============================
# WAIT FOR CONTAINERS
# ==============================
echo ""
echo "[INFO] Waiting for services..."

for i in {1..30}; do
    sleep 5
    RUNNING=$(docker ps --format '{{.Names}}' | grep -E "n8n|postgres" | wc -l)

    echo "[INFO] Progress: $RUNNING/2 containers running... ($i/30)"

    if [ "$RUNNING" -ge 2 ]; then
        echo "[SUCCESS] All services are running!"
        break
    fi
done

# ==============================
# FINAL OUTPUT
# ==============================
IP=$(hostname -I | awk '{print $1}')

echo ""
echo "======================================"
echo "        INSTALLATION COMPLETE"
echo "======================================"
echo ""

echo "[ACCESS]"
echo "Domain : http://$DOMAIN"
echo "IP     : http://$IP:5678"
echo ""

echo "[DATABASE]"
echo "POSTGRES_USER=$POSTGRES_USER"
echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
echo "POSTGRES_DB=$POSTGRES_DB"
echo ""

echo "[RUNNER TOKEN]"
echo "RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN"
echo ""

echo "[LOG]"
echo "Full log: $LOG_FILE"
echo "Docker logs: docker logs -f n8n"
echo ""
