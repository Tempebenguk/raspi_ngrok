#!/bin/bash
set -e

echo "=========================================="
echo "   INSTALASI NGROK V3 + FIREBASE OTOMATIS"
echo "=========================================="
echo

echo "[0/9] Mengumpulkan input dari pengguna..."

read -p "Masukkan ID_DEVICE_PI: " ID_DEVICE_PI
read -p "Masukkan NGROK_AUTHTOKEN: " NGROK_AUTHTOKEN
read -p "Masukkan FIREBASE_URL (contoh: https://xxx.firebaseio.com/ngrok.json): " FIREBASE_URL
read -p "Masukkan USERNAME Raspberry Pi (default: pi): " SERVICE_USER
SERVICE_USER=${SERVICE_USER:-pi}

USER_HOME="/home/$SERVICE_USER"
ENV_FILE="$USER_HOME/.env"
PYTHON_SCRIPT_PATH="$USER_HOME/ngrok_reporter.py"
NGROK_RUNNER="$USER_HOME/ngrok_runner.sh"
SERVICE_PATH="/etc/systemd/system/ngrok-ssh.service"

echo
echo "[1/9] Mendeteksi arsitektur Raspberry Pi..."

ARCH=$(uname -m)

if [[ "$ARCH" == "armv7l" ]]; then
    NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm.tgz"
    echo "Arsitektur: ARM 32-bit (armv7l)"
elif [[ "$ARCH" == "aarch64" ]]; then
    NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz"
    echo "Arsitektur: ARM 64-bit (aarch64)"
else
    echo "ERROR: Arsitektur tidak didukung ($ARCH)."
    exit 1
fi

echo
echo "[2/9] Membuat file .env..."

cat <<EOF > $ENV_FILE
ID_DEVICE_PI="$ID_DEVICE_PI"
NGROK_AUTHTOKEN="$NGROK_AUTHTOKEN"
FIREBASE_URL="$FIREBASE_URL"
USER_HOME="$USER_HOME"
PYTHON_SCRIPT_PATH="$PYTHON_SCRIPT_PATH"
EOF

chmod 600 $ENV_FILE
chown $SERVICE_USER:$SERVICE_USER $ENV_FILE

echo "[3/9] Update daftar paket..."
apt update -y

echo "[4/9] Mengunduh & memasang NGROK v3..."
wget -q $NGROK_URL -O ngrok.tgz
tar -xzf ngrok.tgz
sudo mv -f ngrok /usr/local/bin/ngrok
sudo chmod +x /usr/local/bin/ngrok
rm ngrok.tgz

echo "[5/9] Memasang Authtoken untuk user: $SERVICE_USER ..."
sudo -u $SERVICE_USER /usr/local/bin/ngrok config add-authtoken "$NGROK_AUTHTOKEN"

echo "[6/9] Membuat script ngrok_runner (auto reconnect)..."

cat <<EOF > $NGROK_RUNNER
#!/bin/bash
# Script ini menjalankan NGROK secara terus menerus dan mengirim laporan
# ke Firebase setiap tunnel baru aktif.

set -e

# Muat variabel dari file .env
set -a
source "$USER_HOME/.env"
set +a

while true
do
    echo "[NGROK] Memulai tunnel ngrok..."
    /usr/local/bin/ngrok tcp 22 &
    NGROK_PID=\$!

    echo "[NGROK] Menunggu API ngrok aktif (port 4040)..."

    for i in {1..30}; do
        if curl -s http://127.0.0.1:4040/api/tunnels >/dev/null; then
            echo "[NGROK] Ngrok aktif! Menjalankan reporter..."
            python3 "\$PYTHON_SCRIPT_PATH"
            break
        fi
        sleep 1
    done

    echo "[NGROK] Monitoring proses ngrok (PID: \$NGROK_PID)..."
    wait \$NGROK_PID

    echo "[NGROK] Ngrok berhenti! Restart dalam 3 detik..."
    sleep 3
done
EOF

chmod +x $NGROK_RUNNER
chown $SERVICE_USER:$SERVICE_USER $NGROK_RUNNER

echo "[7/9] Membuat script Python reporter..."

cat <<EOF > $PYTHON_SCRIPT_PATH
#!/usr/bin/env python3
import os, time, requests
from datetime import datetime

DEVICE_ID = os.getenv("ID_DEVICE_PI")
FIREBASE_URL = os.getenv("FIREBASE_URL")

def get_url():
    """Ambil URL tunnel ngrok dari API lokal."""
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
        data = {
            DEVICE_ID: {
                "url": url,
                "ip_local": os.popen("hostname -I").read().strip(),
                "updated_at": datetime.utcnow().isoformat() + "Z"
            }
        }
        requests.patch(FIREBASE_URL, json=data)
        print("URL terkirim ke Firebase:", url)
        break
    time.sleep(1)
EOF

chmod +x $PYTHON_SCRIPT_PATH
chown $SERVICE_USER:$SERVICE_USER $PYTHON_SCRIPT_PATH


echo "[8/9] Membuat systemd service..."

cat <<EOF | tee $SERVICE_PATH >/dev/null
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
systemctl daemon-reload
systemctl enable ngrok-ssh
systemctl restart ngrok-ssh

echo
echo "=========================================="
echo "       NGROK v3 BERHASIL DIINSTAL!"
echo "=========================================="
echo
