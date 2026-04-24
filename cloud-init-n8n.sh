#!/bin/bash

set -e

LOG_FILE="/var/log/bootstrap-n8n.log"
exec > >(tee -a "$LOG_FILE") 2>&1

URL_SCRIPT="https://raw.githubusercontent.com/muh-yazid/Wizzard/main/n8n-wizzard.sh"

echo "======================================"
echo "     N8N BOOTSTRAP INITIALIZER"
echo "======================================"

echo "[...] Downloading main installer..."

curl -L -f "$URL_SCRIPT" -o /root/n8n-installer.sh

chmod +x /root/n8n-installer.sh

echo "[OK] Installer downloaded"

echo ""
echo "[...] Running installer..."
echo ""

bash /root/n8n-installer.sh

echo "Wizzar : $LOG_FILE"
