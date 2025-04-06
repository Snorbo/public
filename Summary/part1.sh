#!/bin/bash
set -e

echo -e "进行系统更新..."
apt update -y && apt install -y curl && apt install -y wget && apt install -y sudo && apt install -y socat && apt install -y unzip && apt install -y unzip && apt-get install tar && apt-get install vim && apt-get install nano

echo -e "安装warp..."
echo -e "请手动配置"
wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh [option] [lisence/url/token]
