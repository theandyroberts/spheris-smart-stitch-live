#!/bin/bash
# Deploy Spheris Stream Server to VPS
# Run from local machine: bash vps/deploy.sh

set -e
VPS="root@stream.sparkpoint.studio"

echo "=== Deploying Spheris Stream Server ==="

# 1. Install dependencies
echo "--- Installing packages ---"
ssh $VPS "apt update -qq && apt install -y -qq libnginx-mod-rtmp python3-venv python3-pip ffmpeg > /dev/null 2>&1"

# 2. Create directories
echo "--- Setting up directories ---"
ssh $VPS "mkdir -p /opt/spheris-stream /var/www/hls /var/www/spheris-data && chown -R www-data:www-data /var/www/hls /var/www/spheris-data"

# 3. Upload files
echo "--- Uploading files ---"
scp vps/app.py $VPS:/opt/spheris-stream/app.py
scp vps/nginx.conf $VPS:/etc/nginx/nginx.conf
scp vps/spheris-stream.service $VPS:/etc/systemd/system/spheris-stream.service

# 4. Set up Python venv and install Flask + gunicorn
echo "--- Setting up Python environment ---"
ssh $VPS "cd /opt/spheris-stream && python3 -m venv venv && venv/bin/pip install -q flask gunicorn"

# 5. Set permissions
ssh $VPS "chown -R www-data:www-data /opt/spheris-stream"

# 6. Enable and start services
echo "--- Starting services ---"
ssh $VPS "systemctl daemon-reload && systemctl enable spheris-stream && systemctl restart spheris-stream && systemctl restart nginx"

# 7. Open RTMP port in firewall (if ufw is active)
ssh $VPS "ufw allow 1935/tcp 2>/dev/null || true"

# 8. Verify
echo "--- Verifying ---"
sleep 2
STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://stream.sparkpoint.studio/)
echo "HTTPS status: $STATUS"
ssh $VPS "systemctl is-active spheris-stream"

echo ""
echo "=== Deployment complete ==="
echo "Stream URL:  rtmp://stream.sparkpoint.studio/live/spheris"
echo "Watch URL:   https://stream.sparkpoint.studio/"
echo "Admin API:   https://stream.sparkpoint.studio/api/admin/sessions"
echo ""
echo "Update the Mac app RTMP URL to: rtmp://stream.sparkpoint.studio/live/spheris"
