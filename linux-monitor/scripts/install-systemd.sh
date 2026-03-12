#!/bin/bash
set -e
INSTALL_DIR=/opt/playback-monitor
sudo mkdir -p $INSTALL_DIR
sudo cp -r . $INSTALL_DIR
sudo npm install --prefix $INSTALL_DIR --production
cat <<EOF | sudo tee /etc/systemd/system/playback-monitor.service
[Unit]
Description=Playback Monitor Service
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/node $INSTALL_DIR/dist/server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable playback-monitor
echo "Installed. Start with: sudo systemctl start playback-monitor"
