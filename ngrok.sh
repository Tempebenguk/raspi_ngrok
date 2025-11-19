#!/bin/bash
set -e

echo "=========================================="
echo "     NGROK + FIREBASE AUTO INSTALLER      "
echo "=========================================="
echo

echo "[0/7] Mengumpulkan input user..."

# USER INPUT
read -p "Masukkan ID_DEVICE_PI: " ID_DEVICE_PI
read -p "Masukkan NGROK_AUTHTOKEN: " NGROK_AUTHTOKEN
read -p "Masukkan FIREBASE_URL (contoh: https://xxx.firebaseio.com/ngrok.json): " FIREBASE_URL
read -p "Masukkan USERNAME untuk service (default: pi): " SERVICE_USER
SERVICE_USER=${SERVICE_USER:-pi}

USER_HOME="/home/$SERVICE_USER"
ENV_FILE="$USER_HOME/.env"
PYTHON_SCRIPT_PATH="$USER_HOME/ngrok_reporter.py"
SERVICE_PATH="/etc/systemd/system/ngrok-ssh.service"

echo
echo "[1/7] Membuat file .env..."

# WRITE ENV
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

# LOAD ENV
set -a
source $ENV_FILE
set +a

if [[ -z "$NGROK_AUTHTOKEN" ]]; then
    echo "ERROR: NGROK_AUTHTOKEN tidak boleh kosong!"
    exit 1
fi

echo "[2/7] Update package list..."
sudo apt update -y

echo "[3/7] Install ngrok..."
wget -q https://bin.equinox.io/c/4VmDzA7iaHb/ngrok-stable-linux-arm.zip -O ngrok.zip
unzip -o ngrok.zip >/dev/null
sudo mv -f ngrok /usr/local/bin/
sudo chmod +x /usr/local/bin/ngrok
rm ngrok.zip

echo "[4/7] Set NGROK Authtoken..."
ngrok config add-authtoken $NGROK_AUTHTOKEN

# WRITE PYTHON SCRIPT
echo "[5/7] Membuat script Python reporter..."

cat <<EOF > $PYTHON_SCRIPT_PATH
#!/usr/bin/env python3
import os, time, json, requests
from datetime import datetime

DEVICE_ID = os.getenv("ID_DEVICE_PI")
FIREBASE_URL = os.getenv("FIREBASE_URL")

def get_ngrok_url():
    try:
        r = requests.get("http://127.0.0.1:4040/api/tunnels")
        data = r.json()
        for t in data.get("tunnels", []):
            if t.get("public_url", "").startswith("tcp://"):
                return t["public_url"]
    except Exception as e:
        print("Belum ada ngrok aktif:", e)
    return None

def send_to_firebase(url):
    payload = {
        DEVICE_ID: {
            "url": url,
            "hostname": DEVICE_ID,
            "ip_local": os.popen("hostname -I").read().strip(),
            "updated_at": datetime.utcnow().isoformat() + "Z"
        }
    }
    r = requests.patch(FIREBASE_URL, json=payload)
    print("Firebase:", r.status_code, r.text)

print("Menunggu ngrok aktif...")
for i in range(30):
    url = get_ngrok_url()
    if url:
        print("Dapat URL:", url)
        send_to_firebase(url)
        break
    time.sleep(2)
else:
    print("Gagal menemukan ngrok URL")
EOF

chmod +x $PYTHON_SCRIPT_PATH
chown $SERVICE_USER:$SERVICE_USER $PYTHON_SCRIPT_PATH

# WRITE SERVICE
echo "[6/7] Membuat systemd service..."

cat <<EOF | sudo tee $SERVICE_PATH >/dev/null
[Unit]
Description=Ngrok SSH Tunnel + Firebase Reporter (Dynamic)
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$USER_HOME
EnvironmentFile=$ENV_FILE

# start ngrok
ExecStart=/usr/local/bin/ngrok tcp 22

# jalankan reporter setelah ngrok aktif
ExecStartPost=/usr/bin/python3 ${PYTHON_SCRIPT_PATH}

Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "[7/7] Mengaktifkan service..."
sudo systemctl daemon-reload
sudo systemctl enable ngrok-ssh
sudo systemctl restart ngrok-ssh

echo
echo "=========================================="
echo "     INSTALASI SELESAI & BERJALAN!"
echo "=========================================="
echo "Cek status:"
echo "  sudo systemctl status ngrok-ssh"
echo
