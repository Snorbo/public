#!/bin/bash
set -e

# 配置参数
VERSION="v0.107.59"
INSTALL_DIR="/opt/AdGuardHome"
SERVICE_FILE="/etc/systemd/system/AdGuardHome.service"
DOWNLOAD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/${VERSION}/AdGuardHome_linux_amd64.tar.gz"
TMP_DIR=$(mktemp -d)
RESOLVED_CONF="/etc/systemd/resolved.conf"
BACKUP_CONF="/etc/systemd/resolved.conf.bak.$(date +%Y%m%d%H%M%S)"

# 颜色定义
COLOR_GREEN='\033[32m'
COLOR_BLUE='\033[34m'
COLOR_RESET='\033[0m'

echo -e "${COLOR_BLUE}关闭可能的系统DNS服务...${COLOR_RESET}"
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
echo -e "\033[34m[1/4] 备份原始配置文件...\033[0m"
sudo cp -v "$RESOLVED_CONF" "$BACKUP_CONF"
echo -e "\n\033[34m[2/4] 修改配置文件...\033[0m"
if grep -q "^DNSStubListener=" "$RESOLVED_CONF"; then
    # 已存在则修改
    sudo sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' "$RESOLVED_CONF"
else
    # 不存在则追加
    echo -e "\n[Resolve]\nDNSStubListener=no" | sudo tee -a "$RESOLVED_CONF" >/dev/null
fi
echo -e "\n\033[34m[3/4] 应用配置更改...\033[0m"
sudo systemctl daemon-reload
sudo systemctl restart systemd-resolved.service
#echo -e "\n\033[34m[4/4] 验证配置效果...\033[0m"
#echo -e "\033[32m当前配置状态：\033[0m"
#sudo systemd-resolve --status | grep "DNS Stub"
#echo -e "\n\033[32m端口监听状态（应无127.0.0.53:53监听）：\033[0m"
#ss -tulpn | grep ":53"
#echo -e "\n\033[36m操作完成！如需回滚可执行：\033[0m"
#echo "sudo cp $BACKUP_CONF $RESOLVED_CONF && sudo systemctl restart systemd-resolved"
echo -e "${COLOR_BLUE}完成DNS清零...${COLOR_RESET}"
echo -e "${COLOR_BLUE}[1/7] 准备安装环境...${COLOR_RESET}"
sudo apt-get update > /dev/null
sudo apt-get install -y wget tar > /dev/null
mkdir -p "${TMP_DIR}"

echo -e "\n${COLOR_BLUE}[2/7] 下载 AdGuard Home ${VERSION}...${COLOR_RESET}"
cd "${TMP_DIR}"
if ! wget -q --show-progress "${DOWNLOAD_URL}"; then
    echo -e "\n\033[31m下载失败，请检查：\033[0m"
    echo "1. 网络连接状态"
    echo "2. 版本是否存在：${DOWNLOAD_URL}"
    exit 1
fi

echo -e "\n${COLOR_BLUE}[3/7] 解压安装文件...${COLOR_RESET}"
tar -xzf AdGuardHome_linux_amd64.tar.gz || {
    echo -e "\033[31m解压失败，文件可能已损坏\033[0m"
    exit 1
}

echo -e "\n${COLOR_BLUE}[4/7] 安装到系统目录...${COLOR_RESET}"
sudo mkdir -p "${INSTALL_DIR}"
sudo mv AdGuardHome/AdGuardHome "${INSTALL_DIR}/"
sudo chmod +x "${INSTALL_DIR}/AdGuardHome"

echo -e "\n${COLOR_BLUE}[5/7] 创建系统服务...${COLOR_RESET}"
sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=AdGuard Home
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/AdGuardHome -w ${INSTALL_DIR}/workdir -c ${INSTALL_DIR}/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

echo -e "\n${COLOR_BLUE}[6/7] 应用服务配置...${COLOR_RESET}"
sudo systemctl daemon-reload
sudo systemctl enable AdGuardHome > /dev/null

echo -e "\n${COLOR_BLUE}[7/7] 启动服务...${COLOR_RESET}"
if ! sudo systemctl start AdGuardHome; then
    echo -e "\033[31m服务启动失败，查看日志：\033[0m"
    journalctl -u AdGuardHome -n 10 --no-pager
    exit 1
fi

# 清理临时文件
rm -rf "${TMP_DIR}"

echo -e "\n${COLOR_GREEN}安装成功！请执行以下操作：${COLOR_RESET}"
echo "1. 访问管理界面：http://185.22.153.33:3000"
echo "2. 完成网页端的初始化配置"
echo -e "\n管理命令："
echo "启动服务：sudo systemctl start AdGuardHome"
echo "查看状态：sudo systemctl status AdGuardHome"
echo "查看日志：journalctl -u AdGuardHome -f"
