#!/bin/bash
set -e

NGINX_CONF="/usr/local/nginx/conf/nginx.conf"

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
        server_name  doh.knauf.quest;
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

echo -e "\n重启Nginx服务..."
sudo systemctl restart nginx

echo -e "\n\033[32m操作成功完成！\033[0m"
