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

echo -e "\n所有操作已完成！"
