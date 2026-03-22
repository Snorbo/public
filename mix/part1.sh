#!/bin/bash

# --- 变量配置 ---
NEW_PORT=1556  # SSH连接默认为1556端口
NGINX_VER="1.29.5"
SSH_VER="10.2p1"

# 1. 系统更新与 OpenSSH 更新
echo "正在更新系统列表并升级所有软件包..."
sudo apt update && sudo apt full-upgrade -y

# 2. 安装 btop
echo "正在安装 btop..."
sudo apt install btop -y

# 3. 编译安装 OpenSSH 10.2p1
echo "正在编译安装 OpenSSH $SSH_VER..."
cd /root
wget https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-$SSH_VER.tar.gz
tar -xzf openssh-$SSH_VER.tar.gz
cd openssh-$SSH_VER
# 配置路径以覆盖系统默认，并开启 PAM 支持
./configure --prefix=/usr --sysconfdir=/etc/ssh --with-md5-passwords --with-pam
make && sudo make install
#重启ssh
systemctl restart sshd
service sshd restart

# 4. 设置虚拟内存 (Swap) 为 1024MB
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

# 5. 修改 SSH 端口  （重启切换？）
echo "正在将 SSH 端口修改为 $NEW_PORT..."
sudo sed -i "s/^#Port 22/Port $NEW_PORT/" /etc/ssh/sshd_config
sudo sed -i "s/^Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
# 注意：如果开启了 UFW 防火墙，需要放行新端口
sudo ufw allow $NEW_PORT/tcp > /dev/null 2>&1

# 6.安装nexttrace
echo "正在安装 NextTrace..."
cd /root
curl -sL nxtrace.org/nt | bash

# 7. 编译安装 Nginx (支持 HTTP/3 & Stream)
echo "开始编译 Nginx $NGINX_VER..."
cd /root
wget https://nginx.org/download/nginx-$NGINX_VER.tar.gz
tar -zxvf nginx-$NGINX_VER.tar.gz
cd nginx-$NGINX_VER

./configure --prefix=/usr/local/nginx \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-http_realip_module \
    --with-stream_ssl_preread_module 

make && make install

# 6. 配置 Nginx Systemd 开机启动
echo "正在配置Nginx systemd服务..."
cd /root
sudo tee /etc/systemd/system/nginx.service >/dev/null <<'EOF'
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
After=xray.service

[Service]
Type=forking
ExecStartPre=/usr/local/nginx/sbin/nginx -t
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

echo "添加PATH到环境变量..."
echo "export PATH=\$PATH:/usr/local/nginx/sbin" | sudo tee /etc/profile.d/nginx-path.sh >/dev/null
echo "应用系统配置..."
sudo systemctl daemon-reload
source /etc/profile
echo "启用并启动Nginx服务..."
sudo systemctl enable --now nginx
echo -e "\n操作完成！请验证服务状态："
systemctl status nginx

# . 系统清理
echo "正在清理无用缓存和旧软件包..."
sudo apt autoremove -y
sudo apt autoclean

echo "------------------------------------------------"
echo "SSH 版本: $(ssh -V 2>&1)"
echo "SSH 端口: $NEW_PORT"
echo "Nginx 版本: $NGINX_VER"
echo "请记住：下次登录请使用新端口: $NEW_PORT"
echo "当前虚拟内存状态："
free -m
