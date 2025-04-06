#!/bin/bash
set -e
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/basic1.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/bbr.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/nginx_systemd.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/nginx_bsv.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/acme_bsv.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/nginx_bsn.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/acme_bsn.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/spare/nginx.conf
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/nginx_change.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/spare/hysteria2.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/adguard.sh
wget https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/cloudreve.sh
chmod +x bbr.sh
chmod +x basic1.sh
chmod +x nginx_bsv.sh
chmod +x acme_bsv.sh
chmod +x nginx_bsn.sh
chmod +x acme_bsn.sh
chmod +x nginx.conf
chmod +x nginx_change.sh
chmod +x hysteria2.sh
chmod +x adguard.sh
chmod +x cloudreve.sh
sudo ./bbr.sh 1
