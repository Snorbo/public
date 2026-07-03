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
        log "OK 成功：$desc"
        return 0
    else
        local exit_code=$?
        warn "FAIL 失败：$desc (退出码=$exit_code)"
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

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 1：系统信息查询
# ═══════════════════════════════════════════════════════════════════════════════
step_sysinfo() {
    step_header "步骤 1/10：系统信息查询 (sysinfo)"

    log "正在采集系统信息…"
    local public_ip="" ipv4_address="" ipv6_address="" isp_info="" country="" city=""

    local ipinfo_json
    ipinfo_json=$(curl -s --max-time 3 https://ipinfo.io 2>/dev/null) || ipinfo_json=""
    if [[ -n "$ipinfo_json" ]]; then
        country=$(echo "$ipinfo_json" | grep '"country"' | awk -F': "' '{print $2}' | tr -d '",')
        city=$(echo "$ipinfo_json" | grep '"city"' | awk -F': "' '{print $2}' | tr -d '",')
        isp_info=$(echo "$ipinfo_json" | grep '"org"' | awk -F': "' '{print $2}' | tr -d '",')
        public_ip=$(echo "$ipinfo_json" | grep '"ip"' | awk -F': "' '{print $2}' | tr -d '",')
    fi

    if echo "$isp_info" | grep -Eiq 'CHINANET|mobile|unicom|telecom'; then
        ipv4_address=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')
    else
        ipv4_address="$public_ip"
    fi
    ipv6_address=$(curl -s --max-time 2 https://v6.ipinfo.io/ip 2>/dev/null) || ipv6_address=""

    local rx_tx
    rx_tx=$(awk 'BEGIN{rx=0;tx=0} $1~/^(eth|ens|enp|eno)[0-9]+/{rx+=$2;tx+=$10} END{printf "%.0f %.0f", rx, tx}' /proc/net/dev 2>/dev/null)
    local rx_bytes=$(echo "$rx_tx" | awk '{print $1}') tx_bytes=$(echo "$rx_tx" | awk '{print $2}')
    hr() { local b=$1; if ((b>1073741824)); then echo "$(echo "scale=2; $b/1073741824" | bc)G"; elif ((b>1048576)); then echo "$(echo "scale=2; $b/1048576" | bc)M"; elif ((b>1024)); then echo "$(echo "scale=2; $b/1024" | bc)K"; else echo "${b}B"; fi; }
    local rx=$(hr "$rx_bytes") tx=$(hr "$tx_bytes")

    local cpu_info=$(lscpu 2>/dev/null | awk -F': +' '/Model name:/ {print $2; exit}') || cpu_info="?"
    local cpu_cores=$(nproc 2>/dev/null) || cpu_cores="?"
    local cpu_stat1=$(grep 'cpu ' /proc/stat 2>/dev/null) || cpu_stat1=""
    local cpu_usage="0"
    if [[ -n "$cpu_stat1" ]]; then
        sleep 1 2>/dev/null || true
        local cpu_stat2=$(grep 'cpu ' /proc/stat 2>/dev/null) || cpu_stat2=""
        [[ -n "$cpu_stat2" ]] && cpu_usage=$(awk '{u=$2+$4;t=$2+$4+$5;if(NR==1){u1=u;t1=t}else printf "%.1f\n",(($2+$4-u1)*100/(t-t1))}' <(echo "$cpu_stat1") <(echo "$cpu_stat2")) || cpu_usage="0"
    fi
    local cpu_freq=$(grep "MHz" /proc/cpuinfo 2>/dev/null | head -1 | awk '{printf "%.1f GHz\n", $4/1000}') || cpu_freq="?"
    local cpu_arch=$(uname -m)
    local mem_info=$(free -b 2>/dev/null | awk 'NR==2{printf "%.2f/%.2fM (%.1f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}') || mem_info="?"
    local swap_info=$(free -m 2>/dev/null | awk 'NR==3{used=$3;total=$2;if(total==0){p=0}else{p=used*100/total}; printf "%dM/%dM (%d%%)", used, total, p}') || swap_info="?"
    local disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}') || disk_info="?"
    local hostname=$(uname -n)
    local kernel_version=$(uname -r)
    local os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"') || os_info="?"
    local load=$(uptime 2>/dev/null | awk '{print $(NF-2), $(NF-1), $NF}') || load="?"
    local runtime=$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);if(d>0)printf "%d天 ",d;if(h>0)printf "%d时 ",h;printf "%d分"}' /proc/uptime 2>/dev/null) || runtime="?"
    local congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || congestion="?"
    local queue_alg=$(sysctl -n net.core.default_qdisc 2>/dev/null) || queue_alg="?"
    local dns_addrs=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null) || dns_addrs="?"
    local timezone=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}') || timezone=$(date +"%Z %z")
    local current_time=$(date "+%Y-%m-%d %I:%M %p")
    local tcp_count=$(ss -t 2>/dev/null | wc -l) || tcp_count="?"; local udp_count=$(ss -u 2>/dev/null | wc -l) || udp_count="?"

    clear
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}      系统信息查询${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}主机名:         ${NC}$hostname"
    echo -e "${CYAN}系统版本:       ${NC}$os_info"
    echo -e "${CYAN}Linux版本:      ${NC}$kernel_version"
    echo -e "${CYAN}CPU架构:        ${NC}$cpu_arch"
    echo -e "${CYAN}CPU型号:        ${NC}$cpu_info"
    echo -e "${CYAN}CPU核心数:      ${NC}$cpu_cores"
    echo -e "${CYAN}CPU频率:        ${NC}$cpu_freq"
    echo -e "${CYAN}CPU占用:        ${NC}${cpu_usage}%"
    echo -e "${CYAN}系统负载:       ${NC}$load"
    echo -e "${CYAN}TCP/UDP连接:    ${NC}${tcp_count}/${udp_count}"
    echo -e "${CYAN}物理内存:       ${NC}$mem_info"
    echo -e "${CYAN}虚拟内存:       ${NC}$swap_info"
    echo -e "${CYAN}硬盘占用:       ${NC}$disk_info"
    echo -e "${CYAN}总接收/总发送:  ${NC}$rx / $tx"
    echo -e "${CYAN}网络算法:       ${NC}$congestion $queue_alg"
    echo -e "${CYAN}运营商:         ${NC}${isp_info:-N/A}"
    echo -e "${CYAN}IPv4地址:       ${NC}${ipv4_address:-N/A}"
    echo -e "${CYAN}IPv6地址:       ${NC}${ipv6_address:-N/A}"
    echo -e "${CYAN}DNS地址:        ${NC}$dns_addrs"
    echo -e "${CYAN}地理位置:       ${NC}${country:-?} ${city:-?}"
    echo -e "${CYAN}时区/系统时间:  ${NC}$timezone $current_time"
    echo -e "${CYAN}运行时长:       ${NC}$runtime"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

    step_mark_executed "sysinfo"; info "系统信息已显示。"
}

# ─── 步骤 2：系统更新 ────────────────────────────────────────────────────
step_system_update() {
    step_header "步骤 2/10：系统更新 (apt update & upgrade)"
    require_root
    if [[ -f /etc/apt/sources.list && ! -f "${BACKUP_DIR}/sources.list.bak" ]]; then
        cp /etc/apt/sources.list "${BACKUP_DIR}/sources.list.bak"
        register_rollback "cp '${BACKUP_DIR}/sources.list.bak' /etc/apt/sources.list"
    fi
    require_run "apt update" apt-get update
    require_run "apt upgrade -y" apt-get upgrade -y
    require_run "apt dist-upgrade -y" apt-get dist-upgrade -y
    safe_run "孤立依赖清理" apt-get autoremove -y
    step_mark_executed "system_update"; info "系统更新完成。"
}

# ─── 步骤 3：安装常用包 ─────────────────────────────────────────────────
step_install_packages() {
    step_header "步骤 3/10：安装常用软件包"
    require_root
    local pkgs=(curl wget git vim nano htop ca-certificates gnupg gnupg2 lsb-release
        software-properties-common apt-transport-https net-tools iproute2 dnsutils
        traceroute mtr tcpdump nmap netcat-openbsd socat iperf3 jq python3 python3-pip
        openssl xxd zip unzip p7zip-full bc uuid-runtime dmidecode build-essential
        autoconf automake libtool psmisc lsof sysstat dstat ufw iptables)
    require_run "apt update (安装前)" apt-get update
    local failed=()
    for pkg in "${pkgs[@]}"; do
        dpkg -s "$pkg" &>/dev/null && log "  已安装：$pkg" || { safe_run "安装 $pkg" apt-get install -y "$pkg" || failed+=("$pkg"); }
    done
    [[ ${#failed[@]} -gt 0 ]] && safe_run "apt --fix-missing" apt-get --fix-missing install -y "${failed[@]}" || warn "仍有失败：${failed[*]}"
    step_mark_executed "install_packages"; info "软件包安装完成。"
}

# ─── 步骤 4：安装 BBR ───────────────────────────────────────────────────
step_install_bbr() {
    step_header "步骤 4/10：安装 BBR 拥塞控制算法"
    require_root
    local bbr_script="${BACKUP_DIR}/bbr.sh"
    require_run "下载 BBR 脚本" wget -q -O "$bbr_script" "https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/2026newconfig/bbr.sh"
    chmod +x "$bbr_script" 2>/dev/null || true
    [[ -f /etc/sysctl.conf && ! -f "${BACKUP_DIR}/sysctl.conf.bak" ]] && { cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.bak"; register_rollback "cp '${BACKUP_DIR}/sysctl.conf.bak' /etc/sysctl.conf"; }
    safe_run "执行 BBR 脚本" bash "$bbr_script" 1 || {
        warn "BBR 脚本异常，手动开启…"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf 2>/dev/null || true
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf 2>/dev/null || true
        sysctl -p 2>/dev/null || true
    }
    local bbr_active=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || bbr_active="?"
    lsmod 2>/dev/null | grep -q tcp_bbr && info "OK BBR 已加载（$bbr_active）" || warn "BBR 未加载，需重启。当前算法：$bbr_active"
    step_mark_executed "install_bbr"; info "BBR 安装完成。"
}

# ─── 步骤 5：安装 NextTrace ─────────────────────────────────────────────
step_install_nexttrace() {
    step_header "步骤 5/10：安装 NextTrace"
    require_root
    safe_run "安装 NextTrace" bash -c "$(curl -sL nxtrace.org/nt)" || {
        warn "官方安装失败，尝试备选…"
        local arch=$(uname -m); [[ "$arch" == "x86_64" ]] && arch="amd64"; [[ "$arch" == "aarch64" ]] && arch="arm64"
        local url=$(curl -sL "https://api.github.com/repos/nxtrace/NTrace-core/releases/latest" | grep "browser_download_url.*linux_${arch}" | grep -v "sig" | head -1 | cut -d '"' -f 4) || url=""
        [[ -n "$url" ]] && { wget -q -O /usr/local/bin/nexttrace "$url" && chmod +x /usr/local/bin/nexttrace; info "NextTrace 已安装"; } || warn "无法获取 NextTrace。"
    }
    step_mark_executed "install_nexttrace"; info "NextTrace 安装完成。"
}

# ─── 步骤 6：修改 SSH 端口 ──────────────────────────────────────────────
step_change_ssh_port() {
    step_header "步骤 6/10：修改 SSH 连接端口"
    require_root
    [[ ! -f /etc/ssh/sshd_config ]] && { error "未找到 /etc/ssh/sshd_config"; return 1; }

    local current_port=$(grep -E '^Port\s+[0-9]' /etc/ssh/sshd_config | tail -1 | awk '{print $2}')
    [[ "$current_port" =~ ^[0-9]+$ ]] || current_port="22"
    echo -e "当前 SSH 端口：${YELLOW}${current_port}${NC}"

    local new_port
    if [[ -z "${SSH_PORT:-}" ]]; then
        read -r -p "请输入新的 SSH 端口号 (1-65535，留空则不修改): " new_port
        new_port="${new_port:-}"
    else
        new_port="$SSH_PORT"; info "使用环境变量 SSH_PORT=$new_port"
    fi
    [[ -z "$new_port" ]] && { info "跳过。"; return 0; }
    [[ "$new_port" =~ ^[0-9]+$ ]] || { error "无效端口。"; return 1; }
    (( new_port >= 1 && new_port <= 65535 )) || { error "端口范围 1-65535。"; return 1; }
    [[ "$new_port" -eq "$current_port" ]] && { info "未变更。"; return 0; }

    if ss -tlnp 2>/dev/null | grep -q ":${new_port} "; then
        warn "端口 $new_port 已被占用:"; ss -tlnp 2>/dev/null | grep ":${new_port} "
        read -r -p "仍然继续？(yes/NO): " fp; [[ "${fp,,}" != "yes" ]] && { info "已取消。"; return 1; }
    fi

    cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak"
    register_rollback "cp '${BACKUP_DIR}/sshd_config.bak' /etc/ssh/sshd_config"
    register_rollback "systemctl restart sshd || service ssh restart || true"
    log "已备份 sshd_config"

    sed -i "s/^Port\s\+[0-9].*/Port $new_port/" /etc/ssh/sshd_config
    grep -q "^Port $new_port" /etc/ssh/sshd_config || echo "Port $new_port" >> /etc/ssh/sshd_config
    log "SSH 端口 $current_port -> $new_port"

    # ── 防火墙放行（不依赖退出码，以规则真实存在为准）──
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$new_port/tcp" 2>/dev/null || true
        ufw status 2>/dev/null | grep -q "$new_port" && info "UFW 已放行 $new_port/tcp" || warn "UFW 规则可能未生效，请手动检查。"
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall-cmd --permanent --add-port="${new_port}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        firewall-cmd --list-ports 2>/dev/null | grep -q "$new_port" && info "firewalld 已放行 $new_port/tcp" || warn "firewalld 规则可能未生效。"
    fi
    if command -v iptables &>/dev/null; then
        local dp=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}' | tr -d '()')
        [[ "$dp" == "DROP" || "$dp" == "REJECT" ]] && { iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true; info "已添加 iptables 放行规则。"; }
    fi

    # ── 重启 SSH ──────────────────────────────────────────────
    command -v sshd &>/dev/null && ! sshd -t 2>/dev/null && { error "sshd_config 语法错误，回滚。"; cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config; return 1; }
    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || { error "SSH 重启失败，回滚。"; cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config; return 1; }
    info "SSH 已重启，端口：$new_port"
    sleep 1; ss -tlnp 2>/dev/null | grep -q ":${new_port} " && info "OK 确认监听 $new_port" || warn "未检测到 SSH 监听 $new_port"

    # ── 确认回滚 ──────────────────────────────────────────────
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  保持当前会话，另开终端测试：ssh -p $new_port user@服务器IP${NC}"
    echo -e "${YELLOW}  云商安全组需手动放行 $new_port${NC}"
    echo -e "${YELLOW}  连接成功后再确认${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    read -r -p "确认新端口连接正常？(yes/NO): " confirm
    if [[ "$confirm" != "yes" ]]; then
        warn "回滚…"; cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        error "已回滚到端口 $current_port。"; return 1
    fi
    step_mark_executed "change_ssh_port"; info "SSH 端口已更改为 $new_port。"
}

# ─── 步骤 7：SSH 密钥配置 ───────────────────────────────────────────────
step_ssh_key_config() {
    step_header "步骤 7/10：禁用密码登录，配置 SSH 密钥登录"
    require_root
    local sshd_config="/etc/ssh/sshd_config"
    [[ ! -f "$sshd_config" ]] && { error "未找到 $sshd_config"; return 1; }
    [[ ! -f "${BACKUP_DIR}/sshd_config.bak" ]] && { cp "$sshd_config" "${BACKUP_DIR}/sshd_config.bak"; register_rollback "cp '${BACKUP_DIR}/sshd_config.bak' '$sshd_config'"; register_rollback "systemctl restart sshd || service ssh restart || true"; }

    local ssh_key="${SSH_PUBKEY:-}"
    if [[ -z "$ssh_key" ]]; then
        echo -e "${YELLOW}粘贴 SSH 公钥，新行输入 EOF 结束（直接回车跳过）：${NC}"
        ssh_key=""
        while IFS= read -r line; do [[ "$line" == "EOF" ]] && break; [[ -z "$line" && -z "$ssh_key" ]] && break; ssh_key+="$line"$'\n'; done
        ssh_key="$(echo -e "$ssh_key" | sed '/^$/d')"
    else
        info "使用环境变量 SSH_PUBKEY。"
    fi

    if [[ -n "$ssh_key" ]]; then
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        echo "$ssh_key" >> /root/.ssh/authorized_keys; sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
        if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
            local uh=$(getent passwd "$SUDO_USER" | cut -d: -f6) || uh="/home/$SUDO_USER"
            [[ -n "$uh" ]] && { mkdir -p "$uh/.ssh"; chmod 700 "$uh/.ssh"; echo "$ssh_key" >> "$uh/.ssh/authorized_keys"; sort -u "$uh/.ssh/authorized_keys" -o "$uh/.ssh/authorized_keys"; chmod 600 "$uh/.ssh/authorized_keys"; chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$uh/.ssh" 2>/dev/null || true; }
        fi
        info "SSH 公钥已添加。"
    else
        info "跳过。"
    fi

    local dp="${SSH_DISABLE_PASSWORD:-}"
    [[ -z "$dp" ]] && { read -r -p "禁用 SSH 密码登录？(yes/NO): " dp; dp="${dp:-no}"; }
    if [[ "${dp,,}" == "yes" || "${dp,,}" == "y" ]]; then
        local kc=$(wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo 0)
        if [[ "$kc" -eq 0 ]]; then
            warn "没有公钥！可能锁死！"; read -r -p "确认继续？(yes/NO): " fd; [[ "${fd,,}" != "yes" ]] && { info "已取消。"; return 0; }
        fi
        sed -i 's/^#\?PasswordAuthentication\s\+.*/PasswordAuthentication no/' "$sshd_config"
        grep -q '^PasswordAuthentication no' "$sshd_config" || echo 'PasswordAuthentication no' >> "$sshd_config"
        sed -i 's/^#\?ChallengeResponseAuthentication\s\+.*/ChallengeResponseAuthentication no/' "$sshd_config"
        grep -q '^ChallengeResponseAuthentication no' "$sshd_config" || echo 'ChallengeResponseAuthentication no' >> "$sshd_config"
        sed -i 's/^#\?PubkeyAuthentication\s\+.*/PubkeyAuthentication yes/' "$sshd_config"
        grep -q '^PubkeyAuthentication yes' "$sshd_config" || echo 'PubkeyAuthentication yes' >> "$sshd_config"
        sed -i 's/^#\?PermitEmptyPasswords\s\+.*/PermitEmptyPasswords no/' "$sshd_config"
        log "已配置：密码禁用，密钥启用。"
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        info "SSH 已重启。"
        echo -e "${YELLOW}保持当前会话，另开终端测试密钥登录。${NC}"
        read -r -p "确认密钥登录正常？(yes/NO): " ck
        if [[ "$ck" != "yes" ]]; then
            warn "回滚…"; cp "${BACKUP_DIR}/sshd_config.bak" "$sshd_config"
            systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
            error "已回滚。"; return 1
        fi
    else
        info "跳过。"
    fi
    step_mark_executed "ssh_key_config"; info "SSH 密钥配置完成。"
}

# ─── 步骤 8：禁止 IPQS ─────────────────────────────────────────────────
step_block_ipqs() {
    step_header "步骤 8/10：禁止 IPQS"
    require_root
    local hosts_file="/etc/hosts"
    local entries=("127.0.0.1 ipqualityscore.com" "127.0.0.1 www.ipqualityscore.com" "127.0.0.1 api.ipqualityscore.com")
    [[ ! -f "${BACKUP_DIR}/hosts.bak" ]] && { cp "$hosts_file" "${BACKUP_DIR}/hosts.bak"; register_rollback "cp '${BACKUP_DIR}/hosts.bak' '$hosts_file'"; }
    local added=0
    for entry in "${entries[@]}"; do
        grep -qF "$entry" "$hosts_file" 2>/dev/null && log "  已存在：$entry" || { echo "$entry" >> "$hosts_file"; log "  已添加：$entry"; ((added++)); }
    done
    info "IPQS 屏蔽完成（新增 $added 条）。"
    step_mark_executed "block_ipqs"
}

# ─── 步骤 9：解除 53 端口占用 ──────────────────────────────────────────
step_release_port53() {
    step_header "步骤 9/10：解除 53 端口占用"
    require_root
    local rc="/etc/systemd/resolved.conf"
    [[ -f "$rc" ]] || touch "$rc"
    [[ ! -f "${BACKUP_DIR}/resolved.conf.bak" ]] && { cp "$rc" "${BACKUP_DIR}/resolved.conf.bak"; register_rollback "cp '${BACKUP_DIR}/resolved.conf.bak' '$rc'"; register_rollback "systemctl restart systemd-resolved || true"; }
    if grep -q '^\[Resolve\]' "$rc" 2>/dev/null; then
        grep -q '^DNS=' "$rc" && sed -i 's/^DNS=.*/DNS=8.8.8.8 1.1.1.1/' "$rc" || sed -i '/^\[Resolve\]/a DNS=8.8.8.8 1.1.1.1' "$rc"
        grep -q '^DNSStubListener=' "$rc" && sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' "$rc" || sed -i '/^\[Resolve\]/a DNSStubListener=no' "$rc"
    else
        cat >> "$rc" << 'EOL'
[Resolve]
DNS=8.8.8.8 1.1.1.1
DNSStubListener=no
EOL
    fi
    log "已配置 resolved.conf"
    local rl="/etc/resolv.conf"
    [[ -L "$rl" ]] || cp "$rl" "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || true
    ln -sf /run/systemd/resolve/resolv.conf "$rl" 2>/dev/null || true
    safe_run "重启 systemd-resolved" systemctl restart systemd-resolved
    echo ""; info "53 端口验证："; command -v lsof &>/dev/null && lsof -i :53 2>/dev/null || ss -tlnp 2>/dev/null | grep ':53 ' || echo "  (无进程监听 53)"
    echo ""; info "DNS 解析测试："
    safe_run "DNS 测试" nslookup google.com 8.8.8.8 2>/dev/null || safe_run "DNS 测试(备选)" dig +short google.com @8.8.8.8 2>/dev/null || warn "DNS 测试失败。"
    step_mark_executed "release_port53"; info "53 端口配置完成。"
}

# ─── 步骤 10：系统清理 ─────────────────────────────────────────────────
step_system_cleanup() {
    step_header "步骤 10/10：系统清理 (Ubuntu/Debian)"
    require_root
    warn "即将深度清理：旧内核、孤立包、apt 缓存、残留配置、日志、tmp、snap、pip/npm。"
    local confirm; read -r -p "确认？(yes/NO): " confirm; [[ "${confirm,,}" != "yes" ]] && { info "跳过。"; return 0; }
    echo ""

    info "--- 1/8 清理旧内核 ---"
    if command -v dpkg &>/dev/null; then
        local rk=$(uname -r | sed 's/-[a-z]*$//; s/-$//')
        log "当前内核：$rk"
        local imgs=(); while IFS= read -r p; do imgs+=("$p"); done < <(dpkg -l 'linux-image-*' 'linux-image-unsigned-*' 2>/dev/null | awk '/^ii/ {print $2}' | sort -V)
        local purge=() keep=1 cnt=${#imgs[@]} i=0
        for pkg in "${imgs[@]}"; do
            local ver=$(echo "$pkg" | sed 's/^linux-image-//; s/^linux-image-unsigned-//')
            [[ "$ver" == "$rk" ]] && ((keep++))
            ((i < cnt - keep)) && purge+=("$pkg"); ((i++))
        done
        if [[ ${#purge[@]} -gt 0 ]]; then
            log "可清理 ${#purge[@]} 个旧内核：${purge[*]}"
            local ck; read -r -p "移除？(yes/NO): " ck; [[ "${ck,,}" == "yes" ]] && safe_run "移除旧内核" apt-get purge -y "${purge[@]}" || info "跳过。"
        fi
        local hdrs=(); while IFS= read -r p; do hdrs+=("$p"); done < <(dpkg -l 'linux-headers-*' 2>/dev/null | awk '/^ii/ {print $2}' | sort -V | head -n -1)
        local hpurge=()
        for pkg in "${hdrs[@]}"; do local ver=$(echo "$pkg" | sed 's/^linux-headers-//'); [[ "$ver" != "$rk" && "$ver" != "generic" ]] && hpurge+=("$pkg"); done
        [[ ${#hpurge[@]} -gt 0 ]] && safe_run "移除旧 headers" apt-get purge -y "${hpurge[@]}" 2>/dev/null || true
    fi

    echo ""; info "--- 2/8 孤立包 ---"; safe_run "autoremove" apt-get autoremove -y
    echo ""; info "--- 3/8 apt 缓存 ---"; safe_run "autoclean" apt-get autoclean; safe_run "clean" apt-get clean; rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
    echo ""; info "--- 4/8 残留配置 ---"
    local rc=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' | wc -l) || rc=0
    [[ "$rc" -gt 0 ]] && { dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg --purge 2>/dev/null || true; info "已清理 $rc 个。"; } || info "无残留配置。"
    echo ""; info "--- 5/8 Snap ---"
    command -v snap &>/dev/null && { local snaps=$(snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}') || snaps=""; if [[ -n "$snaps" ]]; then echo "$snaps"; local cs; read -r -p "移除？(yes/NO): " cs; [[ "${cs,,}" == "yes" ]] && echo "$snaps" | while IFS=' ' read -r n r; do safe_run "移除 snap $n ($r)" snap remove "$n" --revision="$r" 2>/dev/null || true; done; fi; } || info "Snap 未安装。"
    echo ""; info "--- 6/8 日志 ---"
    command -v journalctl &>/dev/null && { local js=$(journalctl --disk-usage 2>/dev/null | awk '{print $NF}') || js="?"; log "日志占用：$js"; echo "清理: 1) 100MB  2) 7天  3) 跳过"; local jc; read -r -p "选择 [1/2/3]: " jc; case "${jc:-3}" in 1) safe_run "日志 100M" journalctl --vacuum-size=100M 2>/dev/null || true;; 2) safe_run "日志 7d" journalctl --vacuum-time=7d 2>/dev/null || true;; *) info "跳过。"; esac; } || info "journalctl 不可用。"
    echo ""; info "--- 7/8 临时文件 ---"
    find /tmp -type f -atime +7 -delete 2>/dev/null || true; find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    echo ""; info "--- 8/8 pip/npm 缓存 ---"
    command -v pip3 &>/dev/null && pip3 cache purge 2>/dev/null || true; command -v pip &>/dev/null && pip cache purge 2>/dev/null || true
    command -v npm &>/dev/null && npm cache clean --force 2>/dev/null || true; command -v yarn &>/dev/null && yarn cache clean 2>/dev/null || true
    info "系统清理完成！"
    step_mark_executed "system_cleanup"
}

# ─── 流程内清理 ─────────────────────────────────────────────────────────────
step_cleanup() {
    step_header "清理临时文件"
    rm -f "${BACKUP_DIR}/bbr.sh" 2>/dev/null || true
    log "备份保留：$BACKUP_DIR"
    local sz=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}') || sz="N/A"
    info "备份大小：$sz"
}

# ─── 全局回滚 ────────────────────────────────────────────────────────────────
step_global_rollback() {
    step_header "执行全局回滚"
    require_root
    [[ ! -f "$ROLLBACK_FILE" ]] && { info "无回滚记录。"; return 0; }
    local cnt=$(wc -l < "$ROLLBACK_FILE"); [[ "$cnt" -eq 0 ]] && { info "无回滚操作。"; return 0; }
    warn "执行 $cnt 条回滚…"
    tac "$ROLLBACK_FILE" | while IFS= read -r cmd; do [[ -n "$cmd" ]] && bash -c "$cmd" >> "$LOG_FILE" 2>&1 || true; done
    rm -f "$EXECUTED_STEPS_FILE"; info "回滚完成。"
}

# ─── 菜单 ────────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Debian/Ubuntu 服务器初始化脚本${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo "请选择步骤（逗号分隔，如 1,2,3）："
    echo "  1)  系统信息查询"
    echo "  2)  系统更新"
    echo "  3)  安装常用软件包"
    echo "  4)  安装 BBR"
    echo "  5)  安装 NextTrace"
    echo "  6)  修改 SSH 端口"
    echo "  7)  SSH 密钥配置"
    echo "  8)  禁止 IPQS"
    echo "  9)  解除 53 端口占用"
    echo "  10) 系统深度清理"
    echo "  a)  全部执行    r) 回滚    q) 退出"
    echo ""
    echo -e "  环境变量：${GREEN}SSH_PORT=2222 SSH_PUBKEY=\"...\" SSH_DISABLE_PASSWORD=yes${NC}"
    echo -e "  静默：${GREEN}sudo ./debian_setup.sh --all${NC}"
    echo -e "  指定：${GREEN}sudo ./debian_setup.sh --step 1,3,10${NC}"
}

# ─── 主流程 ──────────────────────────────────────────────────────────────────
main() {
    require_root
    local run_all=false selected_steps=""
    while [[ $# -gt 0 ]]; do
        case "$1" in --all) run_all=true; shift;; --step) selected_steps="${2:-}"; shift 2;; --rollback) step_global_rollback; exit 0;; -h|--help) show_menu; exit 0;; *) error "未知参数：$1"; exit 1;; esac
    done

    if [[ "$run_all" == true ]]; then
        log "全部步骤"
        step_sysinfo; step_system_update; step_install_packages; step_install_bbr; step_install_nexttrace
        step_change_ssh_port; step_ssh_key_config; step_block_ipqs; step_release_port53; step_system_cleanup
        step_cleanup; info "全部完成！备份：$BACKUP_DIR"; return 0
    fi

    if [[ -n "$selected_steps" ]]; then
        log "步骤 $selected_steps"
        IFS=',' read -ra steps <<< "$selected_steps"
        for s in "${steps[@]}"; do s="$(echo "$s" | xargs)"
            case "$s" in 1) step_sysinfo;; 2) step_system_update;; 3) step_install_packages;; 4) step_install_bbr;; 5) step_install_nexttrace;; 6) step_change_ssh_port;; 7) step_ssh_key_config;; 8) step_block_ipqs;; 9) step_release_port53;; 10) step_system_cleanup;; *) warn "跳过：$s";; esac
        done
        step_cleanup; info "完成！备份：$BACKUP_DIR"; return 0
    fi

    show_menu
    read -r -p "请选择 [1-10,a,r,q]: " choice
    case "$choice" in a|A) main --all;; r|R) step_global_rollback;; q|Q) info "退出。"; exit 0;;
        *)
            IFS=',; ' read -ra selections <<< "$choice"
            for sel in "${selections[@]}"; do sel="$(echo "$sel" | xargs)"
                case "$sel" in 1) step_sysinfo;; 2) step_system_update;; 3) step_install_packages;; 4) step_install_bbr;; 5) step_install_nexttrace;; 6) step_change_ssh_port;; 7) step_ssh_key_config;; 8) step_block_ipqs;; 9) step_release_port53;; 10) step_system_cleanup;; *) warn "跳过：$sel";; esac
            done
            step_cleanup; info "完成！备份：$BACKUP_DIR"
            ;;
    esac
}

main "$@"
    sed -i "s/^Port\s\+[0-9].*/Port $new_port/" /etc/ssh/sshd_config
    grep -q "^Port $new_port" /etc/ssh/sshd_config || echo "Port $new_port" >> /etc/ssh/sshd_config
    log "SSH 端口 $current_port -> $new_port"

    # ── 防火墙放行（不依赖退出码，以规则真实存在为准）──
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$new_port/tcp" 2>/dev/null || true
        ufw status 2>/dev/null | grep -q "$new_port" && info "UFW 已放行 $new_port/tcp" || warn "UFW 规则可能未生效，请手动检查。"
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall-cmd --permanent --add-port="${new_port}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        firewall-cmd --list-ports 2>/dev/null | grep -q "$new_port" && info "firewalld 已放行 $new_port/tcp" || warn "firewalld 规则可能未生效。"
    fi
    if command -v iptables &>/dev/null; then
        local dp=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}' | tr -d '()')
        [[ "$dp" == "DROP" || "$dp" == "REJECT" ]] && { iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true; info "已添加 iptables 放行规则。"; }
    fi

    # ── 重启 SSH ──────────────────────────────────────────────
    command -v sshd &>/dev/null && ! sshd -t 2>/dev/null && { error "sshd_config 语法错误，回滚。"; cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config; return 1; }
    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || { error "SSH 重启失败，回滚。"; cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config; return 1; }
    info "SSH 已重启，端口：$new_port"
    sleep 1; ss -tlnp 2>/dev/null | grep -q ":${new_port} " && info "OK 确认监听 $new_port" || warn "未检测到 SSH 监听 $new_port"
    # ── 调试：显示修改后的 Port 行 ─────────────────────────
    log "修改后 sshd_config 中的 Port 行："
    grep -n '^[[:space:]]*Port\b' /etc/ssh/sshd_config | while IFS= read -r line; do
        log "  $line"
    done
    log "SSH 端口 $current_port -> $new_port"

    # ── 防火墙放行（不依赖退出码，以规则真实存在为准）──
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$new_port/tcp" 2>/dev/null || true
        ufw status 2>/dev/null | grep -q "$new_port" && info "UFW 已放行 $new_port/tcp" || warn "UFW 规则可能未生效，请手动检查。"
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall-cmd --permanent --add-port="${new_port}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        firewall-cmd --list-ports 2>/dev/null | grep -q "$new_port" && info "firewalld 已放行 $new_port/tcp" || warn "firewalld 规则可能未生效。"
    fi
    if command -v iptables &>/dev/null; then
        local dp=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}' | tr -d '()')
        [[ "$dp" == "DROP" || "$dp" == "REJECT" ]] && { iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true; info "已添加 iptables 放行规则。"; }
    fi

    # ── 重启 SSH ──────────────────────────────────────────────
    # 语法检查 + 显示具体错误
    if command -v sshd &>/dev/null; then
        local syntax_ok
        syntax_ok=$(sshd -t 2>&1) || {
            error "sshd_config 语法错误："
            echo "$syntax_ok" | while IFS= read -r err; do echo "  $err"; done
            warn "回滚…"
            cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
            return 1
        }
        log "sshd_config 语法检查通过。"
    fi

    # 重启并检查是否真的启动成功
    local ssh_restart_ok=true
    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || ssh_restart_ok=false
    if ! $ssh_restart_ok; then
        error "SSH 重启失败！"
        # 检查 systemd 状态
        systemctl status sshd --no-pager 2>&1 | head -10 | while IFS= read -r line; do log "  $line"; done
        warn "回滚…"
        cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        return 1
    fi

    # 等待并检查监听端口
    sleep 2
    local listening
    listening=$(ss -tlnp 2>/dev/null | grep sshd) || listening=""
    if echo "$listening" | grep -q ":${new_port} "; then
        info "OK 确认 SSH 正在监听端口 $new_port"
    else
        warn "SSH 未在端口 $new_port 上监听！当前监听端口："
        if [[ -n "$listening" ]]; then
            echo "$listening" | while IFS= read -r line; do log "  $line"; done
        else
            log "  sshd 没有监听任何端口（可能未启动）"
        fi
        # 检查 sshd 是否在运行
        if pgrep -x sshd &>/dev/null; then
            log "  sshd 进程存在但未监听 $new_port"
        else
            log "  sshd 进程不存在"
            systemctl status sshd --no-pager 2>&1 | tail -5 | while IFS= read -r line; do log "  $line"; done
        fi
    fi
