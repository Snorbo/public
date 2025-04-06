#!/bin/bash
set -e
echo -e "\033[34m[1/4] 安装hysteria2...\033[0m"
bash <(curl -fsSL https://get.hy2.sh/)
echo -e "\033[34m[2/4] 配置hysteria2...\033[0m"
rm /etc/hysteria/config.yaml 
sudo tee /etc/hysteria/config.yaml <<'EOF'
listen: 127.0.0.1:1553

tls:
  cert: /usr/local/nginx/certs/cloud.ffe.quest/fullchain.cer
  key: /usr/local/nginx/certs/cloud.ffe.quest/cert.key

obfs:
  type: salamander 
  salamander:
    password: Q?Gu1T7Xy=v@w8

auth:
  type: password
  password: g^INO37i@Ub:v2

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 25165824
  maxConnReceiveWindow: 25165824
  maxIdleTimeout: 30s
  maxDatagramFrameSize: 1492
bandwidth:
  up: 1 gbps
  down: 1 gbps

ignoreClientBandwidth: false
speedTest: false
disableUDP: false

udpIdleTimeout: 30s

masquerade:
  type: proxy
  proxy:
    url: https://cloud.ffe.quest/
    rewriteHost: true
    insecure: false
EOF
echo -e "\033[34m[3/4] 启动hysteria2...\033[0m"
systemctl enable --now hysteria-server.service
sudo systemctl daemon-reload
systemctl restart hysteria-server.service
echo -e "\033[34m[4/4] 完成安装...\033[0m"
