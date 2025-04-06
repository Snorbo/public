#!/bin/bash
set -e
cd /tmp

echo -e "\n\033[32m开始下载cloudreve...\033[0m"
CLOUDREVE_VERSION="3.8.3"
wget https://github.com/cloudreve/Cloudreve/releases/download/${CLOUDREVE_VERSION}/cloudreve_${CLOUDREVE_VERSION}_linux_amd64.tar.gz

echo -e "\n\033[32m解压并安装到/opt/cloudreve...\033[0m"
sudo mkdir -p /opt/cloudreve
sudo tar -zxf cloudreve_${CLOUDREVE_VERSION}_linux_amd64.tar.gz -C /opt/cloudreve

echo -e "\n\033[32m创建配置和数据目录...\033[0m"
sudo mkdir -p /opt/cloudreve/{conf,uploads,avatar}

echo -e "\n\033[32m创建系统服务...\033[0m"
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
echo -e "\n\033[32m启动长期服务...\033[0m"
sudo systemctl daemon-reload
sudo systemctl enable cloudreve
echo -e "\033[33m正在生成初始凭据...\033[0m"
/opt/cloudreve/./cloudreve 2>&1 | grep -E 'Admin user name:|Admin password:'
echo -e "\n\033[32m====== 初始管理员凭据 ======\033[0m"
echo -e "\033[33m请立即记录账号密码（本地未保存）\033[0m"
echo -e "\033[33m请手动重启\033[0m"
echo -e "sudo systemctl start cloudreve"


