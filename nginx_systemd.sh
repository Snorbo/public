#!/bin/bash
set -e

echo "正在配置Nginx systemd服务..."
sudo tee /etc/systemd/system/nginx.service >/dev/null <<'EOF'
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/usr/local/nginx/sbin/nginx -s quit
PrivateTmp=true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "添加PATH到环境变量..."
echo "export PATH=\$PATH:/usr/local/nginx/sbin" | sudo tee /etc/profile.d/nginx-path.sh >/dev/null

echo "应用系统配置..."
sudo systemctl daemon-reload
source /etc/profile

echo "启用并启动Nginx服务..."
sudo systemctl enable --now nginx

echo -e "\n操作完成！请验证服务状态："
systemctl status nginx
