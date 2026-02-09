#!/bin/bash
set -e

NGINX_CONF="/usr/local/nginx/conf/nginx.conf"

# 获取用户输入的server_name
echo -e "\n请输入Nginx配置的server_name（例如：flare.maya.locker）："
read -r SERVER_NAME

# 检查输入是否为空
if [ -z "$SERVER_NAME" ]; then
    echo -e "\033[31m错误：server_name不能为空！\033[0m"
    exit 1
fi

echo -e "\n正在生成Nginx配置，server_name: $SERVER_NAME..."

sudo tee "$NGINX_CONF" >/dev/null <<EOF
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
        server_name  $SERVER_NAME;
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

echo -e "\n正在重启Nginx服务..."
sudo systemctl restart nginx

echo -e "\n\033[32m操作成功完成！\033[0m"
echo -e "已配置server_name: \033[33m$SERVER_NAME\033[0m"
