#!/bin/bash
set -e

# 配置文件路径定义
OLD_CONF="/usr/local/nginx/conf/nginx.conf"
NEW_CONF="/root/nginx.conf"
BACKUP_DIR="/root/nginx_backups"

echo -e "\033[34m验证新配置文件是否存在...\033[0m"
if [ ! -f "$NEW_CONF" ]; then
    echo -e "\033[31m错误：新配置文件 $NEW_CONF 不存在！\033[0m"
    exit 1
fi

echo -e "\n\033[34m创建备份目录...\033[0m"
sudo mkdir -p "$BACKUP_DIR" >/dev/null

echo -e "\n\033[34m备份旧配置文件...\033[0m"
if [ -f "$OLD_CONF" ]; then
    BACKUP_FILE="$BACKUP_DIR/nginx.conf.bak_$(date +%Y%m%d%H%M%S)"
    sudo cp -v "$OLD_CONF" "$BACKUP_FILE"
else
    echo -e "\033[33m警告：原配置文件 $OLD_CONF 不存在，跳过备份\033[0m"
fi

echo -e "\n\033[34m删除旧配置文件...\033[0m"
sudo rm -vf "$OLD_CONF" || true

echo -e "\n\033[34m移动新配置文件...\033[0m"
sudo mv -v "$NEW_CONF" "$OLD_CONF"

echo -e "\n\033[34m设置文件权限...\033[0m"
sudo chown root:root "$OLD_CONF"
sudo chmod 644 "$OLD_CONF"

echo -e "\n\033[34m验证配置文件语法...\033[0m"
if ! sudo /usr/local/nginx/sbin/nginx -t; then
    echo -e "\n\033[31m配置文件验证失败！请执行以下操作：\033[0m"
    echo "1. 手动恢复备份：sudo cp $BACKUP_FILE $OLD_CONF"
    echo "2. 检查配置文件：sudo nano $OLD_CONF"
    exit 1
fi

echo -e "\n\033[34m重启Nginx服务...\033[0m"
sudo systemctl restart nginx

echo -e "\n\033[32m操作成功完成！验证步骤：\033[0m"
echo "1. 检查运行状态：systemctl status nginx"
echo "2. 验证配置版本：sudo nginx -V"
echo "3. 查看最近备份：ls -lht $BACKUP_DIR | head -n 5"
