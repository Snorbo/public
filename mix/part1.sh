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


# --- BBR v3 全自动安装模块 ---
cd /root
echo -e "\033[36m正在启动 BBR v3 自动安装程序...\033[0m"

# 1. 确保必要依赖 (jq 是解析 GitHub API 的关键)
sudo apt-get update && sudo apt-get install -y jq curl wget dpkg

# 2. 自动检测架构并获取最新版下载链接
ARCH=$(uname -m)
BASE_URL="https://api.github.com/repos/byJoey/Actions-bbr-v3/releases"
RELEASE_DATA=$(curl -s "$BASE_URL")

if [[ "$ARCH" == "aarch64" ]]; then
    TAG_NAME=$(echo "$RELEASE_DATA" | jq -r 'sort_by(.published_at) | reverse | .[] | select(.tag_name | contains("arm64")) | .tag_name' | head -n1)
elif [[ "$ARCH" == "x86_64" ]]; then
    TAG_NAME=$(echo "$RELEASE_DATA" | jq -r 'sort_by(.published_at) | reverse | .[] | select(.tag_name | contains("x86_64")) | .tag_name' | head -n1)
fi

if [[ -z "$TAG_NAME" ]]; then
    echo "未找到匹配架构的内核，跳过 BBR 安装。"
else
    # 3. 执行静默下载
    ASSET_URLS=$(echo "$RELEASE_DATA" | jq -r --arg tag "$TAG_NAME" '.[] | select(.tag_name == $tag) | .assets[].browser_download_url')
    for URL in $ASSET_URLS; do
        wget -q --show-progress "$URL" -P /tmp/
    done

    # 4. 强制安装并配置参数
    echo "安装内核并配置 BBR+FQ..."
    sudo dpkg -i /tmp/linux-*.deb
    sudo update-grub

    # 直接写入永久配置，无需询问
    SYSCTL_CONF="/etc/sysctl.d/99-joeyblog.conf"
    echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" | sudo tee "$SYSCTL_CONF" > /dev/null
    
fi

echo "------------------------------------------------"
echo "SSH 版本: $(ssh -V 2>&1)"
echo "SSH 端口: $NEW_PORT"
echo "Nginx 版本: $NGINX_VER"
echo "请记住：下次登录请使用新端口: $NEW_PORT"
echo -e "\033[32mBBR v3 安装完成，请手动重启...\033[0m"
echo "当前虚拟内存状态："
free -m

