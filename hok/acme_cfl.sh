#!/bin/bash
set -e

DOMAIN="cloud.flare.maya.locker"
EMAIL="email.snorbo@gmail.com"
NGINX_CONF="/usr/local/nginx/conf/nginx.conf"
CERT_DIR="/usr/local/nginx/certs/${DOMAIN}"

echo -e "\033[34m正在安装依赖工具...\033[0m"
sudo apt-get install -y curl socat >/dev/null

echo -e "\n\033[34m安装acme.sh证书工具...\033[0m"
curl https://get.acme.sh | sh -s email="${EMAIL}" >/dev/null

echo -e "\n\033[34m设置环境变量...\033[0m"
export PATH="$HOME/.acme.sh:$PATH"
echo 'export PATH="$HOME/.acme.sh:$PATH"' | sudo tee /etc/profile.d/acme.sh >/dev/null
source /etc/profile

echo -e "\n\033[34m申请SSL证书（使用DNS验证）...\033[0m"
acme.sh --issue -d "${DOMAIN}" --nginx "${NGINX_CONF}" --force --debug 2 || {
    echo -e "\033[31m证书申请失败，请检查：\033[0m"
    echo "1. 域名解析是否正确"
    echo "2. 80端口是否开放"
    echo "3. Nginx配置是否包含server_name ${DOMAIN}"
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

echo -e "\n\033[32m操作成功完成！验证命令：\033[0m"
echo "curl -I https://${DOMAIN}"
echo "sudo ls -l ${CERT_DIR}"
