#!/bin/bash
set -e

# 配置参数
CLOUDREVE_VERSION="3.8.3"
INSTALL_DIR="/opt/cloudreve"
SERVICE_FILE="/etc/systemd/system/cloudreve.service"
DOWNLOAD_URL="https://github.com/cloudreve/Cloudreve/releases/download/${CLOUDREVE_VERSION}/cloudreve_${CLOUDREVE_VERSION}_linux_amd64.tar.gz"
TMP_DIR="/tmp"

echo -e "\033[34m[1/7] 正在准备安装环境...\033[0m"
sudo apt-get update >/dev/null
sudo apt-get install -y wget tar >/dev/null

echo -e "\n\033[34m[2/7] 下载 Cloudreve ${CLOUDREVE_VERSION}...\033[0m"
cd "${TMP_DIR}"
    wget -q --show-progress "${DOWNLOAD_URL}"

echo -e "\n\033[34m[3/7] 解压安装文件...\033[0m"
sudo mkdir -p "${INSTALL_DIR}"
sudo tar -zxf cloudreve_${CLOUDREVE_VERSION}_linux_amd64.tar.gz -C /opt/cloudreve

echo -e "\n\033[34m[4/7] 创建数据目录...\033[0m"
sudo mkdir -p "${INSTALL_DIR}/"{conf,uploads,avatar}
sudo chmod -R 750 "${INSTALL_DIR}"

echo -e "\n\033[34m[5/7] 配置系统服务...\033[0m"
sudo tee "${SERVICE_FILE}" >/dev/null <<EOF
[Unit]
Description=Cloudreve Service
After=network.target
Wants=network.target

[Service]
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/cloudreve
Restart=on-abnormal
RestartSec=5s
KillMode=mixed

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo -e "\n\033[34m[6/7] 应用服务配置...\033[0m"
sudo systemctl daemon-reload
sudo systemctl enable cloudreve >/dev/null

echo -e "\n\033[34m[7/7] 启动服务...\033[0m"
if ! sudo systemctl start cloudreve; then
    echo -e "\033[31m服务启动失败，请检查以下日志：\033[0m"
    journalctl -u cloudreve -n 10 --no-pager
    exit 1
fi

echo -e "\n\033[32m安装成功！请执行以下操作：\033[0m"
echo "1. 查看初始密码：sudo journalctl -u cloudreve | grep '初始管理员密码'"
echo "2. 访问面板: http://your_server_ip:5212"
echo "3. 防火墙配置：sudo ufw allow 5212/tcp"
echo -e "\n管理命令："
echo "启动服务：sudo systemctl start cloudreve"
echo "查看状态：sudo systemctl status cloudreve"
echo "查看日志：journalctl -u cloudreve -f"
