#!/bin/bash

# ============================================
# Hysteria2 服务器安装与配置脚本
# 版本：2.0
# 功能：交互式配置 Hysteria2 服务器
# ============================================

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 默认值
DEFAULT_PORT="1553"
DEFAULT_BANDWIDTH_UP="100"
DEFAULT_BANDWIDTH_DOWN="100"
DEFAULT_TLS_CERT="/usr/local/nginx/certs/flare.maya.locker/fullchain.cer"
DEFAULT_TLS_KEY="/usr/local/nginx/certs/flare.maya.locker/cert.key"
DEFAULT_MASQUERADE_URL="https://flare.maya.locker/"

# 函数：显示标题
show_header() {
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}      Hysteria2 服务器配置工具${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo ""
}

# 函数：生成随机密码
generate_random_password() {
    local length="${1:-16}"
    # 生成包含数字、大小写字母的随机字符串
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

# 函数：验证端口号
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 函数：验证带宽值
validate_bandwidth() {
    local bandwidth="$1"
    if [[ "$bandwidth" =~ ^[0-9]+$ ]] && [ "$bandwidth" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# 函数：验证文件路径
validate_file_path() {
    local path="$1"
    local file_type="$2"
    
    if [ -z "$path" ]; then
        echo -e "${RED}错误: ${file_type}路径不能为空${NC}"
        return 1
    fi
    
    # 如果是证书文件，检查是否存在
    if [ "$file_type" = "证书" ] || [ "$file_type" = "私钥" ]; then
        if [ ! -f "$path" ]; then
            echo -e "${YELLOW}警告: ${file_type}文件不存在: $path${NC}"
            echo "请确保文件路径正确，或按Ctrl+C退出重新设置"
            read -p "是否继续？ (y/N): " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi
    
    return 0
}

# 函数：验证URL格式
validate_url() {
    local url="$1"
    if [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(/.*)?$ ]]; then
        return 0
    else
        return 1
    fi
}

# 函数：显示配置摘要
show_config_summary() {
    echo ""
    echo -e "${PURPLE}══════════════════════════════════════════${NC}"
    echo -e "${PURPLE}           配置摘要${NC}"
    echo -e "${PURPLE}══════════════════════════════════════════${NC}"
    echo ""
    echo -e "${GREEN}基本配置:${NC}"
    echo "  - 监听端口: $LISTEN_PORT"
    echo ""
    echo -e "${GREEN}TLS证书:${NC}"
    echo "  - 证书文件: $TLS_CERT"
    echo "  - 私钥文件: $TLS_KEY"
    echo ""
    echo -e "${GREEN}混淆设置:${NC}"
    echo "  - 类型: salamander"
    echo "  - 密码: $OBFS_PASSWORD"
    echo ""
    echo -e "${GREEN}认证设置:${NC}"
    echo "  - 类型: password"
    echo "  - 密码: $AUTH_PASSWORD"
    echo ""
    echo -e "${GREEN}带宽限制:${NC}"
    echo "  - 上行: $BANDWIDTH_UP mbps"
    echo "  - 下行: $BANDWIDTH_DOWN mbps"
    echo ""
    echo -e "${GREEN}伪装设置:${NC}"
    echo "  - 类型: proxy"
    echo "  - URL: $MASQUERADE_URL"
    echo "  - 重写主机头: 是"
    echo "  - 不验证证书: 否"
    echo ""
    echo -e "${PURPLE}══════════════════════════════════════════${NC}"
}

# 函数：显示最终配置内容
show_final_config() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}       Hysteria2 配置文件内容${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo ""
    echo "配置文件位置: /etc/hysteria/config.yaml"
    echo ""
    echo "----------------------------------------"
    cat /etc/hysteria/config.yaml
    echo "----------------------------------------"
    echo ""
}

# 函数：保存重要信息到文件
save_credentials() {
    local save_file="/root/hysteria2_credentials.txt"
    
    cat > "$save_file" << EOF
# Hysteria2 服务器配置信息
# 生成时间: $(date)
# 服务器地址: $(curl -s ifconfig.me)
# 监听端口: $LISTEN_PORT

## 重要：请妥善保存以下信息 ##

1. 混淆密码 (Obfs Password):
   $OBFS_PASSWORD

2. 认证密码 (Auth Password):
   $AUTH_PASSWORD

3. 连接配置示例:
   - 服务器: $(curl -s ifconfig.me):$LISTEN_PORT
   - 混淆类型: salamander
   - 混淆密码: $OBFS_PASSWORD
   - 认证密码: $AUTH_PASSWORD
   - 传输协议: UDP
   - TLS: 启用

4. 证书文件:
   - 证书: $TLS_CERT
   - 私钥: $TLS_KEY

5. 伪装网站:
   - URL: $MASQUERADE_URL

6. 带宽限制:
   - 上行: $BANDWIDTH_UP mbps
   - 下行: $BANDWIDTH_DOWN mbps

EOF
    
    chmod 600 "$save_file"
    echo -e "${GREEN}✓ 配置信息已保存到: $save_file${NC}"
    echo -e "${YELLOW}注意: 此文件包含敏感信息，请妥善保管！${NC}"
}

# 主脚本开始
set -e

# 显示标题
show_header

# 步骤1：安装 Hysteria2
echo -e "${BLUE}[1/6] 安装 Hysteria2...${NC}"
echo -e "${YELLOW}正在安装 Hysteria2，请稍候...${NC}"
bash <(curl -fsSL https://get.hy2.sh/) || {
    echo -e "${RED}错误: Hysteria2 安装失败${NC}"
    exit 1
}
echo -e "${GREEN}✓ Hysteria2 安装完成${NC}"
echo ""

# 步骤2：生成随机密码
echo -e "${BLUE}[2/6] 生成随机密码...${NC}"
OBFS_PASSWORD=$(generate_random_password 16)
AUTH_PASSWORD=$(generate_random_password 16)
echo -e "${GREEN}✓ 混淆密码已生成: ${OBFS_PASSWORD}${NC}"
echo -e "${GREEN}✓ 认证密码已生成: ${AUTH_PASSWORD}${NC}"
echo ""

# 步骤3：获取用户输入
echo -e "${BLUE}[3/6] 配置参数输入${NC}"
echo -e "${YELLOW}请按提示输入配置参数，或按Enter使用默认值${NC}"
echo ""

# 3.1 监听端口
read -p "请输入监听端口 [默认: $DEFAULT_PORT]: " USER_PORT
if [ -n "$USER_PORT" ]; then
    while ! validate_port "$USER_PORT"; do
        echo -e "${RED}错误: 端口号必须在 1-65535 之间${NC}"
        read -p "请重新输入监听端口: " USER_PORT
    done
    LISTEN_PORT="$USER_PORT"
else
    LISTEN_PORT="$DEFAULT_PORT"
fi
echo -e "${GREEN}✓ 监听端口: $LISTEN_PORT${NC}"
echo ""

# 3.2 TLS证书路径
echo -e "${CYAN}TLS证书配置:${NC}"
read -p "请输入证书文件路径 [默认: $DEFAULT_TLS_CERT]: " USER_TLS_CERT
if [ -z "$USER_TLS_CERT" ]; then
    USER_TLS_CERT="$DEFAULT_TLS_CERT"
fi
while ! validate_file_path "$USER_TLS_CERT" "证书"; do
    read -p "请重新输入证书文件路径: " USER_TLS_CERT
done
TLS_CERT="$USER_TLS_CERT"
echo -e "${GREEN}✓ 证书文件: $TLS_CERT${NC}"

read -p "请输入私钥文件路径 [默认: $DEFAULT_TLS_KEY]: " USER_TLS_KEY
if [ -z "$USER_TLS_KEY" ]; then
    USER_TLS_KEY="$DEFAULT_TLS_KEY"
fi
while ! validate_file_path "$USER_TLS_KEY" "私钥"; do
    read -p "请重新输入私钥文件路径: " USER_TLS_KEY
done
TLS_KEY="$USER_TLS_KEY"
echo -e "${GREEN}✓ 私钥文件: $TLS_KEY${NC}"
echo ""

# 3.3 带宽限制
echo -e "${CYAN}带宽限制配置:${NC}"
read -p "请输入上行带宽 (Mbps) [默认: $DEFAULT_BANDWIDTH_UP]: " USER_BANDWIDTH_UP
if [ -n "$USER_BANDWIDTH_UP" ]; then
    while ! validate_bandwidth "$USER_BANDWIDTH_UP"; do
        echo -e "${RED}错误: 带宽值必须是大于0的数字${NC}"
        read -p "请重新输入上行带宽 (Mbps): " USER_BANDWIDTH_UP
    done
    BANDWIDTH_UP="$USER_BANDWIDTH_UP"
else
    BANDWIDTH_UP="$DEFAULT_BANDWIDTH_UP"
fi
echo -e "${GREEN}✓ 上行带宽: ${BANDWIDTH_UP} Mbps${NC}"

read -p "请输入下行带宽 (Mbps) [默认: $DEFAULT_BANDWIDTH_DOWN]: " USER_BANDWIDTH_DOWN
if [ -n "$USER_BANDWIDTH_DOWN" ]; then
    while ! validate_bandwidth "$USER_BANDWIDTH_DOWN"; do
        echo -e "${RED}错误: 带宽值必须是大于0的数字${NC}"
        read -p "请重新输入下行带宽 (Mbps): " USER_BANDWIDTH_DOWN
    done
    BANDWIDTH_DOWN="$USER_BANDWIDTH_DOWN"
else
    BANDWIDTH_DOWN="$DEFAULT_BANDWIDTH_DOWN"
fi
echo -e "${GREEN}✓ 下行带宽: ${BANDWIDTH_DOWN} Mbps${NC}"
echo ""

# 3.4 伪装URL
echo -e "${CYAN}伪装网站配置:${NC}"
read -p "请输入伪装网站URL [默认: $DEFAULT_MASQUERADE_URL]: " USER_MASQUERADE_URL
if [ -z "$USER_MASQUERADE_URL" ]; then
    USER_MASQUERADE_URL="$DEFAULT_MASQUERADE_URL"
fi
while ! validate_url "$USER_MASQUERADE_URL"; do
    echo -e "${RED}错误: URL格式不正确，应以 http:// 或 https:// 开头${NC}"
    read -p "请重新输入伪装网站URL: " USER_MASQUERADE_URL
done
MASQUERADE_URL="$USER_MASQUERADE_URL"
echo -e "${GREEN}✓ 伪装网站URL: $MASQUERADE_URL${NC}"
echo ""

# 显示配置摘要
show_config_summary

# 确认配置
read -p "是否确认以上配置并继续？ (y/N): " CONFIRM_CONFIG
if [[ ! "$CONFIRM_CONFIG" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}配置已取消${NC}"
    exit 0
fi

# 步骤4：创建配置文件
echo -e "${BLUE}[4/6] 创建配置文件...${NC}"
rm -f /etc/hysteria/config.yaml
cat > /etc/hysteria/config.yaml << EOF
listen: :${LISTEN_PORT}

tls:
  cert: ${TLS_CERT}
  key: ${TLS_KEY}

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASSWORD}

auth:
  type: password
  password: ${AUTH_PASSWORD}

bandwidth:
  up: ${BANDWIDTH_UP} mbps
  down: ${BANDWIDTH_DOWN} mbps

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true
    insecure: false

EOF

# 验证配置文件
if [ -f "/etc/hysteria/config.yaml" ]; then
    echo -e "${GREEN}✓ 配置文件已创建${NC}"
    # 显示配置文件权限
    ls -la /etc/hysteria/config.yaml
else
    echo -e "${RED}✗ 配置文件创建失败${NC}"
    exit 1
fi
echo ""

# 步骤5：启动服务
echo -e "${BLUE}[5/6] 启动 Hysteria2 服务...${NC}"
systemctl enable --now hysteria-server.service 2>/dev/null || true
sudo systemctl daemon-reload

# 尝试启动服务
if systemctl restart hysteria-server.service; then
    echo -e "${GREEN}✓ Hysteria2 服务启动成功${NC}"
    
    # 检查服务状态
    sleep 2
    echo ""
    echo -e "${CYAN}服务状态检查:${NC}"
    systemctl status hysteria-server.service --no-pager -l
else
    echo -e "${RED}✗ Hysteria2 服务启动失败${NC}"
    echo -e "${YELLOW}请检查配置文件是否正确${NC}"
    exit 1
fi
echo ""

# 步骤6：显示最终结果
echo -e "${BLUE}[6/6] 安装完成${NC}"
echo ""

# 显示最终配置内容
show_final_config

# 保存重要信息到文件
save_credentials

# 显示防火墙提示
echo -e "${CYAN}防火墙配置提示:${NC}"
echo "如果启用了防火墙，请确保开放端口 $LISTEN_PORT"
echo "Ubuntu (UFW): sudo ufw allow $LISTEN_PORT/udp"
echo "Firewalld: sudo firewall-cmd --permanent --add-port=$LISTEN_PORT/udp"
echo "           sudo firewall-cmd --reload"
echo ""

# 显示客户端配置示例
echo -e "${CYAN}客户端连接配置示例:${NC}"
echo "以下是 Hysteria2 客户端的配置示例:"
echo ""
echo "server: $(curl -s ifconfig.me):$LISTEN_PORT"
echo "auth: $AUTH_PASSWORD"
echo "tls:"
echo "  sni: $(hostname)"
echo "  insecure: false"
echo "obfs:"
echo "  type: salamander"
echo "  salamander:"
echo "    password: $OBFS_PASSWORD"
echo "bandwidth:"
echo "  up: ${BANDWIDTH_UP} mbps"
echo "  down: ${BANDWIDTH_DOWN} mbps"
echo ""

echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}      Hysteria2 服务器配置完成！${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
