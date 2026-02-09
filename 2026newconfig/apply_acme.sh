#!/bin/bash

# ============================================
# Certbot + Cloudflare DNS 证书申请工具
# 版本：1.0
# 功能：交互式申请Let's Encrypt通配符证书
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
DEFAULT_CREDENTIALS_PATH="/root/cloudflare.int"
DEFAULT_PROPAGATION_SECONDS="60"
DEFAULT_KEY_TYPE="ecdsa"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="2.0"

# 显示标题
echo -e "${CYAN}══════════════════════════════════════════${NC}"
echo -e "${CYAN}   Certbot + Cloudflare 证书申请工具${NC}"
echo -e "${CYAN}══════════════════════════════════════════${NC}"
echo ""

# 函数：显示帮助信息
show_help() {
    echo -e "${GREEN}使用方法:${NC}"
    echo "  $SCRIPT_NAME [选项]"
    echo ""
    echo -e "${GREEN}选项:${NC}"
    echo "  -h, --help                显示此帮助信息"
    echo "  -v, --version             显示版本信息"
    echo "  -c, --credentials FILE    指定Cloudflare凭证文件路径"
    echo "  -d, --domain DOMAIN       指定主域名（支持通配符）"
    echo "  -p, --propagation SECONDS 设置DNS传播等待时间（默认: 60）"
    echo "  -k, --key-type TYPE       设置密钥类型（默认: ecdsa）"
    echo "  --dry-run                 模拟运行，不实际申请证书"
    echo ""
    echo -e "${GREEN}示例:${NC}"
    echo "  $SCRIPT_NAME -c /root/cloudflare.int -d *.example.com"
    echo "  $SCRIPT_NAME --domain example.com --propagation 30"
    echo ""
    echo -e "${YELLOW}注意:${NC}"
    echo "  1. 需要提前安装 certbot 和 python3-certbot-dns-cloudflare"
    echo "  2. Cloudflare API凭证文件需要提前配置好"
    echo "  3. 脚本需要sudo权限执行"
    exit 0
}

# 函数：显示版本信息
show_version() {
    echo -e "${GREEN}$SCRIPT_NAME${NC} 版本 $SCRIPT_VERSION"
    echo "支持 Let's Encrypt 通配符证书申请"
    exit 0
}

# 函数：检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}错误: 未找到 $1 命令${NC}"
        echo "请使用以下命令安装:"
        echo "  sudo apt update && sudo apt install $2"
        exit 1
    fi
}

# 函数：验证文件是否存在
check_file_exists() {
    if [ ! -f "$1" ]; then
        echo -e "${RED}错误: 文件不存在: $1${NC}"
        return 1
    fi
    return 0
}

# 函数：验证域名格式
validate_domain() {
    local DOMAIN="$1"
    
    # 移除通配符前缀进行验证
    local DOMAIN_TO_CHECK="${DOMAIN#\*\.}"
    
    # 基本域名格式验证
    if [[ ! "$DOMAIN_TO_CHECK" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        echo -e "${RED}错误: 域名格式无效: $DOMAIN${NC}"
        return 1
    fi
    
    # 检查是否包含顶级域名
    if [[ ! "$DOMAIN_TO_CHECK" =~ \.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}错误: 域名需要包含有效的顶级域名: $DOMAIN${NC}"
        return 1
    fi
    
    return 0
}

# 函数：检查DNS记录是否已存在
check_dns_record() {
    local DOMAIN="$1"
    local SUBDOMAIN="${DOMAIN%%.*}"
    local BASEDOMAIN="${DOMAIN#*.}"
    
    # 如果是通配符域名，检查_acme-challenge记录
    if [[ "$DOMAIN" == \*\.* ]]; then
        echo -e "${BLUE}正在检查DNS记录 _acme-challenge.$BASEDOMAIN ...${NC}"
        if dig TXT "_acme-challenge.$BASEDOMAIN" +short | grep -q "acme"; then
            echo -e "${YELLOW}警告: 发现已存在的_acme-challenge记录${NC}"
            echo "这可能影响证书申请，建议清理后再继续。"
            read -p "是否继续？ (y/N): " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi
    
    return 0
}

# 函数：显示证书信息
show_certificate_info() {
    local CERT_PATH="/etc/letsencrypt/live/$1"
    
    if [ -f "$CERT_PATH/fullchain.pem" ]; then
        echo -e "${GREEN}证书信息:${NC}"
        echo "----------------------------------------"
        openssl x509 -in "$CERT_PATH/fullchain.pem" -text -noout | grep -E "(Subject:|Issuer:|Not Before:|Not After :|DNS:)"
        echo "----------------------------------------"
    fi
}

# 解析命令行参数
CREDENTIALS_PATH=""
DOMAIN=""
PROPAGATION_SECONDS="$DEFAULT_PROPAGATION_SECONDS"
KEY_TYPE="$DEFAULT_KEY_TYPE"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -v|--version)
            show_version
            ;;
        -c|--credentials)
            CREDENTIALS_PATH="$2"
            shift 2
            ;;
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -p|--propagation)
            PROPAGATION_SECONDS="$2"
            shift 2
            ;;
        -k|--key-type)
            KEY_TYPE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo -e "${RED}错误: 未知参数: $1${NC}"
            show_help
            ;;
    esac
done

# 检查必要的命令
check_command "certbot" "certbot"
check_command "dig" "dnsutils"

# 显示欢迎信息
echo -e "${GREEN}欢迎使用 Certbot 证书申请工具${NC}"
echo "此工具将引导您申请 Let's Encrypt 通配符证书"
echo ""

# 步骤1：获取Cloudflare凭证文件路径
echo -e "${CYAN}步骤 1/5: Cloudflare API凭证${NC}"
if [ -z "$CREDENTIALS_PATH" ]; then
    echo -e "默认路径: ${YELLOW}$DEFAULT_CREDENTIALS_PATH${NC}"
    read -p "请输入凭证文件路径 [按Enter使用默认值]: " USER_CREDENTIALS
    
    if [ -z "$USER_CREDENTIALS" ]; then
        CREDENTIALS_PATH="$DEFAULT_CREDENTIALS_PATH"
    else
        CREDENTIALS_PATH="$USER_CREDENTIALS"
    fi
fi

# 验证凭证文件
while ! check_file_exists "$CREDENTIALS_PATH"; do
    echo -e "${YELLOW}凭证文件不存在，请重新输入${NC}"
    read -p "请输入凭证文件路径: " CREDENTIALS_PATH
done

echo -e "${GREEN}✓ 凭证文件: ${CREDENTIALS_PATH}${NC}"
echo ""

# 步骤2：获取域名
echo -e "${CYAN}步骤 2/5: 域名配置${NC}"
if [ -z "$DOMAIN" ]; then
    read -p "请输入主域名 (例如: example.com 或 *.example.com): " USER_DOMAIN
    
    if [ -z "$USER_DOMAIN" ]; then
        echo -e "${RED}错误: 域名不能为空${NC}"
        exit 1
    fi
    DOMAIN="$USER_DOMAIN"
fi

# 验证域名
while ! validate_domain "$DOMAIN"; do
    read -p "请重新输入域名: " DOMAIN
done

echo -e "${GREEN}✓ 主域名: ${DOMAIN}${NC}"

# 自动确定要申请的域名列表
echo -e "${BLUE}自动配置申请的域名...${NC}"
DOMAINS_ARRAY=()

# 添加用户输入的域名
DOMAINS_ARRAY+=("$DOMAIN")

# 如果输入的是通配符域名，添加对应的根域名
if [[ "$DOMAIN" == \*\.* ]]; then
    BASEDOMAIN="${DOMAIN#*.}"
    if [[ ! " ${DOMAINS_ARRAY[@]} " =~ " $BASEDOMAIN " ]]; then
        DOMAINS_ARRAY+=("$BASEDOMAIN")
        echo -e "${GREEN}✓ 自动添加根域名: ${BASEDOMAIN}${NC}"
    fi
fi

# 询问是否添加其他域名
while true; do
    echo ""
    echo -e "${YELLOW}是否要添加其他域名？${NC}"
    echo "  1) 添加子域名 (如: www.example.com)"
    echo "  2) 添加其他域名"
    echo "  3) 完成域名配置"
    read -p "请选择 [1-3]: " DOMAIN_OPTION
    
    case $DOMAIN_OPTION in
        1)
            if [[ "$DOMAIN" == \*\.* ]]; then
                BASEDOMAIN="${DOMAIN#*.}"
            else
                BASEDOMAIN="$DOMAIN"
            fi
            read -p "请输入子域名前缀 (如: www, mail, blog): " SUBDOMAIN
            FULL_DOMAIN="${SUBDOMAIN}.${BASEDOMAIN}"
            if validate_domain "$FULL_DOMAIN"; then
                DOMAINS_ARRAY+=("$FULL_DOMAIN")
                echo -e "${GREEN}✓ 添加子域名: ${FULL_DOMAIN}${NC}"
            fi
            ;;
        2)
            read -p "请输入要添加的域名: " NEW_DOMAIN
            if validate_domain "$NEW_DOMAIN"; then
                DOMAINS_ARRAY+=("$NEW_DOMAIN")
                echo -e "${GREEN}✓ 添加域名: ${NEW_DOMAIN}${NC}"
            fi
            ;;
        3)
            break
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            ;;
    esac
done

echo ""
echo -e "${GREEN}将申请以下域名的证书:${NC}"
for DOMAIN_ITEM in "${DOMAINS_ARRAY[@]}"; do
    echo "  - $DOMAIN_ITEM"
done
echo ""

# 步骤3：检查DNS记录
echo -e "${CYAN}步骤 3/5: DNS记录检查${NC}"
for DOMAIN_ITEM in "${DOMAINS_ARRAY[@]}"; do
    if ! check_dns_record "$DOMAIN_ITEM"; then
        echo -e "${RED}DNS检查失败${NC}"
        exit 1
    fi
done
echo -e "${GREEN}✓ DNS记录检查通过${NC}"
echo ""

# 步骤4：配置高级选项
echo -e "${CYAN}步骤 4/5: 高级选项${NC}"

# DNS传播等待时间
read -p "DNS传播等待时间 (秒) [默认: $PROPAGATION_SECONDS]: " USER_PROPAGATION
if [ -n "$USER_PROPAGATION" ]; then
    PROPAGATION_SECONDS="$USER_PROPAGATION"
fi
echo -e "${GREEN}✓ 传播等待时间: ${PROPAGATION_SECONDS}秒${NC}"

# 密钥类型
read -p "密钥类型 [rsa/ecdsa, 默认: $KEY_TYPE]: " USER_KEY_TYPE
if [ -n "$USER_KEY_TYPE" ]; then
    KEY_TYPE="$USER_KEY_TYPE"
fi
echo -e "${GREEN}✓ 密钥类型: ${KEY_TYPE}${NC}"

# 是否使用dry-run模式
if [ "$DRY_RUN" = false ]; then
    read -p "是否先进行模拟运行 (dry-run)？ (y/N): " DO_DRY_RUN
    if [[ "$DO_DRY_RUN" =~ ^[Yy]$ ]]; then
        DRY_RUN=true
        echo -e "${YELLOW}⚠ 将进行模拟运行${NC}"
    fi
fi
echo ""

# 步骤5：生成并执行命令
echo -e "${CYAN}步骤 5/5: 生成证书申请命令${NC}"

# 构建命令
CERTBOT_CMD="sudo certbot certonly"
CERTBOT_CMD="$CERTBOT_CMD --dns-cloudflare"
CERTBOT_CMD="$CERTBOT_CMD --dns-cloudflare-credentials $CREDENTIALS_PATH"
CERTBOT_CMD="$CERTBOT_CMD --dns-cloudflare-propagation-seconds $PROPAGATION_SECONDS"
CERTBOT_CMD="$CERTBOT_CMD --key-type $KEY_TYPE"

# 添加所有域名
for DOMAIN_ITEM in "${DOMAINS_ARRAY[@]}"; do
    CERTBOT_CMD="$CERTBOT_CMD -d $DOMAIN_ITEM"
done

# 添加dry-run参数
if [ "$DRY_RUN" = true ]; then
    CERTBOT_CMD="$CERTBOT_CMD --dry-run"
fi

# 显示最终命令
echo -e "${PURPLE}生成的命令:${NC}"
echo "$CERTBOT_CMD"
echo ""

# 确认执行
if [ "$DRY_RUN" = false ]; then
    read -p "是否确认执行证书申请？ (y/N): " CONFIRM_EXECUTE
    
    if [[ "$CONFIRM_EXECUTE" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${GREEN}开始执行证书申请...${NC}"
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo ""
        
        # 执行命令
        eval "$CERTBOT_CMD"
        
        # 检查执行结果
        if [ $? -eq 0 ]; then
            echo ""
            echo -e "${CYAN}══════════════════════════════════════════${NC}"
            echo -e "${GREEN}✓ 证书申请成功！${NC}"
            echo ""
            
            # 显示证书信息
            if [[ "$DOMAIN" == \*\.* ]]; then
                BASEDOMAIN="${DOMAIN#*.}"
                show_certificate_info "$BASEDOMAIN"
            else
                show_certificate_info "$DOMAIN"
            fi
            
            echo ""
            echo -e "${GREEN}证书文件位置:${NC}"
            if [[ "$DOMAIN" == \*\.* ]]; then
                BASEDOMAIN="${DOMAIN#*.}"
                CERT_DIR="/etc/letsencrypt/live/$BASEDOMAIN"
            else
                CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
            fi
            
            if [ -d "$CERT_DIR" ]; then
                echo "  - 证书文件: $CERT_DIR/fullchain.pem"
                echo "  - 私钥文件: $CERT_DIR/privkey.pem"
                echo "  - 证书链: $CERT_DIR/chain.pem"
                echo "  - 完整证书: $CERT_DIR/cert.pem"
            fi
            
            echo ""
            echo -e "${YELLOW}后续操作建议:${NC}"
            echo "  1. 配置Web服务器使用新证书"
            echo "  2. 设置证书自动续期: sudo certbot renew --dry-run"
            echo "  3. 测试SSL配置: https://www.ssllabs.com/ssltest/"
            
        else
            echo ""
            echo -e "${RED}✗ 证书申请失败${NC}"
            echo "请检查以下内容:"
            echo "  1. Cloudflare API凭证是否正确"
            echo "  2. 域名DNS解析是否正常"
            echo "  3. 防火墙是否允许访问"
            exit 1
        fi
    else
        echo -e "${YELLOW}已取消执行${NC}"
        echo ""
        echo -e "${GREEN}您可以手动运行以下命令:${NC}"
        echo "$CERTBOT_CMD"
    fi
else
    echo -e "${YELLOW}模拟运行模式，不实际申请证书${NC}"
    echo ""
    echo -e "${GREEN}执行模拟运行...${NC}"
    echo ""
    
    # 执行dry-run
    eval "$CERTBOT_CMD"
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ 模拟运行成功！${NC}"
        echo "模拟运行通过，可以正式申请证书了。"
        echo ""
        echo -e "${YELLOW}正式申请命令:${NC}"
        echo "${CERTBOT_CMD/--dry-run/}"
    fi
fi

echo ""
echo -e "${CYAN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}脚本执行完成${NC}"
