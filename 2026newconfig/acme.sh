#!/bin/bash
set -e

# 获取用户输入的域名和邮箱
echo -e "\033[36m请配置SSL证书信息\033[0m"
echo "======================================"

# 输入域名，设置默认值
read -rp "请输入域名 [默认: flare.maya.locker]: " USER_DOMAIN
DOMAIN="${USER_DOMAIN:-flare.maya.locker}"

# 输入邮箱，设置默认值
read -rp "请输入邮箱地址 [默认: email.snorbo@gmail.com]: " USER_EMAIL
EMAIL="${USER_EMAIL:-email.snorbo@gmail.com}"

# 显示确认信息
echo -e "\n\033[33m配置确认：\033[0m"
echo "域名: $DOMAIN"
echo "邮箱: $EMAIL"
read -rp "确认配置是否正确？[Y/n]: " CONFIRM

# 检查确认
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    echo -e "\033[31m配置已取消\033[0m"
    exit 1
fi

# 定义路径（基于用户输入的域名）
NGINX_CONF="/usr/local/nginx/conf/nginx.conf"
CERT_DIR="/usr/local/nginx/certs/${DOMAIN}"

echo -e "\n\033[34m正在安装依赖工具...\033[0m"
sudo apt-get install -y curl socat >/dev/null

echo -e "\n\033[34m安装acme.sh证书工具...\033[0m"
curl https://get.acme.sh | sh -s email="${EMAIL}" >/dev/null

echo -e "\n\033[34m设置环境变量...\033[0m"
export PATH="$HOME/.acme.sh:$PATH"
echo 'export PATH="$HOME/.acme.sh:$PATH"' | sudo tee /etc/profile.d/acme.sh >/dev/null
source /etc/profile

echo -e "\n\033[34m申请SSL证书（使用DNS验证）...\033[0m"
acme.sh --issue -d "${DOMAIN}" --nginx "${NGINX_CONF}" --force --debug 2 || {
    echo -e "\n\033[31m证书申请失败，请检查以下可能的原因：\033[0m"
    echo "1. 域名解析是否正确（确保 ${DOMAIN} 指向本机IP）"
    echo "2. 80端口是否开放（防火墙设置）"
    echo "3. Nginx配置中是否包含 server_name ${DOMAIN}"
    echo "4. 查看详细错误日志: sudo journalctl -u nginx --no-pager -n 50"
    exit 1
}

echo -e "\n\033[34m创建证书存储目录...\033[0m"
sudo mkdir -p "${CERT_DIR}" >/dev/null

echo -e "\n\033[34m安装证书文件...\033[0m"
acme.sh --install-cert -d "${DOMAIN}" \
        --key-file "${CERT_DIR}/cert.key" \
        --fullchain-file "${CERT_DIR}/fullchain.cer" \
        --reloadcmd "systemctl restart nginx"

echo -e "\n\033[34m设置证书权限...\033[0m"
sudo chmod 755 /usr/local/nginx/certs
sudo chmod 0604 "${CERT_DIR}/cert.key"
sudo chmod 0644 "${CERT_DIR}/fullchain.cer"

echo -e "\n\033[34m重新加载服务配置...\033[0m"
sudo systemctl daemon-reload
sudo systemctl restart nginx

echo -e "\n\033[32mSSL证书配置成功完成！\033[0m"
echo "======================================"
echo "域名: $DOMAIN"
echo "邮箱: $EMAIL"
echo "证书位置: $CERT_DIR"
echo "======================================"
echo -e "\n\033[33m验证命令：\033[0m"
echo "1. 检查证书文件: sudo ls -l ${CERT_DIR}"
echo "2. 测试HTTPS访问: curl -I https://${DOMAIN}"
echo "3. 检查证书有效期: openssl x509 -in ${CERT_DIR}/fullchain.cer -text -noout | grep 'Not'"
echo "4. 检查Nginx状态: sudo systemctl status nginx"
