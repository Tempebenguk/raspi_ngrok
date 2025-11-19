#!/bin/bash
set -e

echo "=========================================="
echo "     NGROK V3 + FIREBASE AUTO INSTALLER   "
echo "=========================================="
echo

echo "[0/9] Mengumpulkan input user..."

# USER INPUT
read -p "Masukkan ID_DEVICE_PI: " ID_DEVICE_PI
read -p "Masukkan NGROK_AUTHTOKEN: " NGROK_AUTHTOKEN
read -p "Masukkan FIREBASE_URL (contoh: https://xxx.firebaseio.com/ngrok.json): " FIREBASE_URL
read -p "Masukkan USERNAME untuk service (default: pi): " SERVICE_USER
SERVICE_USER=${SERVICE_USER:-pi}

USER_HOME="/home/$SERVICE_USER"
ENV_FILE="$USER_HOME/.env"
PYTHON_SCRIPT_PATH="$USER_HOME/ngrok_reporter.py"
NGROK_RUNNER="$USER_HOME/ngrok_runner.sh"
SERVICE_PATH="/etc/systemd/system/ngrok-ssh.service"

echo
echo "[1/9] Mendeteksi arsitektur sistem..."

ARCH=$(uname -m)

if [[ "$ARCH" == "armv7l" ]]; then
    NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm.zip"
    echo "Arsitektur: ARM 32-bit (armv7l)"
elif [[ "$ARCH" == "aarch64" ]]; then
    NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.zip"
    echo "Arsitektur: ARM 64-bit (aarch64)"
else
    echo "ERROR: Arsitektur tidak didukung: $ARCH"
    exit 1
fi

echo
echo "[2/9] Membuat file .env..."

cat <<EOF > $ENV_FILE
ID_DEVICE_PI="$ID_DEVICE_PI"
NGROK_AUTHTOKEN="$NGROK_AUTHTOKEN"
FIREBASE_URL="$FIREBASE_URL"
PYTHON_SCRIPT_PATH="$PYTHON_SCRIPT_PATH"
USER_HOME="$USER_HOME"
EOF

chmod 600 $ENV_FILE
chown $SERVICE_USER:$SERVICE_USER $ENV_FILE

echo "File .env dibuat di: $ENV_FILE"

echo
echo "[3/9] Update package list..."
sudo apt update -y

echo "[4/9] Install ngrok v3..."
wget -q $NGROK_URL -O ngrok.zip
unzip -o ngrok.zip >/dev/null
sudo mv -f ngrok /usr/local/bin/ngrok
sudo chmod +x /usr/local/bin/ngrok
rm ngrok.zip

echo "[5/9] Set NGROK Authtoken..."
ngrok config add-authtoken $NGROK_AUTHTOKEN

echo "[6/9] Membuat script auto reconnect"

cat <<EOF > $NGROK_RUNNER
#!/bin/bash

while true
do
    echo "[NGROK] Starting tunnel..."
    /usr/local/bin/ngrok tcp 22 &

    NGROK_PID=\$!

    echo "[NGROK] Menunggu ngrok aktif..."

    # Tunggu API port 4040 siap sampai 30 detik
    for i in {1..30}; do
        if curl -s http://127.0.0.1:4040/api/tunnels >/dev/null; then
            echo "[NGROK] Ngrok aktif!"
            python3 "$PYTHON_SCRIPT_PATH"
            break
        fi
        sleep 1
    done

    wait \$NGROK_PID

    echo "[NGROK] Ngrok mati. Restart dalam 3 detik..."
    sleep 3

    rm -f /home/$SERVICE_USER/.ngrok2/ngrok.yml.lock 2>/dev/null
done
EOF

chmod +x $NGROK_RUNNER
chown $SERVICE_USER:$SERVICE_USER $NGROK_RUNNER

echo "[7/9] Membuat Python reporter..."

cat <<EOF > $PYTHON_SCRIPT_PATH
#!/usr/bin/env python3
import os, time, requests
from datetime import datetime

DEVICE_ID = os.getenv("ID_DEVICE_PI")
FIREBASE_URL = os.getenv("FIREBASE_URL")

def get_url():
    try:
        r = requests.get("http://127.0.0.1:4040/api/tunnels")
        for t in r.json().get("tunnels", []):
            if t.get("public_url", "").startswith("tcp://"):
                return t["public_url"]
    except:
        return None

print("Menunggu URL ngrok...")
for _ in range(30):
    url = get_url()
    if url:
        payload = {
            DEVICE_ID: {
                "url": url,
                "ip_local": os.popen("hostname -I").read().strip(),
                "updated_at": datetime.utcnow().isoformat() + "Z"
            }
        }
        r = requests.patch(FIREBASE_URL, json=payload)
        print("URL terkirim:", url)
        break
    time.sleep(1)
EOF

chmod +x $PYTHON_SCRIPT_PATH
chown $SERVICE_USER:$SERVICE_USER $PYTHON_SCRIPT_PATH

echo "[8/9] Membuat systemd service..."

cat <<EOF | sudo tee $SERVICE_PATH >/dev/null
[Unit]
Description=Ngrok V3 SSH + Auto Reconnect + Firebase Reporter
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$USER_HOME
EnvironmentFile=$ENV_FILE
ExecStart=/bin/bash $NGROK_RUNNER
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "[9/9] Mengaktifkan service..."
sudo systemctl daemon-reload
sudo systemctl enable ngrok-ssh
sudo systemctl restart ngrok-ssh

echo
echo "=========================================="
echo "     INSTALASI SELESAI & BERJALAN!"
echo "=========================================="
echo "Cek status dengan:"
echo "  sudo systemctl status ngrok-ssh"
echo
