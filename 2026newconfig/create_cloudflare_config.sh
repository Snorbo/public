#!/bin/bash

# ============================================
# 创建 Cloudflare API 配置文件脚本
# 作者：Auto-generated
# 版本：1.0
# ============================================

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 脚本信息
SCRIPT_NAME="create_cloudflare_config.sh"
CONFIG_FILE="cloudflare.int"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="$SCRIPT_DIR/$CONFIG_FILE"

# 显示标题
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Cloudflare API 配置文件生成工具${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 函数：检查文件是否存在
check_existing_file() {
    if [ -f "$CONFIG_PATH" ]; then
        echo -e "${YELLOW}警告: 文件 $CONFIG_FILE 已存在！${NC}"
        echo -e "现有文件内容:"
        echo "----------------------------------------"
        cat "$CONFIG_PATH"
        echo "----------------------------------------"
        read -p "是否要覆盖此文件？ (y/N): " OVERWRITE
        
        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            echo -e "${RED}操作已取消。${NC}"
            exit 1
        fi
        echo ""
    fi
}

# 函数：验证邮箱格式
validate_email() {
    local EMAIL="$1"
    if [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 函数：验证 API Key 格式
validate_api_key() {
    local API_KEY="$1"
    # Cloudflare API Key 通常是 37 或 40 个字符的十六进制字符串
    if [[ "$API_KEY" =~ ^[a-fA-F0-9]{37,40}$ ]]; then
        return 0
    else
        return 1
    fi
}

# 函数：显示帮助信息
show_help() {
    echo "使用方法:"
    echo "  $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo "  -q, --quiet    安静模式，不显示额外信息"
    echo "  -e, --email    直接在命令行指定邮箱"
    echo "  -k, --key      直接在命令行指定 API Key"
    echo ""
    echo "示例:"
    echo "  $0 --email cloudflare@example.com --key 0123456789abcdef0123456789abcdef01234"
    echo ""
}

# 解析命令行参数
QUIET_MODE=false
USER_EMAIL=""
USER_API_KEY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -q|--quiet)
            QUIET_MODE=true
            shift
            ;;
        -e|--email)
            USER_EMAIL="$2"
            shift 2
            ;;
        -k|--key)
            USER_API_KEY="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}错误: 未知参数: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# 如果不是安静模式，显示信息
if [ "$QUIET_MODE" = false ]; then
    echo -e "${GREEN}此脚本将帮助您创建 Cloudflare API 配置文件。${NC}"
    echo -e "${GREEN}文件将被保存在: $CONFIG_PATH${NC}"
    echo ""
fi

# 检查是否已存在同名文件
check_existing_file

# 获取 Cloudflare 邮箱
echo -e "${BLUE}步骤 1/2: 输入 Cloudflare 邮箱${NC}"
if [ -n "$USER_EMAIL" ]; then
    EMAIL="$USER_EMAIL"
    echo -e "${GREEN}使用命令行提供的邮箱: $EMAIL${NC}"
else
    while true; do
        read -p "请输入 Cloudflare 邮箱地址: " EMAIL
        
        if [ -z "$EMAIL" ]; then
            echo -e "${RED}邮箱地址不能为空！${NC}"
            continue
        fi
        
        if validate_email "$EMAIL"; then
            break
        else
            echo -e "${RED}邮箱格式无效！请重新输入。${NC}"
        fi
    done
fi
echo ""

# 获取 Cloudflare API Key
echo -e "${BLUE}步骤 2/2: 输入 Cloudflare API Key${NC}"
if [ -n "$USER_API_KEY" ]; then
    API_KEY="$USER_API_KEY"
    echo -e "${GREEN}使用命令行提供的 API Key${NC}"
else
    while true; do
        echo -e "${YELLOW}提示: 输入时不会显示字符${NC}"
        read -sp "请输入 Cloudflare API Key: " API_KEY
        echo ""
        
        if [ -z "$API_KEY" ]; then
            echo -e "${RED}API Key 不能为空！${NC}"
            continue
        fi
        
        # 确认 API Key
        read -sp "请再次输入 API Key 进行确认: " API_KEY_CONFIRM
        echo ""
        
        if [ "$API_KEY" != "$API_KEY_CONFIRM" ]; then
            echo -e "${RED}两次输入的 API Key 不一致！${NC}"
            continue
        fi
        
        if validate_api_key "$API_KEY"; then
            break
        else
            echo -e "${YELLOW}警告: API Key 格式看起来不标准，是否继续？ (y/N): ${NC}" 
            read -p "" CONTINUE
            if [[ "$CONTINUE" =~ ^[Yy]$ ]]; then
                break
            fi
        fi
    done
fi
echo ""

# 创建配置文件
echo -e "${BLUE}正在创建配置文件...${NC}"
cat > "$CONFIG_PATH" << EOF
# Cloudflare API credentials used by Certbot
# 此文件由脚本自动生成于 $(date)
# 注意：请妥善保管此文件，不要泄露给他人

dns_cloudflare_email = $EMAIL
dns_cloudflare_api_key = $API_KEY
EOF

# 设置文件权限（仅所有者可读写）
chmod 600 "$CONFIG_PATH"

# 验证文件是否创建成功
if [ -f "$CONFIG_PATH" ]; then
    echo -e "${GREEN}✓ 配置文件创建成功！${NC}"
    echo ""
    
    # 显示文件位置
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}配置文件位置:${NC}"
    echo -e "$CONFIG_PATH"
    echo ""
    
    # 显示文件内容（隐藏部分API Key以增加安全性）
    echo -e "${GREEN}配置文件内容:${NC}"
    echo "----------------------------------------"
    
    # 显示邮箱完整内容，但只显示API Key的前5位和最后5位
    EMAIL_LINE=$(grep "dns_cloudflare_email" "$CONFIG_PATH")
    KEY_LINE=$(grep "dns_cloudflare_api_key" "$CONFIG_PATH")
    
    echo "$EMAIL_LINE"
    
    # 安全地显示API Key
    API_KEY_VALUE=$(echo "$KEY_LINE" | cut -d'=' -f2 | xargs)
    if [ ${#API_KEY_VALUE} -gt 10 ]; then
        KEY_PREFIX="${API_KEY_VALUE:0:5}"
        KEY_SUFFIX="${API_KEY_VALUE: -5}"
        KEY_MIDDLE="***"
        echo "dns_cloudflare_api_key = $KEY_PREFIX$KEY_MIDDLE$KEY_SUFFIX"
    else
        echo "$KEY_LINE"
    fi
    
    echo "----------------------------------------"
    echo ""
    
    # 显示使用说明
    echo -e "${BLUE}使用说明:${NC}"
    echo "1. 在使用 Certbot 申请证书时，可以这样引用此文件:"
    echo -e "   ${YELLOW}certbot certonly --dns-cloudflare \\${NC}"
    echo -e "   ${YELLOW}  --dns-cloudflare-credentials $CONFIG_PATH \\${NC}"
    echo -e "   ${YELLOW}  -d example.com -d *.example.com${NC}"
    echo ""
    echo "2. 安全建议:"
    echo "   - 将此文件保存在安全位置"
    echo "   - 不要将此文件提交到版本控制系统"
    echo "   - 定期轮换 API Key"
    
    # 显示文件权限信息
    echo ""
    echo -e "${BLUE}文件权限:${NC}"
    ls -la "$CONFIG_PATH"
    
    # 检查是否安装了 certbot-dns-cloudflare
    echo ""
    echo -e "${BLUE}依赖检查:${NC}"
    if command -v certbot &> /dev/null; then
        echo -e "${GREEN}✓ Certbot 已安装${NC}"
        
        # 检查是否有 cloudflare 插件
        if certbot plugins | grep -q cloudflare; then
            echo -e "${GREEN}✓ Certbot Cloudflare 插件已安装${NC}"
        else
            echo -e "${YELLOW}⚠ Certbot Cloudflare 插件未安装${NC}"
            echo "  可以通过以下命令安装:"
            echo "  sudo apt install python3-certbot-dns-cloudflare"
        fi
    else
        echo -e "${YELLOW}⚠ Certbot 未安装${NC}"
        echo "  可以通过以下命令安装:"
        echo "  sudo apt install certbot python3-certbot-dns-cloudflare"
    fi
    
else
    echo -e "${RED}✗ 配置文件创建失败！${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}脚本执行完成！${NC}"
