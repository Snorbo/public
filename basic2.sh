#!/bin/bash
set -e

echo -e "\n配置I/O调度器（仅适用于JustHost的vda磁盘）..."
sudo tee /etc/systemd/system/set-io-scheduler.service >/dev/null <<'EOF'
[Unit]
Description=Set Disk Scheduler to None
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo "none" > /sys/block/vda/queue/scheduler'

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 0644 /etc/systemd/system/set-io-scheduler.service
sudo systemctl daemon-reload
sudo systemctl enable --now set-io-scheduler

echo -e "\n已完成配置操作..."

