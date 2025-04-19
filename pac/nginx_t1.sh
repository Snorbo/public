#!/bin/bash
set -e

NGINX_CONF="/usr/local/nginx/conf/nginx.conf"
BACKUP_CONF="/usr/local/nginx/conf/nginx.conf.bak.$(date +%Y%m%d%H%M%S)"

echo "正在备份原始配置文件..."
sudo cp -v "$NGINX_CONF" "$BACKUP_CONF"

echo -e "\n生成新的Nginx配置..."
sudo tee "$NGINX_CONF" >/dev/null <<'EOF'
worker_processes  1;
events {
    worker_connections  1024;
}
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    server {
        listen       80;
        server_name  t1.ffe.quest;
        location / {
            root   html;
            index  index.html index.htm;
        }
        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   html;
        }
    }
}
EOF

echo -e "\n验证配置文件语法..."
sudo /usr/local/nginx/sbin/nginx -t || {
    echo -e "\033[31m配置文件验证失败，正在恢复备份...\033[0m"
    sudo mv -f "$BACKUP_CONF" "$NGINX_CONF"
    exit 1
}

echo -e "\n重启Nginx服务..."
sudo systemctl restart nginx

echo -e "\n\033[32m操作成功完成！\033[0m"
echo "备份文件位置：$BACKUP_CONF"
