#!/bin/bash
set -e

echo -e "\n\033[32m更新软件包列表\033[0m"
sudo apt update
echo -e "\n\033[32安装ufw\033[0m"
sudo apt install ufw -y
echo -e "\n\033[32配置规则并启动\033[0m"
sudo ufw disable
sudo ufw reset
sudo ufw allow 53
sudo ufw allow 80
sudo ufw allow 323
sudo ufw allow 443
sudo ufw allow 1556
sudo ufw allow 1555
sudo ufw enable
echo -e "\n\033[32配置成功，请注意：warp端口未开放\033[0m"
