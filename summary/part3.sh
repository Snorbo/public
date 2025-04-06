#!/bin/bash
set -e

sudo ./basic1.sh
sudo ./nginx_bsv.sh
sudo ./acme_bsv.sh
sudo ./nginx_bsn.sh
sudo ./acme_bsn.sh
sudo ./nginx.conf
sudo ./nginx_change.sh
sudo ./hysteria2.sh
sudo ./adguard.sh
sudo ./cloudreve.sh
