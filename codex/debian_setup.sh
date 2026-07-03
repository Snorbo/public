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

    # ── 网络信息 ──────────────────────────────────────────────
    local public_ip=""
    local ipv4_address=""
    local ipv6_address=""
    local isp_info=""
    local country=""
    local city=""

    local ipinfo_json
    ipinfo_json=$(curl -s --max-time 3 https://ipinfo.io 2>/dev/null) || ipinfo_json=""
    if [[ -n "$ipinfo_json" ]]; then
        country=$(echo "$ipinfo_json" | grep '"country"' | awk -F': "' '{print $2}' | tr -d '",')
        city=$(echo "$ipinfo_json" | grep '"city"' | awk -F': "' '{print $2}' | tr -d '",')
        isp_info=$(echo "$ipinfo_json" | grep '"org"' | awk -F': "' '{print $2}' | tr -d '",')
        public_ip=$(echo "$ipinfo_json" | grep '"ip"' | awk -F': "' '{print $2}' | tr -d '",')
    fi

    if echo "$isp_info" | grep -Eiq 'CHINANET|mobile|unicom|telecom'; then
        ipv4_address=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || \
            hostname -I 2>/dev/null | awk '{print $1}')
    else
        ipv4_address="$public_ip"
    fi
    ipv6_address=$(curl -s --max-time 2 https://v6.ipinfo.io/ip 2>/dev/null) || ipv6_address=""

    # ── 流量统计 ──────────────────────────────────────────────
    local rx_tx
    rx_tx=$(awk 'BEGIN{rx=0;tx=0} $1~/^(eth|ens|enp|eno)[0-9]+/{rx+=$2;tx+=$10} END{printf "%.0f %.0f", rx, tx}' /proc/net/dev)
    local rx_bytes tx_bytes
    rx_bytes=$(echo "$rx_tx" | awk '{print $1}')
    tx_bytes=$(echo "$rx_tx" | awk '{print $2}')

    human_readable() {
        local bytes=$1
        if (( bytes > 1073741824 )); then echo "$(echo "scale=2; $bytes/1073741824" | bc)G"
        elif (( bytes > 1048576 )); then echo "$(echo "scale=2; $bytes/1048576" | bc)M"
        elif (( bytes > 1024 )); then echo "$(echo "scale=2; $bytes/1024" | bc)K"
        else echo "${bytes}B"; fi
    }
    local rx=$(human_readable "$rx_bytes")
    local tx=$(human_readable "$tx_bytes")

    # ── CPU ───────────────────────────────────────────────────
    local cpu_info
    cpu_info=$(lscpu 2>/dev/null | awk -F': +' '/Model name:/ {print $2; exit}') || cpu_info="unknown"
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null) || cpu_cores="?"

    local cpu_usage="0"
    local cpu_stat1 cpu_stat2
    cpu_stat1=$(grep 'cpu ' /proc/stat 2>/dev/null) || cpu_stat1=""
    if [[ -n "$cpu_stat1" ]]; then
        sleep 1 2>/dev/null || true
        cpu_stat2=$(grep 'cpu ' /proc/stat 2>/dev/null) || cpu_stat2=""
        if [[ -n "$cpu_stat2" ]]; then
            cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if(NR==1){u1=u;t1=t}else printf "%.1f\n",(($2+$4-u1)*100/(t-t1))}' \
                <(echo "$cpu_stat1") <(echo "$cpu_stat2")) || cpu_usage="0"
        fi
    fi

    local cpu_freq
    cpu_freq=$(grep "MHz" /proc/cpuinfo 2>/dev/null | head -1 | awk '{printf "%.1f GHz\n", $4/1000}') || cpu_freq="?"
    local cpu_arch
    cpu_arch=$(uname -m)

    # ── 内存 ───────────────────────────────────────────────────
    local mem_info
    mem_info=$(free -b 2>/dev/null | awk 'NR==2{printf "%.2f/%.2fM (%.1f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}') || mem_info="?"
    local swap_info
    swap_info=$(free -m 2>/dev/null | awk 'NR==3{used=$3;total=$2;if(total==0){p=0}else{p=used*100/total}; printf "%dM/%dM (%d%%)", used, total, p}') || swap_info="?"

    # ── 磁盘 ───────────────────────────────────────────────────
    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}') || disk_info="?"

    # ── 系统 ───────────────────────────────────────────────────
    local hostname
    hostname=$(uname -n)
    local kernel_version
    kernel_version=$(uname -r)
    local os_info
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"') || os_info="?"

    local load
    load=$(uptime 2>/dev/null | awk '{print $(NF-2), $(NF-1), $NF}') || load="?"

    local runtime
    runtime=$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);
        if(d>0)printf "%d天 ",d;if(h>0)printf "%d时 ",h;printf "%d分"}' /proc/uptime 2>/dev/null) || runtime="?"

    local congestion
    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || congestion="?"
    local queue_alg
    queue_alg=$(sysctl -n net.core.default_qdisc 2>/dev/null) || queue_alg="?"

    local dns_addrs
    dns_addrs=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null) || dns_addrs="?"

    local timezone
    if grep -q 'Alpine' /etc/issue 2>/dev/null; then
        timezone=$(date +"%Z %z")
    else
        timezone=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}') || timezone=$(date +"%Z %z")
    fi
    local current_time
    current_time=$(date "+%Y-%m-%d %I:%M %p")

    local tcp_count udp_count
    tcp_count=$(ss -t 2>/dev/null | wc -l) || tcp_count="?"
    udp_count=$(ss -u 2>/dev/null | wc -l) || udp_count="?"

    # ── 输出 ────────────────────────────────────────────────
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

    step_mark_executed "sysinfo"
    info "系统信息已显示。"
}

# ─── 步骤 2：系统更新 ────────────────────────────────────────────────────
step_system_update() {
    step_header "步骤 2/10：系统更新 (apt update & upgrade)"
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

# ─── 步骤 3：安装常用包 ─────────────────────────────────────────────────
step_install_packages() {
    step_header "步骤 3/10：安装常用软件包"
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

# ─── 步骤 4：安装 BBR ───────────────────────────────────────────────────
step_install_bbr() {
    step_header "步骤 4/10：安装 BBR 拥塞控制算法"
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
        info "OK BBR 模块已加载，当前拥塞控制算法：$bbr_active"
    else
        warn "BBR 模块未加载，可能需要重启后生效。当前算法：$bbr_active"
    fi

    step_mark_executed "install_bbr"
    info "BBR 安装步骤完成。"
}

# ─── 步骤 5：安装 NextTrace ─────────────────────────────────────────────
step_install_nexttrace() {
    step_header "步骤 5/10：安装 NextTrace (路由追踪工具)"
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

# ─── 步骤 6：修改 SSH 端口 ──────────────────────────────────────────────
step_change_ssh_port() {
    step_header "步骤 6/10：修改 SSH 连接端口"
    require_root

    if [[ ! -f /etc/ssh/sshd_config ]]; then
        error "未找到 /etc/ssh/sshd_config"
        return 1
    fi

    local current_port
    current_port=$(grep -E '^Port\s+[0-9]' /etc/ssh/sshd_config | tail -1 | awk '{print $2}') 
    if ! [[ "$current_port" =~ ^[0-9]+$ ]]; then
        current_port="1556"
    fi    
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

    # 检查新端口是否已被其他进程占用
    if ss -tlnp 2>/dev/null | grep -q ":${new_port} "; then
        warn "端口 $new_port 已被占用："
        ss -tlnp 2>/dev/null | grep ":${new_port} "
        read -r -p "端口已被占用，仍然继续？(yes/NO): " force_port
        if [[ "${force_port,,}" != "yes" ]]; then
            info "取消端口修改。"; return 1
        fi
    fi

    cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak"
    register_rollback "cp '${BACKUP_DIR}/sshd_config.bak' /etc/ssh/sshd_config"
    register_rollback "systemctl restart sshd || service ssh restart || true"
    log "已备份 sshd_config"

    # 注释掉所有现有 Port 指令，追加新端口 (比依赖 sed 的 \n 更可靠)
    sed -i 's/^Port\s\+.*/#&/' /etc/ssh/sshd_config
    echo "Port $new_port" >> /etc/ssh/sshd_config
    log "SSH 端口已从 $current_port 修改为 $new_port"

    # ── 防火墙放行 ──────────────────────────────────────────────
    local ufw_ok=false
    local ipt_ok=false

    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "active"; then
            safe_run "UFW 放行 $new_port/tcp" ufw allow "$new_port/tcp"
            safe_run "UFW 放行 $new_port"     ufw allow "$new_port"
            ufw_ok=true
        else
            warn "UFW 未启用，跳过。"
        fi
    fi

    if command -v firewall-cmd &>/dev/null; then
        if firewall-cmd --state 2>/dev/null | grep -q "running"; then
            safe_run "firewalld 放行 $new_port/tcp" firewall-cmd --permanent --add-port="${new_port}/tcp"
            safe_run "firewalld 重载" firewall-cmd --reload
            ipt_ok=true
        fi
    fi

    # UFW 和 firewalld 均无效时，尝试直接 iptables
    if ! $ufw_ok && ! $ipt_ok; then
        if command -v iptables &>/dev/null; then
            local default_policy
            default_policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}' | tr -d '()')
            if [[ "$default_policy" == "DROP" || "$default_policy" == "REJECT" ]]; then
                warn "iptables INPUT 默认策略为 DROP/REJECT，尝试放行 $new_port…"
                safe_run "iptables 放行 $new_port" iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true
                if command -v iptables-save &>/dev/null; then
                    safe_run "保存 iptables 规则" sh -c "iptables-save > /etc/iptables/rules.v4 2>/dev/null" || true
                fi
                ipt_ok=true
            else
                info "iptables INPUT 默认策略为 ACCEPT，无需额外放行。"
                ipt_ok=true
            fi
        fi
    fi

    if ! $ufw_ok && ! $ipt_ok; then
        warn "未能自动配置防火墙。如果云服务商有安全组/防火墙，请手动放行端口 $new_port。"
    fi

    # ── 重启 SSH ──────────────────────────────────────────────
    # 先验证 sshd_config 语法
    if command -v sshd &>/dev/null; then
        if ! sshd -t 2>/dev/null; then
            error "sshd_config 语法检查失败！回滚…"
            cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
            error "已回滚。请手动检查 sshd_config。"
            return 1
        fi
        log "sshd_config 语法检查通过。"
    fi

    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || {
        error "SSH 服务重启失败，回滚…"
        cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
        return 1
    }
    info "SSH 服务已重启，新端口：$new_port"

    # 验证监听
    sleep 1
    if ss -tlnp 2>/dev/null | grep -q ":${new_port} "; then
        info "OK 确认 SSH 正在监听端口 $new_port"
    else
        warn "未检测到 SSH 在 $new_port 上监听："
        ss -tlnp 2>/dev/null | grep -E "sshd" || true
    fi

    # ── 确认回滚 ──────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  重要提醒${NC}"
    echo -e "${YELLOW}  1. 保持当前 SSH 会话不要关闭${NC}"
    echo -e "${YELLOW}  2. 另开终端测试：ssh -p $new_port user@服务器IP${NC}"
    echo -e "${YELLOW}  3. 如云商有安全组，请确保已放行 $new_port${NC}"
    echo -e "${YELLOW}  4. 连接成功后再来输入 yes 确认${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo ""

    read -r -p "确认新端口连接正常？(yes/NO): " confirm
    if [[ "$confirm" != "yes" ]]; then
        warn "回滚 SSH 端口…"
        cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        error "已回滚到端口 $current_port。"
        echo -e "${YELLOW}若云商安全组未放行，添加规则后可重新执行步骤 6。${NC}"
        return 1
    fi

    step_mark_executed "change_ssh_port"
    info "SSH 端口已更改为 $new_port。"
}

# ─── 步骤 7：SSH 密钥配置 ───────────────────────────────────────────────
step_ssh_key_config() {
    step_header "步骤 7/10：禁用密码登录，配置 SSH 密钥登录"
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

# ─── 步骤 8：禁止 IPQS ─────────────────────────────────────────────────
step_block_ipqs() {
    step_header "步骤 8/10：禁止 IPQS"
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

# ─── 步骤 9：解除 53 端口占用 ──────────────────────────────────────────
step_release_port53() {
    step_header "步骤 9/10：解除 53 端口占用"
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
        cat >> "$resolved_conf" << 'EOL'
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

# ─── 步骤 10：系统清理 ─────────────────────────────────────────────────
step_system_cleanup() {
    step_header "步骤 10/10：系统清理 (Ubuntu/Debian)"
    require_root

    warn "即将执行系统深度清理，包括：旧内核、孤立包、apt 缓存、日志、临时文件。"
    echo ""
    echo -e "  ${YELLOW}• 移除${NC} 旧内核（保留当前 + 最新 1 个）"
    echo -e "  ${YELLOW}• 清理${NC} 孤立依赖（apt autoremove）"
    echo -e "  ${YELLOW}• 清理${NC} apt 缓存（clean / autoclean）"
    echo -e "  ${YELLOW}• 清理${NC} 已删除包的残留配置文件"
    echo -e "  ${YELLOW}• 清理${NC} 系统日志（journalctl）"
    echo -e "  ${YELLOW}• 清理${NC} 临时文件（/tmp, /var/tmp）"
    echo -e "  ${YELLOW}• 清理${NC} Snap 旧版本"
    echo -e "  ${YELLOW}• 清理${NC} pip / npm 缓存"
    echo ""

    local confirm
    read -r -p "确认执行系统清理？(yes/NO): " confirm
    if [[ "${confirm,,}" != "yes" ]]; then
        info "跳过系统清理。"
        return 0
    fi
    echo ""

    # ── 1. 清理旧内核 ──────────────────────────────────────────────
    info "--- 1/8 清理旧内核 ---"
    if command -v dpkg &>/dev/null; then
        local running_kernel
        running_kernel=$(uname -r | sed 's/-[a-z]*$//; s/-$//')
        log "当前运行内核版本：$running_kernel"

        local all_images=()
        while IFS= read -r pkg; do
            all_images+=("$pkg")
        done < <(dpkg -l 'linux-image-*' 'linux-image-unsigned-*' 2>/dev/null \
            | awk '/^ii/ {print $2}' | sort -V)

        local to_purge=()
        local keep=1
        local count=${#all_images[@]}
        local i=0
        for pkg in "${all_images[@]}"; do
            local ver
            ver=$(echo "$pkg" | sed 's/^linux-image-//; s/^linux-image-unsigned-//')
            if [[ "$ver" == "$running_kernel" ]]; then
                ((keep++))
            elif [[ $i -lt $((count - keep)) ]]; then
                to_purge+=("$pkg")
            fi
            ((i++))
        done

        if [[ ${#to_purge[@]} -gt 0 ]]; then
            log "发现 ${#to_purge[@]} 个可清理的旧内核：${to_purge[*]}"
            local ck
            read -r -p "移除这些旧内核包？(yes/NO): " ck
            if [[ "${ck,,}" == "yes" ]]; then
                safe_run "移除旧内核" apt-get purge -y "${to_purge[@]}"
            else
                info "跳过内核清理。"
            fi
        else
            info "没有需要清理的旧内核。"
        fi

        local all_headers=()
        while IFS= read -r pkg; do
            all_headers+=("$pkg")
        done < <(dpkg -l 'linux-headers-*' 2>/dev/null | awk '/^ii/ {print $2}' | sort -V | head -n -1)
        local hdrs_to_purge=()
        for pkg in "${all_headers[@]}"; do
            local ver
            ver=$(echo "$pkg" | sed 's/^linux-headers-//')
            [[ "$ver" == "$running_kernel" || "$ver" == "generic" ]] && continue
            hdrs_to_purge+=("$pkg")
        done
        if [[ ${#hdrs_to_purge[@]} -gt 0 ]]; then
            safe_run "移除旧 headers" apt-get purge -y "${hdrs_to_purge[@]}" 2>/dev/null || true
        fi
    else
        warn "dpkg 不可用，跳过内核清理。"
    fi

    # ── 2. 清理孤立包 ──────────────────────────────────────────────
    echo ""
    info "--- 2/8 清理孤立包 (autoremove) ---"
    safe_run "apt autoremove -y" apt-get autoremove -y

    # ── 3. 清理 apt 缓存 ──────────────────────────────────────────
    echo ""
    info "--- 3/8 清理 apt 缓存 ---"
    safe_run "apt autoclean" apt-get autoclean
    safe_run "apt clean" apt-get clean
    safe_run "清理 /var/cache/apt" rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true

    # ── 4. 清理残留配置文件 ──────────────────────────────────────
    echo ""
    info "--- 4/8 清理已删除包的残留配置 ---"
    local rc_count
    rc_count=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' | wc -l) || rc_count=0
    if [[ "$rc_count" -gt 0 ]]; then
        log "发现 $rc_count 个残留配置包"
        dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg --purge 2>/dev/null || true
        info "残留配置已清理。"
    else
        info "没有残留配置文件。"
    fi

    # ── 5. 清理 Snap 旧版本 ──────────────────────────────────────
    echo ""
    info "--- 5/8 清理 Snap 旧版本 ---"
    if command -v snap &>/dev/null; then
        local disabled_snaps
        disabled_snaps=$(snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}') || disabled_snaps=""
        if [[ -n "$disabled_snaps" ]]; then
            log "存在已禁用的 snap 版本："
            echo "$disabled_snaps"
            local cs
            read -r -p "移除这些旧 snap 版本？(yes/NO): " cs
            if [[ "${cs,,}" == "yes" ]]; then
                snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}' | while IFS=' ' read -r name rev; do
                    safe_run "移除 snap $name ($rev)" snap remove "$name" --revision="$rev" 2>/dev/null || true
                done
            fi
        else
            info "没有需要清理的 snap 版本。"
        fi
    else
        info "Snap 未安装，跳过。"
    fi

    # ── 6. 清理 systemd 日志 ─────────────────────────────────────
    echo ""
    info "--- 6/8 清理系统日志 (journalctl) ---"
    if command -v journalctl &>/dev/null; then
        local jsize
        jsize=$(journalctl --disk-usage 2>/dev/null | awk '{print $NF}') || jsize="?"
        log "当前日志占用：$jsize"
        echo "  清理模式："
        echo "    1) 保留最近 100MB"
        echo "    2) 保留最近 7 天"
        echo "    3) 跳过"
        local jc
        read -r -p "  请选择 [1/2/3]: " jc
        case "${jc:-3}" in
            1) safe_run "journalctl 清理(100M)" journalctl --vacuum-size=100M 2>/dev/null || true ;;
            2) safe_run "journalctl 清理(7d)" journalctl --vacuum-time=7d 2>/dev/null || true ;;
            *) info "跳过日志清理。" ;;
        esac
    else
        info "journalctl 不可用，跳过。"
    fi

    # ── 7. 清理临时文件 ──────────────────────────────────────────
    echo ""
    info "--- 7/8 清理临时文件 ---"
    safe_run "清理 /tmp" find /tmp -type f -atime +7 -delete 2>/dev/null || true
    safe_run "清理 /var/tmp" find /var/tmp -type f -atime +7 -delete 2>/dev/null || true

    # ── 8. 清理 pip / npm 缓存 ───────────────────────────────────
    echo ""
    info "--- 8/8 清理 pip / npm 缓存 ---"
    command -v pip3 &>/dev/null && safe_run "pip3 缓存" pip3 cache purge 2>/dev/null || true
    command -v pip  &>/dev/null && safe_run "pip 缓存"  pip  cache purge 2>/dev/null || true
    command -v npm  &>/dev/null && safe_run "npm 缓存"  npm  cache clean --force 2>/dev/null || true
    command -v yarn &>/dev/null && safe_run "yarn 缓存" yarn cache clean 2>/dev/null || true

    echo ""
    info "系统清理执行完毕！可使用 'df -h' 查看磁盘释放情况。"
    step_mark_executed "system_cleanup"
}

# ─── 流程内清理 ─────────────────────────────────────────────────────────────
step_cleanup() {
    step_header "清理本次运行临时文件"
    safe_run "删除下载的 BBR 脚本" rm -f "${BACKUP_DIR}/bbr.sh" 2>/dev/null || true
    safe_run "pip 缓存" pip3 cache purge 2>/dev/null || true
    log "备份保留在：$BACKUP_DIR"
    local size
    size=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}') || size="N/A"
    info "备份大小：$size"
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
    echo "  1)  系统信息查询"
    echo "  2)  系统更新 (apt update & upgrade)"
    echo "  3)  安装常用软件包"
    echo "  4)  安装 BBR 拥塞控制"
    echo "  5)  安装 NextTrace"
    echo "  6)  修改 SSH 端口"
    echo "  7)  配置 SSH 密钥（禁用密码登录）"
    echo "  8)  禁止 IPQS 域名"
    echo "  9)  解除 53 端口占用"
    echo "  10) 系统深度清理"
    echo "  a)  全部执行"
    echo "  r)  回滚所有变更"
    echo "  q)  退出"
    echo ""
    echo -e "  可使用环境变量跳过交互："
    echo -e "    ${GREEN}SSH_PORT=2222 SSH_PUBKEY=\"ssh-ed25519 AAAA...\" SSH_DISABLE_PASSWORD=yes${NC}"
    echo ""
    echo -e "  静默模式：${GREEN}sudo ./debian_setup.sh --all${NC}"
    echo -e "  指定步骤：${GREEN}sudo ./debian_setup.sh --step 1,3,10${NC}"
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
        step_sysinfo
        step_system_update
        step_install_packages
        step_install_bbr
        step_install_nexttrace
        step_change_ssh_port
        step_ssh_key_config
        step_block_ipqs
        step_release_port53
        step_system_cleanup
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
                1)  step_sysinfo ;;
                2)  step_system_update ;;
                3)  step_install_packages ;;
                4)  step_install_bbr ;;
                5)  step_install_nexttrace ;;
                6)  step_change_ssh_port ;;
                7)  step_ssh_key_config ;;
                8)  step_block_ipqs ;;
                9)  step_release_port53 ;;
                10) step_system_cleanup ;;
                *)  warn "跳过未知步骤：$s" ;;
            esac
        done
        step_cleanup
        info "完成！备份：$BACKUP_DIR"
        return 0
    fi

    show_menu
    read -r -p "请选择 [1-10,a,r,q]: " choice
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
                    1)  step_sysinfo ;;
                    2)  step_system_update ;;
                    3)  step_install_packages ;;
                    4)  step_install_bbr ;;
                    5)  step_install_nexttrace ;;
                    6)  step_change_ssh_port ;;
                    7)  step_ssh_key_config ;;
                    8)  step_block_ipqs ;;
                    9)  step_release_port53 ;;
                    10) step_system_cleanup ;;
                    *)  warn "跳过未知：$sel" ;;
                esac
            done
            step_cleanup
            info "完成！备份：$BACKUP_DIR"
            ;;
    esac
}

main "$@"
