#!/usr/bin/env bash
# ============================================================================
# Debian/Ubuntu Server Initialization Script — 分步可选，自动回滚
# ============================================================================
# 用法:
#   chmod +x debian_setup.sh
#   sudo ./debian_setup.sh                 # 交互菜单
#   sudo ./debian_setup.sh --all           # 全部执行
#   sudo ./debian_setup.sh --step 1,6,10   # 指定步骤
#   sudo ./debian_setup.sh --rollback      # 回滚
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
step_header() { echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}" ; echo -e "${CYAN}  $*${NC}" ; echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"; }

# ─── 工作区间 ────────────────────────────────────────────────────────────────
BACKUP_DIR="/tmp/init_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
LOG_FILE="${BACKUP_DIR}/setup.log"
ROLLBACK_FILE="${BACKUP_DIR}/rollback.sh"
EXECUTED_STEPS_FILE="${BACKUP_DIR}/executed_steps.txt"
touch "$LOG_FILE" "$ROLLBACK_FILE" "$EXECUTED_STEPS_FILE"

step_mark_executed() { echo "$1" >> "$EXECUTED_STEPS_FILE"; }
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行。请使用 sudo 或以 root 身份执行。"
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
    log "执行: $desc ($*)"
    if "$@" >> "$LOG_FILE" 2>&1; then
        log "OK 完成: $desc"
        return 0
    else
        local ec=$?
        warn "失败: $desc (退出码=$ec)"
        return $ec
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
# 步骤 1: 系统信息查询
# ═══════════════════════════════════════════════════════════════════════════════
step_sysinfo() {
    step_header "步骤 1/10: 系统信息查询"
    log "正在采集系统信息…"

    local pub_ip="" ip4="" ip6="" isp="" country="" city=""
    local json
    json=$(curl -s --max-time 3 https://ipinfo.io 2>/dev/null) || json=""
    if [[ -n "$json" ]]; then
        country=$(echo "$json" | grep '"country"' | awk -F': "' '{print $2}' | tr -d '",')
        city=$(echo "$json" | grep '"city"' | awk -F': "' '{print $2}' | tr -d '",')
        isp=$(echo "$json" | grep '"org"' | awk -F': "' '{print $2}' | tr -d '",')
        pub_ip=$(echo "$json" | grep '"ip"' | awk -F': "' '{print $2}' | tr -d '",')
    fi

    if echo "$isp" | grep -Eiq 'CHINANET|mobile|unicom|telecom'; then
        ip4=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')
    else
        ip4="$pub_ip"
    fi
    ip6=$(curl -s --max-time 2 https://v6.ipinfo.io/ip 2>/dev/null) || ip6=""

    local rx_bytes tx_bytes
    rx_bytes=$(awk 'BEGIN{rx=0} $1~/^(eth|ens|enp|eno)[0-9]+/{rx+=$2} END{printf "%.0f", rx}' /proc/net/dev 2>/dev/null || echo 0)
    tx_bytes=$(awk 'BEGIN{tx=0} $1~/^(eth|ens|enp|eno)[0-9]+/{tx+=$10} END{printf "%.0f", tx}' /proc/net/dev 2>/dev/null || echo 0)

    hr() {
        local b=$1
        if (( b > 1073741824 )); then echo "$(echo "scale=2; $b/1073741824" | bc)G"
        elif (( b > 1048576 )); then echo "$(echo "scale=2; $b/1048576" | bc)M"
        elif (( b > 1024 )); then echo "$(echo "scale=2; $b/1024" | bc)K"
        else echo "${b}B"; fi
    }
    local rx=$(hr "$rx_bytes") tx=$(hr "$tx_bytes")

    local cpu_info=$(lscpu 2>/dev/null | awk -F': +' '/Model name:/ {print $2; exit}') || cpu_info="?"
    local cpu_cores=$(nproc 2>/dev/null) || cpu_cores="?"
    local cpu_stat1=$(grep 'cpu ' /proc/stat 2>/dev/null) || cpu_stat1=""
    local cpu_usage="0"
    if [[ -n "$cpu_stat1" ]]; then
        sleep 0.5 2>/dev/null || true
        local cpu_stat2=$(grep 'cpu ' /proc/stat 2>/dev/null) || cpu_stat2=""
        if [[ -n "$cpu_stat2" ]]; then
            cpu_usage=$(awk '{u=$2+$4;t=$2+$4+$5;if(NR==1){u1=u;t1=t}else printf "%.1f",(($2+$4-u1)*100/(t-t1))}' <(echo "$cpu_stat1") <(echo "$cpu_stat2"))
        fi
    fi
    local cpu_freq=$(grep "MHz" /proc/cpuinfo 2>/dev/null | head -1 | awk '{printf "%.1f GHz", $4/1000}') || cpu_freq="?"
    local cpu_arch=$(uname -m)
    local mem_info=$(free -b 2>/dev/null | awk 'NR==2{printf "%.1f/%.1fM (%.1f%%)", $3/1048576, $2/1048576, $3*100/$2}') || mem_info="?"
    local swap_info=$(free -m 2>/dev/null | awk 'NR==3{if($2==0)printf "0M/0M (0%%)"; else printf "%dM/%dM (%d%%)", $3, $2, $3*100/$2}') || swap_info="?"
    local disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}') || disk_info="?"
    local hostname=$(uname -n)
    local kernel=$(uname -r)
    local os=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"') || os="?"
    local load=$(uptime 2>/dev/null | awk '{print $(NF-2), $(NF-1), $NF}') || load="?"
    local runtime=$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);if(d>0)printf "%dd ",d;if(h>0)printf "%dh ",h;printf "%dm"}' /proc/uptime 2>/dev/null) || runtime="?"
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cc="?"
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null) || qd="?"
    local dns=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null) || dns="?"
    local timezone=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}') || timezone=$(date +%z)
    local now=$(date "+%Y-%m-%d %H:%M")

    echo ""
    echo -e "${CYAN}  主机名:     ${NC}$hostname"
    echo -e "${CYAN}  系统:       ${NC}$os / $kernel / $cpu_arch"
    echo -e "${CYAN}  CPU:        ${NC}$cpu_info (${cpu_cores}c) $cpu_freq 占用${cpu_usage}% 负载$load"
    echo -e "${CYAN}  内存:       ${NC}$mem_info"
    echo -e "${CYAN}  Swap:       ${NC}$swap_info"
    echo -e "${CYAN}  磁盘 /:     ${NC}$disk_info"
    echo -e "${CYAN}  流量:       ${NC}RX $rx / TX $tx"
    echo -e "${CYAN}  算法:       ${NC}$cc $qd"
    echo -e "${CYAN}  运营商:     ${NC}${isp:-N/A}"
    echo -e "${CYAN}  IPv4:       ${NC}${ip4:-N/A}"
    echo -e "${CYAN}  IPv6:       ${NC}${ip6:-N/A}"
    echo -e "${CYAN}  DNS:        ${NC}$dns"
    echo -e "${CYAN}  位置:       ${NC}${country:-?} ${city:-?}"
    echo -e "${CYAN}  时区/时间:  ${NC}$timezone $now"
    echo -e "${CYAN}  运行时长:   ${NC}$runtime"

    step_mark_executed sysinfo
    info "系统信息显示完成。"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 2: 系统更新
# ═══════════════════════════════════════════════════════════════════════════════
step_system_update() {
    step_header "步骤 2/10: 系统更新 (apt)"
    require_root
    if [[ -f /etc/apt/sources.list && ! -f "${BACKUP_DIR}/sources.list.bak" ]]; then
        cp /etc/apt/sources.list "${BACKUP_DIR}/sources.list.bak"
        register_rollback "cp '${BACKUP_DIR}/sources.list.bak' /etc/apt/sources.list"
    fi
    require_run "apt update" apt-get update
    require_run "apt upgrade" apt-get upgrade -y
    require_run "apt dist-upgrade" apt-get dist-upgrade -y
    safe_run "autoremove" apt-get autoremove -y
    step_mark_executed system_update
    info "系统更新完成。"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 3: 安装常用包
# ═══════════════════════════════════════════════════════════════════════════════
step_install_packages() {
    step_header "步骤 3/10: 安装常用软件包"
    require_root
    local pkgs=(curl wget git vim nano htop ca-certificates gnupg lsb-release
        software-properties-common apt-transport-https net-tools iproute2 dnsutils
        traceroute mtr tcpdump nmap socat iperf3 jq python3-pip openssl xxd
        zip unzip p7zip-full bc uuid-runtime dmidecode build-essential psmisc
        lsof sysstat dstat ufw iptables)

    require_run "apt update" apt-get update
    local failed=()
    for pkg in "${pkgs[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            log "已安装: $pkg"
        else
            safe_run "安装 $pkg" apt-get install -y "$pkg" || failed+=("$pkg")
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        safe_run "重试失败包" apt-get --fix-missing install -y "${failed[@]}" || \
            warn "以下软件包安装失败: ${failed[*]}"
    fi
    step_mark_executed install_packages
    info "软件包安装完成。"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 4: BBR
# ═══════════════════════════════════════════════════════════════════════════════
step_install_bbr() {
    step_header "步骤 4/10: 安装 BBR"
    require_root
    local bs="${BACKUP_DIR}/bbr.sh"
    require_run "下载 bbr.sh" wget -q -O "$bs" \
        "https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/2026newconfig/bbr.sh"
    chmod +x "$bs" 2>/dev/null || true

    if [[ -f /etc/sysctl.conf && ! -f "${BACKUP_DIR}/sysctl.conf.bak" ]]; then
        cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.bak"
        register_rollback "cp '${BACKUP_DIR}/sysctl.conf.bak' /etc/sysctl.conf"
    fi

    if ! safe_run "执行 bbr.sh" bash "$bs" 1; then
        warn "BBR 脚本异常，手动写入配置…"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf 2>/dev/null || true
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf 2>/dev/null || true
        sysctl -p 2>/dev/null || true
    fi

    local algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || algo="?"
    if lsmod 2>/dev/null | grep -q tcp_bbr; then
        info "OK BBR 已加载 ($algo)"
    else
        warn "BBR 模块未加载，可能需要重启。当前算法: $algo"
    fi
    step_mark_executed install_bbr
    info "BBR 安装完成。"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 5: NextTrace
# ═══════════════════════════════════════════════════════════════════════════════
step_install_nexttrace() {
    step_header "步骤 5/10: 安装 NextTrace"
    require_root
    if ! safe_run "官方安装" bash -c "$(curl -sL nxtrace.org/nt)"; then
        warn "官方安装失败，尝试备选方案…"
        local arch=$(uname -m)
        [[ "$arch" == "x86_64" ]] && arch="amd64"
        [[ "$arch" == "aarch64" ]] && arch="arm64"
        local url
        url=$(curl -sL "https://api.github.com/repos/nxtrace/NTrace-core/releases/latest" | \
            grep "browser_download_url.*linux_${arch}" | grep -v "sig" | head -1 | cut -d'"' -f4) || url=""
        if [[ -n "$url" ]]; then
            wget -q -O /usr/local/bin/nexttrace "$url" && chmod +x /usr/local/bin/nexttrace
            info "NextTrace 已安装"
        else
            warn "无法获取 NextTrace，可稍后手动安装。"
        fi
    fi
    step_mark_executed install_nexttrace
    info "NextTrace 安装完成。"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 6: 修改 SSH 端口
# ═══════════════════════════════════════════════════════════════════════════════
step_change_ssh_port() {
    step_header "步骤 6/10: 修改 SSH 端口"
    require_root

    if [[ ! -f /etc/ssh/sshd_config ]]; then
        error "未找到 /etc/ssh/sshd_config"
        return 1
    fi

    local current_port
    current_port=$(grep -E '^Port\s+[0-9]' /etc/ssh/sshd_config | tail -1 | awk '{print $2}')
    if ! [[ "$current_port" =~ ^[0-9]+$ ]]; then
        current_port="22"
    fi
    echo -e "当前 SSH 端口: ${YELLOW}${current_port}${NC}"

    local new_port
    if [[ -z "${SSH_PORT:-}" ]]; then
        read -r -p "请输入新的端口号 (1-65535, 留空跳过): " new_port
        new_port="${new_port:-}"
    else
        new_port="$SSH_PORT"
        info "使用环境变量 SSH_PORT=$new_port"
    fi

    if [[ -z "$new_port" ]]; then
        info "跳过。"; return 0
    fi
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        error "无效端口号"; return 1
    fi
    if (( new_port == current_port )); then
        info "端口未变更。"; return 0
    fi

    # 检查端口占用
    if ss -tlnp 2>/dev/null | grep -q ":${new_port} "; then
        warn "端口 $new_port 已被以下进程占用:"
        ss -tlnp 2>/dev/null | grep ":${new_port} "
        read -r -p "仍要继续？(yes/NO): " force_port
        if [[ "${force_port,,}" != "yes" ]]; then
            info "已取消。"; return 1
        fi
    fi

    # 备份
    cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak"
    register_rollback "cp '${BACKUP_DIR}/sshd_config.bak' /etc/ssh/sshd_config"
    register_rollback "systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true"
    log "sshd_config 已备份"

    # 处理 systemd socket activation
    local socket_active=false
    if systemctl is-active ssh.socket 2>/dev/null | grep -q active; then
        socket_active=true
    fi
    if systemctl is-active sshd.socket 2>/dev/null | grep -q active; then
        socket_active=true
    fi
    if $socket_active; then
        info "检测到 socket activation，正在禁用…"
        systemctl stop ssh.socket sshd.socket 2>/dev/null || true
        systemctl disable ssh.socket sshd.socket 2>/dev/null || true
        register_rollback "systemctl enable ssh.socket 2>/dev/null || true; systemctl start ssh.socket 2>/dev/null || true"
        # 创建 /run/sshd (socket 禁用后 systemd 不再自动创建)
        if [[ ! -d /run/sshd ]]; then
            mkdir -p /run/sshd
            chmod 755 /run/sshd
        fi
        if [[ ! -f /etc/tmpfiles.d/sshd.conf ]]; then
            echo 'd /run/sshd 0755 root root' > /etc/tmpfiles.d/sshd.conf
            log "已创建 /etc/tmpfiles.d/sshd.conf"
            register_rollback "rm -f /etc/tmpfiles.d/sshd.conf 2>/dev/null || true"
        fi
        log "socket activation 已禁用，/run/sshd 已创建。"
    fi

    # 修改端口
    sed -i "s/^Port\s\+[0-9].*/Port $new_port/" /etc/ssh/sshd_config
    if ! grep -q "^Port $new_port" /etc/ssh/sshd_config; then
        echo "Port $new_port" >> /etc/ssh/sshd_config
    fi
    log "ssh port $current_port -> $new_port"

    # 防火墙放行
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q active; then
        ufw allow "$new_port/tcp" 2>/dev/null || true
        if ufw status 2>/dev/null | grep -q "$new_port"; then
            info "UFW 已放行 $new_port/tcp"
        else
            warn "UFW 规则可能未生效，请手动检查。"
        fi
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
        firewall-cmd --permanent --add-port="${new_port}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
    if command -v iptables &>/dev/null; then
        local policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}' | tr -d '()')
        if [[ "$policy" == "DROP" || "$policy" == "REJECT" ]]; then
            iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true
            info "iptables 放行规则已添加。"
        fi
    fi

    # 语法检查
    if command -v sshd &>/dev/null; then
        local syntax_err
        syntax_err=$(sshd -t 2>&1) || {
            error "sshd_config 语法错误:"
            echo "$syntax_err" | while IFS= read -r line; do echo "  $line"; done
            warn "回滚…"
            cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
            return 1
        }
        log "sshd_config 语法检查通过。"
    fi

    # 重启 SSH
    local restart_ok=true
    if systemctl restart sshd 2>/dev/null; then
        info "SSH 已重启，端口: $new_port"
    elif service ssh restart 2>/dev/null; then
        info "SSH 已重启 (via service)，端口: $new_port"
    else
        error "SSH 重启失败，systemd 状态:"
        systemctl status sshd --no-pager 2>&1 | head -5 | while IFS= read -r line; do log "  $line"; done
        warn "回滚…"
        cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        return 1
    fi

    # 验证监听
    sleep 2
    local listening
    listening=$(ss -tlnp 2>/dev/null | grep sshd) || listening=""
    if echo "$listening" | grep -q ":${new_port} "; then
        info "OK SSH 已在端口 $new_port 上监听。"
    else
        warn "SSH 未在端口 $new_port 上监听。当前监听状态:"
        if [[ -n "$listening" ]]; then
            echo "$listening" | while IFS= read -r line; do log "  $line"; done
        else
            log "  sshd 当前未监听任何端口"
        fi
        if pgrep -x sshd &>/dev/null; then
            log "  sshd 进程存在"
        else
            log "  sshd 进程不存在"
            systemctl status sshd --no-pager 2>&1 | tail -5 | while IFS= read -r line; do log "  $line"; done
        fi
    fi

    # 确认回滚
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  重要提醒${NC}"
    echo -e "${YELLOW}  1. 保持当前 SSH 会话不要关闭${NC}"
    echo -e "${YELLOW}  2. 另开终端测试: ssh -p $new_port root@<服务器IP>${NC}"
    echo -e "${YELLOW}  3. 如果云商有安全组/防火墙，请手动放行 $new_port${NC}"
    echo -e "${YELLOW}  4. 连接成功后再确认${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
    echo ""

    read -r -p "确认新端口连接正常？(yes/NO): " confirm
    if [[ "$confirm" != "yes" ]]; then
        warn "回滚 SSH 端口…"
        cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        error "已回滚到端口 $current_port。"
        return 1
    fi

    step_mark_executed change_ssh_port
    info "SSH 端口已成功更改为 $new_port。"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 7: SSH 密钥配置
# ═══════════════════════════════════════════════════════════════════════════════
step_ssh_key_config() {
    step_header "步骤 7/10: SSH 密钥配置与禁用密码登录"
    require_root
    local sc="/etc/ssh/sshd_config"
    if [[ ! -f "$sc" ]]; then
        error "未找到 $sc"; return 1
    fi
    if [[ ! -f "${BACKUP_DIR}/sshd_config.bak" ]]; then
        cp "$sc" "${BACKUP_DIR}/sshd_config.bak"
        register_rollback "cp '${BACKUP_DIR}/sshd_config.bak' '$sc'; systemctl restart sshd 2>/dev/null || true"
    fi

    local pubkey="${SSH_PUBKEY:-}"
    if [[ -z "$pubkey" ]]; then
        echo -e "${YELLOW}请粘贴您的 SSH 公钥，新行输入 EOF 结束（直接回车跳过）:${NC}"
        pubkey=""
        while IFS= read -r line; do
            if [[ "$line" == "EOF" ]]; then break; fi
            if [[ -z "$line" && -z "$pubkey" ]]; then break; fi
            pubkey+="$line"$'\n'
        done
        pubkey="$(echo -e "$pubkey" | sed '/^$/d')"
    else
        info "使用环境变量 SSH_PUBKEY 中的公钥。"
    fi

    if [[ -n "$pubkey" ]]; then
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        echo "$pubkey" >> /root/.ssh/authorized_keys
        sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys

        if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
            local uh=$(getent passwd "$SUDO_USER" | cut -d: -f6) || uh="/home/$SUDO_USER"
            if [[ -n "$uh" ]]; then
                mkdir -p "$uh/.ssh"; chmod 700 "$uh/.ssh"
                echo "$pubkey" >> "$uh/.ssh/authorized_keys"
                sort -u "$uh/.ssh/authorized_keys" -o "$uh/.ssh/authorized_keys"
                chmod 600 "$uh/.ssh/authorized_keys"
                chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$uh/.ssh" 2>/dev/null || true
            fi
        fi
        info "SSH 公钥已添加。"
    else
        info "跳过 SSH 公钥添加。"
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
            warn "没有 SSH 公钥，禁用密码可能导致无法登录！"
            read -r -p "仍然继续？(yes/NO): " force
            if [[ "${force,,}" != "yes" ]]; then
                info "已取消。"; return 0
            fi
        fi

        sed -i 's/^#\?PasswordAuthentication\s\+.*/PasswordAuthentication no/' "$sc"
        grep -q '^PasswordAuthentication no' "$sc" || echo 'PasswordAuthentication no' >> "$sc"
        sed -i 's/^#\?ChallengeResponseAuthentication\s\+.*/ChallengeResponseAuthentication no/' "$sc"
        grep -q '^ChallengeResponseAuthentication no' "$sc" || echo 'ChallengeResponseAuthentication no' >> "$sc"
        sed -i 's/^#\?PubkeyAuthentication\s\+.*/PubkeyAuthentication yes/' "$sc"
        grep -q '^PubkeyAuthentication yes' "$sc" || echo 'PubkeyAuthentication yes' >> "$sc"
        sed -i 's/^#\?PermitEmptyPasswords\s\+.*/PermitEmptyPasswords no/' "$sc"

        log "密码登录已禁用，密钥登录已启用。"
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        info "SSH 已重启。"

        echo -e "${YELLOW}请保持当前会话，另开终端测试密钥登录。${NC}"
        read -r -p "确认密钥登录正常？(yes/NO): " confirm
        if [[ "$confirm" != "yes" ]]; then
            warn "回滚…"
            cp "${BACKUP_DIR}/sshd_config.bak" "$sc"
            systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
            error "已回滚。"; return 1
        fi
    else
        info "跳过禁用密码登录。"
    fi

    step_mark_executed ssh_key_config
    info "SSH 密钥配置完成。"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 8: 禁止 IPQS
# ═══════════════════════════════════════════════════════════════════════════════
step_block_ipqs() {
    step_header "步骤 8/10: 禁止 IPQS"
    require_root
    local hosts_file="/etc/hosts"
    local entries=(
        "127.0.0.1 ipqualityscore.com"
        "127.0.0.1 www.ipqualityscore.com"
        "127.0.0.1 api.ipqualityscore.com"
    )
    if [[ ! -f "${BACKUP_DIR}/hosts.bak" ]]; then
        cp "$hosts_file" "${BACKUP_DIR}/hosts.bak"
        register_rollback "cp '${BACKUP_DIR}/hosts.bak' '$hosts_file'"
    fi
    local added=0
    for entry in "${entries[@]}"; do
        if grep -qF "$entry" "$hosts_file" 2>/dev/null; then
            log "已存在: $entry"
        else
            echo "$entry" >> "$hosts_file"
            log "已添加: $entry"
            ((added++))
        fi
    done
    info "IPQS 屏蔽完成（新增 $added 条）。"
    step_mark_executed block_ipqs
}

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 9: 解除 53 端口占用
# ═══════════════════════════════════════════════════════════════════════════════
step_release_port53() {
    step_header "步骤 9/10: 解除 53 端口占用"
    require_root
    local resolved_conf="/etc/systemd/resolved.conf"
    [[ -f "$resolved_conf" ]] || touch "$resolved_conf"

    if [[ ! -f "${BACKUP_DIR}/resolved.conf.bak" ]]; then
        cp "$resolved_conf" "${BACKUP_DIR}/resolved.conf.bak"
        register_rollback "cp '${BACKUP_DIR}/resolved.conf.bak' '$resolved_conf'"
        register_rollback "systemctl restart systemd-resolved || true"
    fi

    if grep -q '^\[Resolve\]' "$resolved_conf" 2>/dev/null; then
        if grep -q '^DNS=' "$resolved_conf"; then
            sed -i 's/^DNS=.*/DNS=8.8.8.8 1.1.1.1/' "$resolved_conf"
        else
            sed -i '/^\[Resolve\]/a DNS=8.8.8.8 1.1.1.1' "$resolved_conf"
        fi
        if grep -q '^DNSStubListener=' "$resolved_conf"; then
            sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' "$resolved_conf"
        else
            sed -i '/^\[Resolve\]/a DNSStubListener=no' "$resolved_conf"
        fi
    else
        cat >> "$resolved_conf" << 'EOL'

[Resolve]
DNS=8.8.8.8 1.1.1.1
DNSStubListener=no
EOL
    fi
    log "已配置 resolved.conf"

    local rl="/etc/resolv.conf"
    if [[ ! -L "$rl" ]]; then
        cp "$rl" "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || true
    fi
    ln -sf /run/systemd/resolve/resolv.conf "$rl" 2>/dev/null || true

    safe_run "重启 systemd-resolved" systemctl restart systemd-resolved

    echo ""
    info "53 端口验证:"
    if command -v lsof &>/dev/null; then
        lsof -i :53 2>/dev/null || echo "  (无进程监听 53)"
    else
        ss -tlnp 2>/dev/null | grep ':53 ' || echo "  (无进程监听 53)"
    fi

    echo ""
    info "DNS 解析测试:"
    safe_run "nslookup" nslookup google.com 8.8.8.8 2>/dev/null || \
        safe_run "dig" dig +short google.com @8.8.8.8 2>/dev/null || \
        warn "DNS 解析测试失败。"

    step_mark_executed release_port53
    info "53 端口配置完成。"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 步骤 10: 系统清理
# ═══════════════════════════════════════════════════════════════════════════════
step_system_cleanup() {
    step_header "步骤 10/10: 系统深度清理"
    require_root

    warn "即将执行系统深度清理: 旧内核、孤立包、apt 缓存、残留配置、日志、临时文件、snap、pip/npm 缓存。"
    local confirm
    read -r -p "确认执行？(yes/NO): " confirm
    if [[ "${confirm,,}" != "yes" ]]; then
        info "跳过。"; return 0
    fi

    # 清理旧内核
    echo ""
    info "--- 1/8 清理旧内核 ---"
    local run_kernel
    run_kernel=$(uname -r | sed 's/-[a-z]*$//; s/-$//')
    log "当前内核: $run_kernel"

    local images=()
    while IFS= read -r pkg; do
        images+=("$pkg")
    done < <(dpkg -l 'linux-image-*' 'linux-image-unsigned-*' 2>/dev/null | awk '/^ii/ {print $2}' | sort -V)

    local to_purge=()
    local keep=1 count=${#images[@]} i=0
    for pkg in "${images[@]}"; do
        local ver
        ver=$(echo "$pkg" | sed 's/^linux-image-//; s/^linux-image-unsigned-//')
        if [[ "$ver" == "$run_kernel" ]]; then
            ((keep++))
        elif (( i < count - keep )); then
            to_purge+=("$pkg")
        fi
        ((i++))
    done

    if [[ ${#to_purge[@]} -gt 0 ]]; then
        log "可清理 ${#to_purge[@]} 个旧内核: ${to_purge[*]}"
        local ck; read -r -p "移除旧内核？(yes/NO): " ck
        if [[ "${ck,,}" == "yes" ]]; then
            safe_run "移除旧内核" apt-get purge -y "${to_purge[@]}"
        fi
    fi

    local headers=()
    while IFS= read -r pkg; do
        headers+=("$pkg")
    done < <(dpkg -l 'linux-headers-*' 2>/dev/null | awk '/^ii/ {print $2}' | sort -V | head -n -1)
    local hdrs_purge=()
    for pkg in "${headers[@]}"; do
        local ver=$(echo "$pkg" | sed 's/^linux-headers-//')
        if [[ "$ver" != "$run_kernel" && "$ver" != "generic" ]]; then
            hdrs_purge+=("$pkg")
        fi
    done
    if [[ ${#hdrs_purge[@]} -gt 0 ]]; then
        safe_run "移除旧 headers" apt-get purge -y "${hdrs_purge[@]}" 2>/dev/null || true
    fi

    # 清理孤立包和缓存
    echo ""; info "--- 2/8 孤立包 ---"; safe_run "autoremove" apt-get autoremove -y
    echo ""; info "--- 3/8 apt 缓存 ---"
    safe_run "autoclean" apt-get autoclean
    safe_run "clean" apt-get clean
    rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true

    # 清理残留配置
    echo ""; info "--- 4/8 残留配置 ---"
    local rc_count
    rc_count=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' | wc -l) || rc_count=0
    if (( rc_count > 0 )); then
        dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg --purge 2>/dev/null || true
        info "已清理 $rc_count 个残留配置包。"
    else
        info "无残留配置。"
    fi

    # 清理 snap
    echo ""; info "--- 5/8 Snap 旧版本 ---"
    if command -v snap &>/dev/null; then
        local disabled
        disabled=$(snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}') || disabled=""
        if [[ -n "$disabled" ]]; then
            echo "$disabled"
            local cs; read -r -p "移除禁用版本？(yes/NO): " cs
            if [[ "${cs,,}" == "yes" ]]; then
                echo "$disabled" | while IFS=' ' read -r name rev; do
                    safe_run "snap remove $name ($rev)" snap remove "$name" --revision="$rev" 2>/dev/null || true
                done
            fi
        else
            info "无可清理的 snap 版本。"
        fi
    else
        info "Snap 未安装，跳过。"
    fi

    # 清理日志
    echo ""; info "--- 6/8 系统日志 ---"
    if command -v journalctl &>/dev/null; then
        local jsize
        jsize=$(journalctl --disk-usage 2>/dev/null | awk '{print $NF}') || jsize="?"
        log "当前日志占用: $jsize"
        echo "  清理模式: 1) 保留 100MB  2) 保留 7 天  3) 跳过"
        local jc; read -r -p "  选择 [1/2/3]: " jc
        case "${jc:-3}" in
            1) journalctl --vacuum-size=100M 2>/dev/null || true ;;
            2) journalctl --vacuum-time=7d 2>/dev/null || true ;;
            *) info "跳过日志清理。" ;;
        esac
    else
        info "journalctl 不可用。"
    fi

    # 清理临时文件
    echo ""; info "--- 7/8 临时文件 ---"
    find /tmp -type f -atime +7 -delete 2>/dev/null || true
    find /var/tmp -type f -atime +7 -delete 2>/dev/null || true

    # 清理 pip/npm 缓存
    echo ""; info "--- 8/8 pip / npm 缓存 ---"
    command -v pip3 &>/dev/null && pip3 cache purge 2>/dev/null || true
    command -v pip &>/dev/null && pip cache purge 2>/dev/null || true
    command -v npm &>/dev/null && npm cache clean --force 2>/dev/null || true
    command -v yarn &>/dev/null && yarn cache clean 2>/dev/null || true

    info "系统清理执行完毕！"
    step_mark_executed system_cleanup
}

# ─── 清理临时文件 ─────────────────────────────────────────────────────────────
step_cleanup() {
    step_header "清理本次运行产生的临时文件"
    rm -f "${BACKUP_DIR}/bbr.sh" 2>/dev/null || true
    local size
    size=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}') || size="?"
    info "备份文件保留在: $BACKUP_DIR ($size)"
}

# ─── 全局回滚 ─────────────────────────────────────────────────────────────────
step_global_rollback() {
    step_header "执行全局回滚"
    require_root
    if [[ ! -f "$ROLLBACK_FILE" ]]; then
        info "无回滚记录。"; return 0
    fi
    local count
    count=$(wc -l < "$ROLLBACK_FILE")
    if (( count == 0 )); then
        info "无回滚操作。"; return 0
    fi
    warn "正在执行 $count 条回滚操作…"
    tac "$ROLLBACK_FILE" | while IFS= read -r cmd; do
        if [[ -n "$cmd" ]]; then
            bash -c "$cmd" >> "$LOG_FILE" 2>&1 || true
        fi
    done
    rm -f "$EXECUTED_STEPS_FILE"
    info "回滚完成。"
}

# ─── 菜单 ─────────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Debian/Ubuntu 服务器初始化脚本${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo "选择步骤（逗号分隔，如 1,2,3）:"
    echo ""
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
    echo ""
    echo "  a)  全部执行"
    echo "  r)  全局回滚"
    echo "  q)  退出"
    echo ""
    echo -e "  环境变量: ${GREEN}SSH_PORT=2222 SSH_PUBKEY=\"...\" SSH_DISABLE_PASSWORD=yes${NC}"
    echo -e "  静默模式: ${GREEN}sudo ./debian_setup.sh --all${NC}"
    echo -e "  指定步骤: ${GREEN}sudo ./debian_setup.sh --step 1,6,10${NC}"
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────
main() {
    require_root
    local run_all=false
    local selected_steps=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)      run_all=true; shift ;;
            --step)     selected_steps="${2:-}"; shift 2 ;;
            --rollback) step_global_rollback; exit 0 ;;
            -h|--help)  show_menu; exit 0 ;;
            *)          error "未知参数: $1"; exit 1 ;;
        esac
    done

    if $run_all; then
        log "全部步骤模式"
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
        info "全部完成！备份文件: $BACKUP_DIR"
        return 0
    fi

    if [[ -n "$selected_steps" ]]; then
        log "指定步骤: $selected_steps"
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
                *)  warn "跳过未知步骤: $s" ;;
            esac
        done
        step_cleanup
        info "完成！备份文件: $BACKUP_DIR"
        return 0
    fi

    # 交互模式
    show_menu
    read -r -p "请选择 [1-10, a, r, q]: " choice
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
                    *)  warn "跳过未知: $sel" ;;
                esac
            done
            step_cleanup
            info "完成！备份文件: $BACKUP_DIR"
            ;;
    esac
}

main "$@"
