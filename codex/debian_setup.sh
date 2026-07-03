#!/usr/bin/env bash
# ============================================================================
# Debian/Ubuntu Server Initialization Script
# 多合一服务器初始化脚本 —— 分步可选，自动回滚
# ============================================================================
# 用法：
#   chmod +x debian_setup.sh
#   sudo ./debian_setup.sh               # 使用菜单交互
#   sudo ./debian_setup.sh --all          # 全部执行（非交互）
#   sudo ./debian_setup.sh --step 1,3,5   # 仅执行指定步骤
# ============================================================================

set -o errexit
set -o pipefail
set -o nounset

# ─── 颜色 ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step_header() { echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"; }

# ─── 工作区 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="/tmp/debian_setup_backup_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${BACKUP_DIR}/setup.log"
ROLLBACK_FILE="${BACKUP_DIR}/rollback.sh"
EXECUTED_STEPS_FILE="${BACKUP_DIR}/executed_steps.txt"
mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE" "$ROLLBACK_FILE" "$EXECUTED_STEPS_FILE"

# ─── 步骤状态管理 ──────────────────────────────────────────────────────────
step_mark_executed() { echo "$1" >> "$EXECUTED_STEPS_FILE"; }
step_was_executed()  { grep -qFx "$1" "$EXECUTED_STEPS_FILE" 2>/dev/null; }

# ─── 安全助手函数 ──────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 身份运行。请使用 sudo。"
        exit 1
    fi
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
}

safe_run() {
    local desc="$1"
    shift
    log "执行：$desc ($*)"
    if "$@" >> "$LOG_FILE" 2>&1; then
        log "√ 成功：$desc"
        return 0
    else
        local exit_code=$?
        warn "✗ 失败：$desc (退出码=$exit_code)"
        return $exit_code
    fi
}

require_run() {
    local desc="$1"
    shift
    if ! safe_run "$desc" "$@"; then
        error "关键步骤失败，退出。"
        exit 1
    fi
}

register_rollback() {
    echo "$*" >> "$ROLLBACK_FILE"
}

# ─── 步骤 1：系统更新 ────────────────────────────────────────────────────
step_system_update() {
    step_header "步骤 1/8：系统更新 (apt update & upgrade)"
    require_root

    if [[ -f /etc/apt/sources.list && ! -f "${BACKUP_DIR}/sources.list.bak" ]]; then
        cp /etc/apt/sources.list "${BACKUP_DIR}/sources.list.bak"
        register_rollback "cp '${BACKUP_DIR}/sources.list.bak' /etc/apt/sources.list"
        log "已备份 /etc/apt/sources.list"
    fi

    require_run "apt update" apt-get update
    require_run "apt upgrade -y" apt-get upgrade -y
    require_run "apt dist-upgrade -y" apt-get dist-upgrade -y
    safe_run "清理孤立依赖" apt-get autoremove -y

    step_mark_executed "system_update"
    info "系统更新完成。"
}

# ─── 步骤 2：安装常用包 ─────────────────────────────────────────────────
step_install_packages() {
    step_header "步骤 2/8：安装常用软件包"
    require_root

    local base_pkgs=(
        curl wget git vim nano htop
        ca-certificates gnupg gnupg2 lsb-release
        software-properties-common apt-transport-https
        net-tools iproute2 dnsutils traceroute mtr
        tcpdump nmap netcat-openbsd socat
        iperf3 jq python3 python3-pip
        openssl xxd zip unzip p7zip-full
        bc uuid-runtime dmidecode
        build-essential autoconf automake libtool
        psmisc lsof sysstat dstat
        ufw iptables
    )

    local all_pkgs=("${base_pkgs[@]}")

    log "需要安装的包：${all_pkgs[*]}"
    require_run "apt update (安装前)" apt-get update

    local failed_pkgs=()
    for pkg in "${all_pkgs[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            log "  已安装，跳过：$pkg"
        else
            if safe_run "安装 $pkg" apt-get install -y "$pkg"; then
                true
            else
                failed_pkgs+=("$pkg")
            fi
        fi
    done

    if [[ ${#failed_pkgs[@]} -gt 0 ]]; then
        warn "以下软件包首次安装失败，重试：${failed_pkgs[*]}"
        safe_run "apt --fix-missing" apt-get --fix-missing install -y "${failed_pkgs[@]}" || {
            warn "仍有包安装失败，但将继续执行：${failed_pkgs[*]}"
        }
    fi

    step_mark_executed "install_packages"
    info "软件包安装步骤完成。"
}

# ─── 步骤 3：安装 BBR ───────────────────────────────────────────────────
step_install_bbr() {
    step_header "步骤 3/8：安装 BBR 拥塞控制算法"
    require_root

    local bbr_script="${BACKUP_DIR}/bbr.sh"
    require_run "下载 BBR 脚本" wget -q -O "$bbr_script" \
        "https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/2026newconfig/bbr.sh"

    safe_run "赋予执行权限" chmod +x "$bbr_script"

    if [[ -f /etc/sysctl.conf && ! -f "${BACKUP_DIR}/sysctl.conf.bak" ]]; then
        cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.bak"
        register_rollback "cp '${BACKUP_DIR}/sysctl.conf.bak' /etc/sysctl.conf"
    fi

    if safe_run "执行 BBR 脚本" bash "$bbr_script" 1; then
        info "BBR 安装/配置完成。"
    else
        warn "BBR 脚本执行返回非零，尝试手动开启 BBR…"
        {
            echo "net.core.default_qdisc=fq"
            echo "net.ipv4.tcp_congestion_control=bbr"
        } >> /etc/sysctl.conf 2>/dev/null || true
        safe_run "sysctl -p (手动 BBR)" sysctl -p || true
    fi

    local bbr_active
    bbr_active=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}') || bbr_active="unknown"
    if lsmod 2>/dev/null | grep -q tcp_bbr; then
        info "√ BBR 模块已加载，当前拥塞控制算法：$bbr_active"
    else
        warn "BBR 模块未加载，可能需要重启后生效。当前算法：$bbr_active"
    fi

    step_mark_executed "install_bbr"
    info "BBR 安装步骤完成。"
}

# ─── 步骤 4：安装 NextTrace ─────────────────────────────────────────────
step_install_nexttrace() {
    step_header "步骤 4/8：安装 NextTrace (路由追踪工具)"
    require_root

    if safe_run "安装 NextTrace" bash -c "$(curl -sL nxtrace.org/nt)"; then
        info "NextTrace 安装成功。"
    else
        warn "官方安装方式失败，尝试备选方案…"
        local arch
        arch=$(uname -m)
        case "$arch" in
            x86_64)  arch="amd64" ;;
            aarch64) arch="arm64" ;;
            *)       arch="amd64" ;;
        esac
        local nt_url
        nt_url=$(curl -sL "https://api.github.com/repos/nxtrace/NTrace-core/releases/latest" \
            | grep "browser_download_url.*linux_${arch}" \
            | grep -v "sig" | head -1 | cut -d '"' -f 4) || nt_url=""
        if [[ -n "$nt_url" ]]; then
            local nt_bin="/usr/local/bin/nexttrace"
            safe_run "下载 NextTrace 二进制" wget -q -O "$nt_bin" "$nt_url"
            safe_run "赋予执行权限" chmod +x "$nt_bin"
            info "NextTrace 已通过备选方式安装"
        else
            warn "无法获取 NextTrace。可稍后手动安装。"
        fi
    fi

    step_mark_executed "install_nexttrace"
    info "NextTrace 安装步骤完成。"
}

# ─── 步骤 5：修改 SSH 端口 ──────────────────────────────────────────────
step_change_ssh_port() {
    step_header "步骤 5/8：修改 SSH 连接端口"
    require_root

    if [[ ! -f /etc/ssh/sshd_config ]]; then
        error "未找到 /etc/ssh/sshd_config"
        return 1
    fi

    local current_port
    current_port=$(grep -E '^Port\s+' /etc/ssh/sshd_config | awk '{print $2}') || current_port="22"
    echo -e "当前 SSH 端口：${YELLOW}${current_port}${NC}"

    local new_port
    if [[ -z "${SSH_PORT:-}" ]]; then
        read -r -p "请输入新的 SSH 端口号 (1-65535，留空则不修改): " new_port
        new_port="${new_port:-}"
    else
        new_port="$SSH_PORT"
        info "使用环境变量 SSH_PORT=$new_port"
    fi

    if [[ -z "$new_port" ]]; then
        info "跳过 SSH 端口修改。"; return 0
    fi

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 ]] || [[ "$new_port" -gt 65535 ]]; then
        error "无效端口号：$new_port"; return 1
    fi

    if [[ "$new_port" -eq "$current_port" ]]; then
        info "端口已经是 $new_port，无需修改。"; return 0
    fi

    cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak"
    register_rollback "cp '${BACKUP_DIR}/sshd_config.bak' /etc/ssh/sshd_config"
    register_rollback "systemctl restart sshd || service ssh restart || true"
    log "已备份 sshd_config"

    sed -i 's/^Port\s\+.*/Port was: &\n# Modified by debian_setup.sh/' /etc/ssh/sshd_config
    echo "Port $new_port" >> /etc/ssh/sshd_config
    log "SSH 端口已从 $current_port 修改为 $new_port"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        safe_run "UFW 放行新端口" ufw allow "$new_port/tcp"
        safe_run "UFW 放行新端口(完整)" ufw allow "$new_port"
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        safe_run "firewalld 放行" firewall-cmd --permanent --add-port="${new_port}/tcp"
        safe_run "firewalld 重载" firewall-cmd --reload
    fi

    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
    info "SSH 服务已重启，新端口：$new_port"

    echo -e "${YELLOW}⚠ 保持当前会话，另开终端测试：ssh -p $new_port user@host${NC}"
    read -r -p "确认新端口连接正常？(yes/NO): " confirm
    if [[ "$confirm" != "yes" ]]; then
        warn "回滚 SSH 端口…"
        cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        error "已回滚。"; return 1
    fi

    step_mark_executed "change_ssh_port"
    info "SSH 端口已更改为 $new_port。"
}

# ─── 步骤 6：SSH 密钥配置 ───────────────────────────────────────────────
step_ssh_key_config() {
    step_header "步骤 6/8：禁用密码登录，配置 SSH 密钥登录"
    require_root

    local sshd_config="/etc/ssh/sshd_config"
    if [[ ! -f "$sshd_config" ]]; then
        error "未找到 $sshd_config"; return 1
    fi

    if [[ ! -f "${BACKUP_DIR}/sshd_config.bak" ]]; then
        cp "$sshd_config" "${BACKUP_DIR}/sshd_config.bak"
        register_rollback "cp '${BACKUP_DIR}/sshd_config.bak' '$sshd_config'"
        register_rollback "systemctl restart sshd || service ssh restart || true"
    fi

    local ssh_key="${SSH_PUBKEY:-}"
    if [[ -z "$ssh_key" ]]; then
        echo -e "${YELLOW}请在下方粘贴您的 SSH 公钥 (以 EOF 结束)：${NC}"
        echo "（直接回车跳过）"
        ssh_key=""
        while IFS= read -r line; do
            if [[ "$line" == "EOF" ]]; then break; fi
            if [[ -z "$line" && -z "$ssh_key" ]]; then break; fi
            ssh_key+="$line"$'\n'
        done
        ssh_key="$(echo -e "$ssh_key" | sed '/^$/d')"
    else
        info "使用环境变量 SSH_PUBKEY。"
    fi

    if [[ -n "$ssh_key" ]]; then
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        echo "$ssh_key" >> /root/.ssh/authorized_keys
        sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
            local user_home
            user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6) || user_home="/home/$SUDO_USER"
            if [[ -n "$user_home" ]]; then
                mkdir -p "$user_home/.ssh"; chmod 700 "$user_home/.ssh"
                echo "$ssh_key" >> "$user_home/.ssh/authorized_keys"
                sort -u "$user_home/.ssh/authorized_keys" -o "$user_home/.ssh/authorized_keys"
                chmod 600 "$user_home/.ssh/authorized_keys"
                chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$user_home/.ssh" 2>/dev/null || true
            fi
        fi
        info "SSH 公钥已添加。"
    else
        info "未提供 SSH 公钥，跳过。"
    fi

    local disable_pw="${SSH_DISABLE_PASSWORD:-}"
    if [[ -z "$disable_pw" ]]; then
        read -r -p "禁用 SSH 密码登录？(yes/NO): " disable_pw
        disable_pw="${disable_pw:-no}"
    fi

    if [[ "${disable_pw,,}" == "yes" || "${disable_pw,,}" == "y" ]]; then
        local key_count
        key_count=$(wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo 0)
        if [[ "$key_count" -eq 0 ]]; then
            warn "未检测到 SSH 公钥！可能把自己锁在外面！"
            read -r -p "仍然继续？(yes/NO): " force_disable
            if [[ "${force_disable,,}" != "yes" ]]; then
                info "取消。"; return 0
            fi
        fi

        sed -i 's/^#\?PasswordAuthentication\s\+.*/PasswordAuthentication no/' "$sshd_config"
        grep -q '^PasswordAuthentication no' "$sshd_config" || echo 'PasswordAuthentication no' >> "$sshd_config"
        sed -i 's/^#\?ChallengeResponseAuthentication\s\+.*/ChallengeResponseAuthentication no/' "$sshd_config"
        grep -q '^ChallengeResponseAuthentication no' "$sshd_config" || echo 'ChallengeResponseAuthentication no' >> "$sshd_config"
        sed -i 's/^#\?PubkeyAuthentication\s\+.*/PubkeyAuthentication yes/' "$sshd_config"
        grep -q '^PubkeyAuthentication yes' "$sshd_config" || echo 'PubkeyAuthentication yes' >> "$sshd_config"
        sed -i 's/^#\?PermitEmptyPasswords\s\+.*/PermitEmptyPasswords no/' "$sshd_config"

        log "已配置：密码登录禁用，密钥登录启用。"
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        info "SSH 已重启。"

        echo -e "${YELLOW}⚠ 保持当前会话，另开终端测试密钥登录。${NC}"
        read -r -p "确认密钥登录正常？(yes/NO): " confirm_key
        if [[ "$confirm_key" != "yes" ]]; then
            warn "回滚 SSH 配置…"
            cp "${BACKUP_DIR}/sshd_config.bak" "$sshd_config"
            systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
            error "已回滚。"; return 1
        fi
    else
        info "跳过禁用密码登录。"
    fi

    step_mark_executed "ssh_key_config"
    info "SSH 密钥配置步骤完成。"
}

# ─── 步骤 7：禁止 IPQS ─────────────────────────────────────────────────
step_block_ipqs() {
    step_header "步骤 7/8：禁止 IPQS"
    require_root

    local hosts_file="/etc/hosts"
    local ipqs_entries=(
        "127.0.0.1 ipqualityscore.com"
        "127.0.0.1 www.ipqualityscore.com"
        "127.0.0.1 api.ipqualityscore.com"
    )

    if [[ ! -f "${BACKUP_DIR}/hosts.bak" ]]; then
        cp "$hosts_file" "${BACKUP_DIR}/hosts.bak"
        register_rollback "cp '${BACKUP_DIR}/hosts.bak' '$hosts_file'"
    fi

    local added=0
    for entry in "${ipqs_entries[@]}"; do
        if grep -qF "$entry" "$hosts_file" 2>/dev/null; then
            log "  已存在：$entry"
        else
            echo "$entry" >> "$hosts_file"
            log "  已添加：$entry"
            ((added++))
        fi
    done

    info "IPQS 域名屏蔽完成（新增 $added 条）。"
    step_mark_executed "block_ipqs"
}

# ─── 步骤 8：解除 53 端口占用 ──────────────────────────────────────────
step_release_port53() {
    step_header "步骤 8/8：解除 53 端口占用"
    require_root

    local resolved_conf="/etc/systemd/resolved.conf"
    [[ -f "$resolved_conf" ]] || touch "$resolved_conf"

    if [[ ! -f "${BACKUP_DIR}/resolved.conf.bak" ]]; then
        cp "$resolved_conf" "${BACKUP_DIR}/resolved.conf.bak"
        register_rollback "cp '${BACKUP_DIR}/resolved.conf.bak' '$resolved_conf'"
        register_rollback "systemctl restart systemd-resolved || true"
    fi

    if grep -q '^\[Resolve\]' "$resolved_conf" 2>/dev/null; then
        grep -q '^DNS=' "$resolved_conf" && sed -i 's/^DNS=.*/DNS=8.8.8.8 1.1.1.1/' "$resolved_conf" \
            || sed -i '/^\[Resolve\]/a DNS=8.8.8.8 1.1.1.1' "$resolved_conf"
        grep -q '^DNSStubListener=' "$resolved_conf" && sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' "$resolved_conf" \
            || sed -i '/^\[Resolve\]/a DNSStubListener=no' "$resolved_conf"
    else
        cat >> "$resolved_conf" <<- 'EOL'

        [Resolve]
        DNS=8.8.8.8 1.1.1.1
        DNSStubListener=no
        EOL
    fi

    log "已配置 resolved.conf"

    local resolv_link="/etc/resolv.conf"
    [[ -L "$resolv_link" ]] || cp "$resolv_link" "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || true
    safe_run "创建软链接" ln -sf /run/systemd/resolve/resolv.conf "$resolv_link"
    safe_run "重启 systemd-resolved" systemctl restart systemd-resolved

    echo ""
    info "验证 53 端口："
    if command -v lsof &>/dev/null; then
        lsof -i :53 2>/dev/null || echo "  (无进程监听 53)"
    else
        ss -tlnp 2>/dev/null | grep ':53 ' || echo "  (无进程监听 53)"
    fi

    echo ""
    info "测试 DNS 解析："
    safe_run "DNS 测试" nslookup google.com 8.8.8.8 2>/dev/null || \
        safe_run "DNS 测试(备选)" dig +short google.com @8.8.8.8 2>/dev/null || \
        warn "DNS 解析测试失败。"

    step_mark_executed "release_port53"
    info "53 端口配置完成。"
}

# ─── 清理 ────────────────────────────────────────────────────────────────────
step_cleanup() {
    step_header "清理临时文件与缓存"

    safe_run "apt clean" apt-get clean
    safe_run "apt autoremove" apt-get autoremove -y
    safe_run "apt autoclean" apt-get autoclean
    safe_run "pip3 缓存清理" pip3 cache purge 2>/dev/null || true
    safe_run "删除 BBR 临时脚本" rm -f "${BACKUP_DIR}/bbr.sh" 2>/dev/null || true

    log "清理完成。备份保留在：$BACKUP_DIR"
    local size
    size=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}') || size="N/A"
    info "备份大小：$size"
    step_mark_executed "cleanup"
}

# ─── 全局回滚 ────────────────────────────────────────────────────────────────
step_global_rollback() {
    step_header "执行全局回滚"
    require_root

    if [[ ! -f "$ROLLBACK_FILE" ]]; then
        info "无回滚记录。"; return 0
    fi

    local count
    count=$(wc -l < "$ROLLBACK_FILE")
    [[ "$count" -eq 0 ]] && { info "无回滚操作。"; return 0; }

    warn "执行 $count 条回滚操作…"
    tac "$ROLLBACK_FILE" | while IFS= read -r cmd; do
        [[ -n "$cmd" ]] && safe_run "回滚: $cmd" bash -c "$cmd"
    done

    rm -f "$EXECUTED_STEPS_FILE"
    info "回滚完成。"
}

# ─── 菜单 ────────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Debian/Ubuntu 服务器初始化脚本${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo "请选择要执行的步骤（逗号分隔，如 1,2,3）："
    echo ""
    echo "  1)  系统更新 (apt update & upgrade)"
    echo "  2)  安装常用软件包"
    echo "  3)  安装 BBR 拥塞控制"
    echo "  4)  安装 NextTrace"
    echo "  5)  修改 SSH 端口"
    echo "  6)  配置 SSH 密钥（禁用密码登录）"
    echo "  7)  禁止 IPQS 域名"
    echo "  8)  解除 53 端口占用"
    echo "  a)  全部执行"
    echo "  r)  回滚所有变更"
    echo "  q)  退出"
    echo ""
    echo -e "  可使用环境变量跳过交互："
    echo -e "    ${GREEN}SSH_PORT=2222 SSH_PUBKEY=\"ssh-ed25519 AAAA...\" SSH_DISABLE_PASSWORD=yes${NC}"
    echo ""
    echo -e "  静默模式：${GREEN}sudo ./debian_setup.sh --all${NC}"
    echo -e "  指定步骤：${GREEN}sudo ./debian_setup.sh --step 1,2,3${NC}"
    echo ""
}

# ─── 主流程 ──────────────────────────────────────────────────────────────────
main() {
    require_root

    local run_all=false
    local selected_steps=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)       run_all=true; shift ;;
            --step)      selected_steps="${2:-}"; shift 2 ;;
            --rollback)  step_global_rollback; exit 0 ;;
            -h|--help)   show_menu; exit 0 ;;
            *)           error "未知参数：$1"; exit 1 ;;
        esac
    done

    if [[ "$run_all" == true ]]; then
        log "非交互模式：全部步骤"
        step_system_update
        step_install_packages
        step_install_bbr
        step_install_nexttrace
        step_change_ssh_port
        step_ssh_key_config
        step_block_ipqs
        step_release_port53
        step_cleanup
        info "全部完成！备份：$BACKUP_DIR"
        return 0
    fi

    if [[ -n "$selected_steps" ]]; then
        log "非交互模式：步骤 $selected_steps"
        IFS=',' read -ra steps <<< "$selected_steps"
        for s in "${steps[@]}"; do
            s="$(echo "$s" | xargs)"
            case "$s" in
                1) step_system_update ;;
                2) step_install_packages ;;
                3) step_install_bbr ;;
                4) step_install_nexttrace ;;
                5) step_change_ssh_port ;;
                6) step_ssh_key_config ;;
                7) step_block_ipqs ;;
                8) step_release_port53 ;;
                *) warn "跳过未知步骤：$s" ;;
            esac
        done
        step_cleanup
        info "完成！备份：$BACKUP_DIR"
        return 0
    fi

    show_menu
    read -r -p "请选择 [1-8,a,r,q]: " choice
    echo ""

    case "$choice" in
        a|A) main --all ;;
        r|R) step_global_rollback ;;
        q|Q) info "退出。"; exit 0 ;;
        *)
            IFS=',; ' read -ra selections <<< "$choice"
            for sel in "${selections[@]}"; do
                sel="$(echo "$sel" | xargs)"
                case "$sel" in
                    1) step_system_update ;;
                    2) step_install_packages ;;
                    3) step_install_bbr ;;
                    4) step_install_nexttrace ;;
                    5) step_change_ssh_port ;;
                    6) step_ssh_key_config ;;
                    7) step_block_ipqs ;;
                    8) step_release_port53 ;;
                    *) warn "跳过未知：$sel" ;;
                esac
            done
            step_cleanup
            info "完成！备份：$BACKUP_DIR"
            ;;
    esac
}

main "$@"
