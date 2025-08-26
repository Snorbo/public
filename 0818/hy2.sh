#!/bin/bash
set -e
echo -e "\033[34m[1/4] 安装hysteria2...\033[0m"
bash <(curl -fsSL https://get.hy2.sh/)
echo -e "\033[34m[2/4] 配置hysteria2...\033[0m"
rm /etc/hysteria/config.yaml 
sudo tee /etc/hysteria/config.yaml <<'EOF'
listen: :1553

tls:
  cert: /usr/local/nginx/certs/doh.knauf.quest/fullchain.cer
  key: /usr/local/nginx/certs/doh.knauf.quest/cert.key

obfs:
  type: salamander 
  salamander:
    password: rpxMG1O5Ua
auth:
  type: password
  password: dVgZ1NWt8w

bandwidth:
  up: 1000 mbps
  down: 1000 mbps

masquerade:
  type: proxy
  proxy:
    url: https://doh.knauf.quest/
    rewriteHost: true
    insecure: false
EOF
echo -e "\033[34m[3/4] 启动hysteria2...\033[0m"
systemctl enable --now hysteria-server.service
sudo systemctl daemon-reload
systemctl restart hysteria-server.service
echo -e "\033[34m[4/4] 完成安装...\033[0m"
