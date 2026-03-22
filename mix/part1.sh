#!/bin/bash

# 1. 系统更新与 OpenSSH 更新
echo "正在更新系统列表并升级所有软件包..."
sudo apt update && sudo apt full-upgrade -y

# 2. 安装 btop
echo "正在安装 btop..."
sudo apt install btop -y

# 3. 设置虚拟内存 (Swap) 为 1024MB
echo "正在配置 1024MB 虚拟内存..."
# 先禁用现有可能的 swapfile
sudo swapoff -a
# 创建 1G 文件
sudo dd if=/dev/zero of=/swapfile bs=1M count=1024
# 设置权限
sudo chmod 600 /swapfile
# 格式化并启用
sudo mkswap /swapfile
sudo swapon /swapfile
# 写入 fstab 实现开机自启（防止重复写入）
if ! grep -q "/swapfile" /etc/fstab; then
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# 4. 修改 SSH 端口 (默认1556)
NEW_PORT=1556
echo "正在将 SSH 端口修改为 $NEW_PORT..."
sudo sed -i "s/^#Port 22/Port $NEW_PORT/" /etc/ssh/sshd_config
sudo sed -i "s/^Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
# 注意：如果开启了 UFW 防火墙，需要放行新端口
sudo ufw allow $NEW_PORT/tcp > /dev/null 2>&1

# 5. 系统清理
echo "正在清理无用缓存和旧软件包..."
sudo apt autoremove -y
sudo apt autoclean

# 6. openssh更新
apt update -y
apt install build-essential zlib1g-dev libssl-dev -y
wget https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.2p1.tar.gz
tar -xzf openssh-10.2p1.tar.gz
cd openssh-10.2p1
./configure
make
make install
#重启ssh
systemctl restart sshd
service sshd restart

echo "------------------------------------------------"
echo "所有任务已完成！"
echo "请记住：下次登录请使用新端口: $NEW_PORT"
echo "当前虚拟内存状态："
free -m
