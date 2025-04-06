#!/bin/bash
set -e

# 配置参数
VERSION="v0.107.59"
INSTALL_DIR="/opt/AdGuardHome"
SERVICE_USER="adguard"
SERVICE_GROUP="adguard"
SERVICE_FILE="/etc/systemd/system/AdGuardHome.service"
DOWNLOAD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/${VERSION}/AdGuardHome_linux_amd64.tar.gz"
TMP_DIR=$(mktemp -d)
RESOLVED_CONF="/etc/systemd/resolved.conf"
BACKUP_CONF="/etc/systemd/resolved.conf.bak.$(date +%Y%m%d%H%M%S)"

# 颜色定义
COLOR_GREEN='\033[32m'
COLOR_BLUE='\033[34m'
COLOR_RED='\033[31m'
COLOR_RESET='\033[0m'

# 检查URL有效性
check_url() {
  if ! curl --output /dev/null --silent --head --fail "$1"; then
    echo -e "${COLOR_RED}错误：下载地址无效 ${DOWNLOAD_URL}${COLOR_RESET}"
    echo "请检查："
    echo "1. 网络连接状态"
    echo "2. 版本是否存在"
    exit 1
  fi
}

# 检查端口占用
check_port() {
  if ss -tulpn | grep -q ":$1 "; then
    echo -e "${COLOR_RED}错误：端口 $1 已被占用，请先停止相关服务${COLOR_RESET}"
    exit 1
  fi
}

# 创建服务用户
create_service_user() {
  if ! id "${SERVICE_USER}" &>/dev/null; then
    sudo useradd -r -s /usr/sbin/nologin "${SERVICE_USER}"
    echo -e "${COLOR_BLUE}已创建系统用户：${SERVICE_USER}${COLOR_RESET}"
  fi
}

echo -e "${COLOR_BLUE}[1/10] 验证下载地址...${COLOR_RESET}"
check_url "${DOWNLOAD_URL}"

echo -e "\n${COLOR_BLUE}[2/10] 检查端口占用...${COLOR_RESET}"
check_port 53
check_port 3000

echo -e "\n${COLOR_BLUE}[3/10] 准备安装环境...${COLOR_RESET}"
sudo apt-get update > /dev/null
sudo apt-get install -y wget tar curl > /dev/null

echo -e "\n${COLOR_BLUE}[4/10] 配置系统DNS...${COLOR_RESET}"
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved > /dev/null

echo -e "\n${COLOR_BLUE}备份DNS配置...${COLOR_RESET}"
sudo cp -v "$RESOLVED_CONF" "$BACKUP_CONF"

sudo sed -i '/^DNSStubListener/d' "$RESOLVED_CONF"
echo -e "[Resolve]\nDNSStubListener=no" | sudo tee -a "$RESOLVED_CONF" >/dev/null

sudo systemctl daemon-reload
sudo systemctl restart systemd-resolved.service

echo -e "\n${COLOR_BLUE}[5/10] 创建服务用户...${COLOR_RESET}"
create_service_user

echo -e "\n${COLOR_BLUE}[6/10] 下载 AdGuard Home ${VERSION}...${COLOR_RESET}"
cd "${TMP_DIR}"
wget -q --show-progress "${DOWNLOAD_URL}"

echo -e "\n${COLOR_BLUE}[7/10] 解压安装文件...${COLOR_RESET}"
tar -xzf AdGuardHome_linux_amd64.tar.gz || {
  echo -e "${COLOR_RED}解压失败，文件可能已损坏${COLOR_RESET}"
  exit 1
}

echo -e "\n${COLOR_BLUE}[8/10] 安装到系统目录...${COLOR_RESET}"
sudo mkdir -p "${INSTALL_DIR}/workdir"
sudo mv AdGuardHome/AdGuardHome "${INSTALL_DIR}/"
sudo chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${INSTALL_DIR}"
sudo chmod +x "${INSTALL_DIR}/AdGuardHome"

echo -e "\n${COLOR_BLUE}[9/10] 创建系统服务...${COLOR_RESET}"
sudo tee "${SERVICE_FILE}" > /dev/null <<'EOF'
[Unit]
Description=AdGuard Home
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/AdGuardHome -w ${INSTALL_DIR}/workdir -c ${INSTALL_DIR}/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

echo -e "\n${COLOR_BLUE}[10/10] 启动服务...${COLOR_RESET}"
sudo systemctl daemon-reload
sudo systemctl enable --now AdGuardHome > /dev/null
sudo systemctl start AdGuardHome

# 验证安装
echo -e "\n${COLOR_BLUE}验证服务状态...${COLOR_RESET}"
sleep 3
if ! systemctl is-active --quiet AdGuardHome; then
  echo -e "${COLOR_RED}服务启动失败，查看日志：${COLOR_RESET}"
  journalctl -u AdGuardHome -n 10 --no-pager
  exit 1
fi

echo -e "\n${COLOR_GREEN}安装成功！请执行以下操作：${COLOR_RESET}"
echo "1. 打开管理界面：http://$(curl -s ifconfig.me):3000"
echo "2. 完成网页初始化配置"
echo "3. 配置防火墙开放53/UDP/TCP和3000/TCP端口"

echo -e "\n${COLOR_BLUE}管理命令：${COLOR_RESET}"
echo "启动服务：sudo systemctl start AdGuardHome"
echo "查看状态：sudo systemctl status AdGuardHome"
echo "查看日志：journalctl -u AdGuardHome -f"

# 清理临时文件
rm -rf "${TMP_DIR}"
