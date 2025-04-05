#!/bin/bash
set -e

echo "正在安装Speedtest..."
sudo apt-get update
sudo apt-get install -y curl
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
sudo apt-get install -y speedtest

echo -e "\n正在安装Nexttrace..."
echo "deb [trusted=yes] https://github.com/nxtrace/nexttrace-debs/releases/latest/download ./" | \
sudo tee /etc/apt/sources.list.d/nexttrace.list
sudo apt-get update
sudo apt-get install -y nexttrace

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

sudo chmod 644 /etc/systemd/system/set-io-scheduler.service
sudo systemctl daemon-reload
sudo systemctl enable --now set-io-scheduler

echo -e "\n所有操作已完成！"
