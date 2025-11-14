#!/bin/bash
set -e

echo "=========================================="
echo "     NGROK + FIREBASE AUTO INSTALLER      "
echo "=========================================="
echo

# ---------- CONFIGURASI ----------
NGROK_AUTHTOKEN="2hiWLISZVB1Q0d4z4jnWXY8r2C0_sBPKbU4Qndy4WQQB1hTY"
FIREBASE_URL="https://iot-dts-vsga-default-rtdb.asia-southeast1.firebasedatabase.app/ngrok.json"
PYTHON_SCRIPT_PATH="/home/pi/ngrok_reporter.py"
SERVICE_PATH="/etc/systemd/system/ngrok-ssh.service"
USER_HOME="/home/pi"
# --------------------------------

if [ -z "$NGROK_AUTHTOKEN" ]; then
  echo "ERROR: Authtoken kosong!"
  exit 1
fi

echo "[1/6] Menginstall dependencies..."
sudo apt update
sudo apt install -y python3 python3-pip wget unzip

echo "[2/6] Menginstall ngrok..."
wget -q https://bin.equinox.io/c/4VmDzA7iaHb/ngrok-stable-linux-arm.zip -O ngrok.zip
unzip -o ngrok.zip >/dev/null
sudo mv -f ngrok /usr/local/bin/
sudo chmod +x /usr/local/bin/ngrok
rm ngrok.zip

echo "[3/6] Menambahkan authtoken ngrok..."
ngrok config add-authtoken $NGROK_AUTHTOKEN

echo "[4/6] Membuat script reporter Firebase..."
cat <<EOF > $PYTHON_SCRIPT_PATH
#!/usr/bin/env python3
import os, time, json, requests
from datetime import datetime

DEVICE_ID = os.uname()[1]
FIREBASE_URL = "$FIREBASE_URL"

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
chown pi:pi $PYTHON_SCRIPT_PATH

echo "[5/6] Membuat systemd service..."
cat <<EOF | sudo tee $SERVICE_PATH >/dev/null
[Unit]
Description=Ngrok SSH Tunnel + Firebase Reporter
After=network-online.target
Wants=network-online.target

[Service]
User=pi
WorkingDirectory=/home/pi
ExecStart=/usr/local/bin/ngrok tcp 22
ExecStartPost=/usr/bin/python3 /home/pi/ngrok_reporter.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "[6/6] Mengaktifkan service systemd..."
sudo systemctl daemon-reload
sudo systemctl enable ngrok-ssh

echo
echo "=========================================="
echo "   INSTALASI SELESAI!"
echo "   Service akan aktif setelah reboot."
echo "=========================================="
echo
echo "Jalankan:"
echo "   sudo systemctl start ngrok-ssh"
echo "Untuk memulai sekarang, atau reboot."
echo
