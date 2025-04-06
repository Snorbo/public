#!/bin/bash
set -e

wget https://nginx.org/download/nginx-1.27.4.tar.gz
tar -zxvf nginx-1.27.4.tar.gz
cd nginx-1.27.4
apt install gcc make -y
apt install libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev -y
./configure --prefix=/usr/local/nginx --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-stream --with-stream_ssl_module --with-http_realip_module --with-stream_ssl_preread_module 
make && make install
systemctl start nginx
#配置nginx开机启动
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/nginx_systemd.sh
chmod +x nginx_systemd.sh
sudo ./nginx_systemd.sh
