#!/bin/bash
set -e
echo -e "\033[34m[1/4] 安装hysteria2...\033[0m"
bash <(curl -fsSL https://get.hy2.sh/)
echo -e "\033[34m[2/4] 配置hysteria2...\033[0m"
rm /etc/hysteria/config.yaml 
sudo tee /etc/hysteria/config.yaml <<'EOF'
listen: :1553

tls:
  cert: /usr/local/nginx/certs/source.maya.locker/fullchain.cer
  key: /usr/local/nginx/certs/source.maya.locker/cert.key

obfs:
  type: salamander
  salamander:
    password: uc0jSOnoq57
auth:
  type: password
  password: ifQ4MdK9FEt

bandwidth:
  up: 1 gbps
  down: 1 gbps

masquerade:
  type: proxy
  proxy:
    url: https://source.maya.locker/
    rewriteHost: true
    insecure: false

EOF
echo -e "\033[34m[3/4] 启动hysteria2...\033[0m"
systemctl enable --now hysteria-server.service
sudo systemctl daemon-reload
systemctl restart hysteria-server.service
echo -e "\033[34m[4/4] 完成安装...\033[0m"
