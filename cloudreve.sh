#!/bin/bash
set -e
cd /tmp

echo -e "\n\033[32m开始下载cloudreve...\033[0m"
CLOUDREVE_VERSION="3.8.3"
wget https://github.com/cloudreve/Cloudreve/releases/download/${CLOUDREVE_VERSION}/cloudreve_${CLOUDREVE_VERSION}_linux_amd64.tar.gz

echo -e "\n\033[32m解压并安装到/opt/cloudreve...\033[0m"
sudo mkdir -p /opt/cloudreve
sudo tar -zxvf cloudreve_${CLOUDREVE_VERSION}_linux_amd64.tar.gz -C /opt/cloudreve

echo -e "\n\033[32m创建配置和数据目录...\033[0m"
sudo mkdir -p /opt/cloudreve/{conf,uploads,avatar}
sudo tee /etc/systemd/system/cloudreve.service <<'EOF'
[Unit]
Description=Cloudreve
After=network.target

[Service]
User=root
WorkingDirectory=/opt/cloudreve
ExecStart=/opt/cloudreve/cloudreve
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
echo -e "\n\033[32m重启相关服务...\033[0m"
sudo systemctl daemon-reload
sudo systemctl enable cloudreve
sudo systemctl start cloudreve
echo -e "\n\033[32m正在重置Cloudreve并提取初始凭据...\033[0m"
cd /opt/cloudreve/
sudo systemctl stop cloudreve 2>/dev/null || true
[ -f cloudreve.db ] && rm -f cloudreve.db
sed -i '/^\[System\]$/,/^\[/ s/^\(Listen\s*=\s*\):5212$/\1:1552/' conf.ini

./cloudreve 2>&1 | grep -E 'Admin user name:|Admin password:'
username=$(echo "$output" | grep -oP 'Admin user name:\s*\K\S+')
password=$(echo "$output" | grep -oP 'Admin password:\s*\K\S+')
echo -e "\n\033[32m====== 初始管理员凭据 ======\033[0m"
echo -e "账号: \033[36m$username\033[0m"
echo -e "密码: \033[31m$password\033[0m"
echo -e "\033[33m请立即登录修改密码！\033[0m"
echo -e "\n\033[32m正在启动后台服务...\033[0m"
sudo systemctl start cloudreve

