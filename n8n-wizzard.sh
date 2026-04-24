#!/bin/bash

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
# SETUP DIRECTORY
# ==============================
echo "[2/5] Preparing directory..."
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# ==============================
# CLONE REPO
# ==============================
echo "[3/5] Cloning n8n hosting repository..."
git clone https://github.com/n8n-io/n8n-hosting.git . || true

# ==============================
# CREATE ENV FILE
# ==============================
echo "[4/5] Creating .env configuration..."

cat <<EOF > .env
N8N_VERSION=stable

POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB

POSTGRES_NON_ROOT_USER=$POSTGRES_NON_ROOT_USER
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD

RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN
EOF

# ==============================
# RUN DOCKER
# ==============================
echo "[5/5] Starting n8n services..."
docker compose -f docker-compose/withPostgres/docker-compose.yml up -d

echo ""
echo "[INFO] Waiting for services..."

for i in {1..30}; do
    sleep 10
    RUNNING=$(docker ps --format '{{.Names}}' | grep -E "n8n|postgres" | wc -l)

    echo "[INFO] Progress: $RUNNING containers running... ($i/30)"

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

echo "[INFO] Check logs if needed:"
echo "docker logs -f n8n"
echo ""
