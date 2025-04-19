#!/bin/bash
set -e
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/basic1.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/basic2.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/bbr.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/nginx_bsc.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/acme_bsc.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/nginx_bsp.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/acme_bsp.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/nginx.conf
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/nginx_change.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/hysteria2.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/adguard.sh
chmod +x bbr.sh
chmod +x basic1.sh
chmod +x basic2.sh
chmod +x nginx_bsc.sh
chmod +x acme_bsc.sh
chmod +x nginx_bsp.sh
chmod +x acme_bsp.sh
chmod +x nginx_change.sh
chmod +x hysteria2.sh
chmod +x adguard.sh
sudo ./bbr.sh 1
