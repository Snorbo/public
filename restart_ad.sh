#!/bin/bash
set -e

RESOLVED_CONF="/etc/systemd/resolved.conf"
BACKUP_CONF="/etc/systemd/resolved.conf.bak.$(date +%Y%m%d%H%M%S)"

echo -e "\033[34m[1/4] 备份原始配置文件...\033[0m"
sudo cp -v "$RESOLVED_CONF" "$BACKUP_CONF"

echo -e "\n\033[34m[2/4] 修改配置文件...\033[0m"
if grep -q "^DNSStubListener=" "$RESOLVED_CONF"; then
    # 已存在则修改
    sudo sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' "$RESOLVED_CONF"
else
    # 不存在则追加
    echo -e "\n[Resolve]\nDNSStubListener=no" | sudo tee -a "$RESOLVED_CONF" >/dev/null
fi

echo -e "\n\033[34m[3/4] 应用配置更改...\033[0m"
sudo systemctl daemon-reload
sudo systemctl restart systemd-resolved.service

echo -e "\n\033[34m[4/4] 验证配置效果...\033[0m"
echo -e "\033[32m当前配置状态：\033[0m"
sudo systemd-resolve --status | grep "DNS Stub"

echo -e "\n\033[32m端口监听状态（应无127.0.0.53:53监听）：\033[0m"
ss -tulpn | grep ":53"

echo -e "\n\033[36m操作完成！如需回滚可执行：\033[0m"
echo "sudo cp $BACKUP_CONF $RESOLVED_CONF && sudo systemctl restart systemd-resolved"
