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

# ─── 颜色 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step_header() { echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}" ; echo -e "${CYAN}  $*${NC}" ; echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"; }

# ─── 工作区间 ────────────────────────────────────────────────────────────
BACKUP_DIR="/tmp/init_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
LOG_FILE="${BACKUP_DIR}/setup.log"
ROLLBACK_FILE="${BACKUP_DIR}/rollback.sh"
EXECUTED_STEPS_FILE="${BACKUP_DIR}/executed_steps.txt"
touch "$LOG_FILE" "$ROLLBACK_FILE" "$EXECUTED_STEPS_FILE"

step_mark_executed() { echo "$1" >> "$EXECUTED_STEPS_FILE"; }
require_root() {
    [[ $EUID -ne 0 ]] && { error "需要 root 权限。请使用 sudo。"; exit 1; }
}
log() {
    local m="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$m" >> "$LOG_FILE"; echo "$m"
}
safe_run() {
    local d="$1"; shift; log "执行: $d ($*)"
    if "$@" >> "$LOG_FILE" 2>&1; then log "OK: $d"; return 0
    else local e=$?; warn "失败: $d ($e)"; return $e; fi
}
require_run() { local d="$1"; shift; safe_run "$d" "$@" || { error "关键失败，退出。"; exit 1; }; }
register_rollback() { echo "$*" >> "$ROLLBACK_FILE"; }

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 1: 系统信息查询
# ═══════════════════════════════════════════════════════════════════════════
step_sysinfo() {
    step_header "步骤 1/10: 系统信息查询"
    log "正在采集系统信息…"
    local pub_ip="" ip4="" ip6="" isp="" country="" city=""
    local json=$(curl -s --max-time 3 https://ipinfo.io 2>/dev/null) || json=""
    [[ -n "$json" ]] && {
        country=$(echo "$json" | grep '"country"' | awk -F': "' '{print $2}' | tr -d '",')
        city=$(echo "$json" | grep '"city"' | awk -F': "' '{print $2}' | tr -d '",')
        isp=$(echo "$json" | grep '"org"' | awk -F': "' '{print $2}' | tr -d '",')
        pub_ip=$(echo "$json" | grep '"ip"' | awk -F': "' '{print $2}' | tr -d '",')
    }
    if echo "$isp" | grep -Eiq 'CHINANET|mobile|unicom|telecom'; then
        ip4=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || hostname -I 2>/dev/null | awk '{print $1}')
    else ip4="$pub_ip"; fi
    ip6=$(curl -s --max-time 2 https://v6.ipinfo.io/ip 2>/dev/null) || ip6=""
    local rx=$(awk 'BEGIN{rx=0} $1~/^(eth|ens|enp|eno)[0-9]+/{rx+=$2}END{printf "%.0f",rx}' /proc/net/dev 2>/dev/null || echo 0)
    local tx=$(awk 'BEGIN{tx=0} $1~/^(eth|ens|enp|eno)[0-9]+/{tx+=$10}END{printf "%.0f",tx}' /proc/net/dev 2>/dev/null || echo 0)
    hr() { local b=$1; ((b>1073741824)) && echo "$(echo "scale=2; $b/1073741824" | bc)G"; ((b>1048576)) && echo "$(echo "scale=2; $b/1048576" | bc)M"; ((b>1024)) && echo "$(echo "scale=2; $b/1024" | bc)K"; echo "${b}B"; }
    local rx_hr=$(hr "$rx") tx_hr=$(hr "$tx")
    local ci=$(lscpu 2>/dev/null | awk -F': +' '/Model name:/ {print $2; exit}') || ci="?"
    local cc=$(nproc 2>/dev/null) || cc="?"
    local s1=$(grep 'cpu ' /proc/stat 2>/dev/null) || s1=""; local cu="0"
    [[ -n "$s1" ]] && { sleep 0.5 2>/dev/null || true; local s2=$(grep 'cpu ' /proc/stat 2>/dev/null) || s2=""; [[ -n "$s2" ]] && cu=$(awk '{u=$2+$4;t=$2+$4+$5;if(NR==1){u1=u;t1=t}else printf "%.1f",(($2+$4-u1)*100/(t-t1))}' <(echo "$s1") <(echo "$s2")) || cu="0"; }
    local cf=$(grep "MHz" /proc/cpuinfo 2>/dev/null | head -1 | awk '{printf "%.1f GHz",$4/1000}') || cf="?"
    local ca=$(uname -m)
    local mi=$(free -b 2>/dev/null | awk 'NR==2{printf "%.1f/%.1fM (%.1f%%)",$3/1048576,$2/1048576,$3*100/$2}') || mi="?"
    local si=$(free -m 2>/dev/null | awk 'NR==3{if($2==0)printf "0M/0M (0%%)"; else printf "%dM/%dM (%d%%)",$3,$2,$3*100/$2}') || si="?"
    local di=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)",$3,$2,$5}') || di="?"
    local hn=$(uname -n) kv=$(uname -r)
    local os=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"') || os="?"
    local ld=$(uptime 2>/dev/null | awk '{print $(NF-2),$(NF-1),$NF}') || ld="?"
    local rt=$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);if(d>0)printf "%dd ",d;if(h>0)printf "%dh ",h;printf "%dm"}' /proc/uptime 2>/dev/null) || rt="?"
    local cg=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cg="?"
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null) || qd="?"
    local dns=$(awk '/^nameserver/{printf "%s ",$2}' /etc/resolv.conf 2>/dev/null) || dns="?"
    local tz=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}') || tz=$(date +%z)
    local now=$(date "+%Y-%m-%d %H:%M")
    echo "" && echo -e "${CYAN}  主机名:     ${NC}$hn"
    echo -e "${CYAN}  系统:       ${NC}$os / $kv / $ca"
    echo -e "${CYAN}  CPU:        ${NC}$ci (${cc}c) $cf 占用${cu}% 负载$ld"
    echo -e "${CYAN}  内存:       ${NC}$mi"
    echo -e "${CYAN}  Swap:       ${NC}$si"
    echo -e "${CYAN}  磁盘 /:     ${NC}$di"
    echo -e "${CYAN}  流量:       ${NC}RX $rx_hr / TX $tx_hr"
    echo -e "${CYAN}  算法:       ${NC}$cg $qd"
    echo -e "${CYAN}  运营商:     ${NC}${isp:-N/A}"
    echo -e "${CYAN}  IPv4:       ${NC}${ip4:-N/A}"
    echo -e "${CYAN}  IPv6:       ${NC}${ip6:-N/A}"
    echo -e "${CYAN}  DNS:        ${NC}$dns"
    echo -e "${CYAN}  位置:       ${NC}${country:-?} ${city:-?}"
    echo -e "${CYAN}  时区/时间:  ${NC}$tz $now"
    echo -e "${CYAN}  运行时长:   ${NC}$rt"
    step_mark_executed sysinfo; info "完成。"
}

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 2: 系统更新
# ═══════════════════════════════════════════════════════════════════════════
step_system_update() {
    step_header "步骤 2/10: 系统更新"
    require_root
    [[ -f /etc/apt/sources.list && ! -f "${BACKUP_DIR}/sources.list.bak" ]] && {
        cp /etc/apt/sources.list "${BACKUP_DIR}/sources.list.bak"
        register_rollback "cp '${BACKUP_DIR}/sources.list.bak' /etc/apt/sources.list"
    }
    require_run "apt update" apt-get update
    require_run "apt upgrade" apt-get upgrade -y
    require_run "apt dist-upgrade" apt-get dist-upgrade -y
    safe_run "autoremove" apt-get autoremove -y
    step_mark_executed system_update; info "完成。"
}

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 3: 安装常用包
# ═══════════════════════════════════════════════════════════════════════════
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
        dpkg -s "$pkg" &>/dev/null && log "已安装: $pkg" || { safe_run "安装 $pkg" apt-get install -y "$pkg" || failed+=("$pkg"); }
    done
    [[ ${#failed[@]} -gt 0 ]] && { safe_run "重试" apt-get --fix-missing install -y "${failed[@]}" || warn "失败: ${failed[*]}"; }
    step_mark_executed install_packages; info "完成。"
}

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 4: BBR
# ═══════════════════════════════════════════════════════════════════════════
step_install_bbr() {
    step_header "步骤 4/10: 安装 BBR"
    require_root
    local bs="${BACKUP_DIR}/bbr.sh"
    require_run "下载 bbr.sh" wget -q -O "$bs" "https://raw.githubusercontent.com/Snorbo/public/refs/heads/main/2026newconfig/bbr.sh"
    chmod +x "$bs" 2>/dev/null || true
    [[ -f /etc/sysctl.conf && ! -f "${BACKUP_DIR}/sysctl.conf.bak" ]] && {
        cp /etc/sysctl.conf "${BACKUP_DIR}/sysctl.conf.bak"
        register_rollback "cp '${BACKUP_DIR}/sysctl.conf.bak' /etc/sysctl.conf"
    }
    safe_run "执行 bbr.sh" bash "$bs" 1 || {
        warn "脚本异常，手动写入…"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf 2>/dev/null || true
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf 2>/dev/null || true
        sysctl -p 2>/dev/null || true
    }
    local algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || algo="?"
    lsmod 2>/dev/null | grep -q tcp_bbr && info "OK BBR 已加载 ($algo)" || warn "BBR 未加载，需重启。当前: $algo"
    step_mark_executed install_bbr; info "完成。"
}

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 5: NextTrace
# ═══════════════════════════════════════════════════════════════════════════
step_install_nexttrace() {
    step_header "步骤 5/10: 安装 NextTrace"
    require_root
    safe_run "官方安装" bash -c "$(curl -sL nxtrace.org/nt)" || {
        warn "官方失败，备选…"
        local arch=$(uname -m); [[ "$arch" == "x86_64" ]] && arch="amd64"; [[ "$arch" == "aarch64" ]] && arch="arm64"
        local url=$(curl -sL "https://api.github.com/repos/nxtrace/NTrace-core/releases/latest" | grep "browser_download_url.*linux_${arch}" | grep -v "sig" | head -1 | cut -d'"' -f4) || url=""
        [[ -n "$url" ]] && { wget -q -O /usr/local/bin/nexttrace "$url" && chmod +x /usr/local/bin/nexttrace && info "已安装"; } || warn "无法获取。"
    }
    step_mark_executed install_nexttrace; info "完成。"
}

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 6: 修改 SSH 端口
# ═══════════════════════════════════════════════════════════════════════════
step_change_ssh_port() {
    step_header "步骤 6/10: 修改 SSH 端口"
    require_root
    [[ ! -f /etc/ssh/sshd_config ]] && { error "未找到 sshd_config"; return 1; }

    local cur=$(grep -E '^Port\s+[0-9]' /etc/ssh/sshd_config | tail -1 | awk '{print $2}')
    [[ "$cur" =~ ^[0-9]+$ ]] || cur="22"
    echo -e "当前端口: ${YELLOW}$cur${NC}"

    local new_port
    [[ -n "${SSH_PORT:-}" ]] && new_port="$SSH_PORT" || {
        read -r -p "新端口 (1-65535, 留空跳过): " new_port; new_port="${new_port:-}"
    }
    [[ -z "$new_port" ]] && { info "跳过。"; return 0; }
    [[ "$new_port" =~ ^[0-9]+$ ]] || { error "无效端口。"; return 1; }
    (( new_port >= 1 && new_port <= 65535 )) || { error "端口范围 1-65535。"; return 1; }
    (( new_port == cur )) && { info "未变更。"; return 0; }

    ss -tlnp 2>/dev/null | grep -q ":${new_port} " && {
        warn "端口 $new_port 被占用:"
        ss -tlnp 2>/dev/null | grep ":${new_port} "
        read -r -p "继续？(yes/NO): " fp; [[ "${fp,,}" != "yes" ]] && { info "已取消。"; return 1; }
    }

    cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak"
    register_rollback "cp '${BACKUP_DIR}/sshd_config.bak' /etc/ssh/sshd_config; systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true"
    log "已备份"

    # ── 确保 /run/sshd 存在（sshd privilege separation 必需）──
    # socket 禁用后或重启后 /run/sshd 可能消失（tmpfs），此处无条件重建
    if [[ ! -d /run/sshd ]]; then
        mkdir -p /run/sshd; chmod 755 /run/sshd; log "已创建 /run/sshd"
    fi
    if [[ ! -f /etc/tmpfiles.d/sshd.conf ]]; then
        echo 'd /run/sshd 0755 root root' > /etc/tmpfiles.d/sshd.conf
        log "已创建 /etc/tmpfiles.d/sshd.conf"
    fi

    # ── 处理 systemd socket activation ──
    local sa=false
    systemctl is-active ssh.socket 2>/dev/null | grep -q active && sa=true
    systemctl is-active sshd.socket 2>/dev/null | grep -q active && sa=true
    if $sa; then
        info "检测到 socket activation，正在禁用…"
        systemctl stop ssh.socket sshd.socket 2>/dev/null || true
        systemctl disable ssh.socket sshd.socket 2>/dev/null || true
        register_rollback "systemctl enable ssh.socket 2>/dev/null || true; systemctl start ssh.socket 2>/dev/null || true"
        log "socket activation 已禁用。"
    fi

    # ── 修改端口 ──
    sed -i "s/^Port\s\+[0-9].*/Port $new_port/" /etc/ssh/sshd_config
    grep -q "^Port $new_port" /etc/ssh/sshd_config || echo "Port $new_port" >> /etc/ssh/sshd_config
    log "端口 $cur -> $new_port"

    # ── 防火墙放行 ──
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q active && {
        ufw allow "$new_port/tcp" 2>/dev/null || true
        ufw status 2>/dev/null | grep -q "$new_port" && info "UFW 已放行" || warn "UFW 可能未生效。"
    }
    command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running && {
        firewall-cmd --permanent --add-port="${new_port}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    }
    command -v iptables &>/dev/null && {
        local policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}' | tr -d '()')
        [[ "$policy" == "DROP" || "$policy" == "REJECT" ]] && { iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true; info "iptables 已放行。"; }
    }

    # ── 语法检查 + 重启 ──
    command -v sshd &>/dev/null && {
        local serr=$(sshd -t 2>&1) || {
            error "sshd_config 语法错误:"; echo "$serr" | while IFS= read -r line; do echo "  $line"; done
            warn "回滚…"; cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config; return 1
        }
        log "语法检查通过。"
    }
    local ok=true
    systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || ok=false
    $ok || {
        error "SSH 重启失败"; systemctl status sshd --no-pager 2>&1 | head -5 | while IFS= read -r line; do log "  $line"; done
        cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config; return 1
    }
    info "SSH 已重启"
    sleep 2
    local ls=$(ss -tlnp 2>/dev/null | grep sshd) || ls=""
    grep -q ":${new_port} " <<<"$ls" && info "OK 监听 $new_port" || {
        warn "未监听 $new_port:"; [[ -n "$ls" ]] && echo "$ls" | while IFS= read -r line; do log "  $line"; done || log "  sshd 无监听"
        pgrep -x sshd &>/dev/null && log "  pid 存在" || { log "  pid 不存在"; systemctl status sshd --no-pager 2>&1 | tail -3 | while IFS= read -r line; do log "  $line"; done; }
    }

    # ── 确认回滚 ──
    echo ""; echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  保持会话, 测试: ssh -p $new_port root@<IP>${NC}"
    echo -e "${YELLOW}  云商安全组请手动放行 $new_port${NC}"
    echo -e "${YELLOW}  连接成功后输入 yes${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════${NC}"
    read -r -p "确认？(yes/NO): " cf
    [[ "$cf" != "yes" ]] && {
        warn "回滚…"; cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        error "已回滚到 $cur"; return 1
    }
    step_mark_executed change_ssh_port; info "SSH 端口已改为 $new_port。"
}

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 7: SSH 密钥配置
# ═══════════════════════════════════════════════════════════════════════════
step_ssh_key_config() {
    step_header "步骤 7/10: SSH 密钥与禁用密码"
    require_root
    local sc="/etc/ssh/sshd_config"
    [[ ! -f "$sc" ]] && { error "未找到 $sc"; return 1; }
    [[ ! -f "${BACKUP_DIR}/sshd_config.bak" ]] && {
        cp "$sc" "${BACKUP_DIR}/sshd_config.bak"
        register_rollback "cp '${BACKUP_DIR}/sshd_config.bak' '$sc'; systemctl restart sshd 2>/dev/null || true"
    }
    local pubkey="${SSH_PUBKEY:-}"
    if [[ -z "$pubkey" ]]; then
        echo -e "${YELLOW}粘贴公钥，新行 EOF 结束 (回车跳过):${NC}"
        pubkey=""; while IFS= read -r line; do
            [[ "$line" == "EOF" ]] && break; [[ -z "$line" && -z "$pubkey" ]] && break; pubkey+="$line"$'\n'
        done
        pubkey="$(echo -e "$pubkey" | sed '/^$/d')"
    else info "使用 SSH_PUBKEY 环境变量。"; fi
    [[ -n "$pubkey" ]] && {
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        echo "$pubkey" >> /root/.ssh/authorized_keys; sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
        [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && {
            local uh=$(getent passwd "$SUDO_USER" | cut -d: -f6) || uh="/home/$SUDO_USER"
            [[ -n "$uh" ]] && { mkdir -p "$uh/.ssh"; chmod 700 "$uh/.ssh"; echo "$pubkey" >> "$uh/.ssh/authorized_keys"; sort -u "$uh/.ssh/authorized_keys" -o "$uh/.ssh/authorized_keys"; chmod 600 "$uh/.ssh/authorized_keys"; chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$uh/.ssh" 2>/dev/null || true; }
        }
        info "公钥已添加。"
    } || info "跳过。"
    local dp="${SSH_DISABLE_PASSWORD:-}"; [[ -z "$dp" ]] && { read -r -p "禁用密码登录？(yes/NO): " dp; dp="${dp:-no}"; }
    if [[ "${dp,,}" == "yes" || "${dp,,}" == "y" ]]; then
        local kc=$(wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo 0)
        ((kc)) || { warn "无公钥!"; read -r -p "继续？(yes/NO): " fd; [[ "${fd,,}" != "yes" ]] && { info "取消。"; return 0; }; }
        sed -i 's/^#\?PasswordAuthentication\s\+.*/PasswordAuthentication no/' "$sc"; grep -q '^PasswordAuthentication no' "$sc" || echo 'PasswordAuthentication no' >> "$sc"
        sed -i 's/^#\?ChallengeResponseAuthentication\s\+.*/ChallengeResponseAuthentication no/' "$sc"; grep -q '^ChallengeResponseAuthentication no' "$sc" || echo 'ChallengeResponseAuthentication no' >> "$sc"
        sed -i 's/^#\?PubkeyAuthentication\s\+.*/PubkeyAuthentication yes/' "$sc"; grep -q '^PubkeyAuthentication yes' "$sc" || echo 'PubkeyAuthentication yes' >> "$sc"
        sed -i 's/^#\?PermitEmptyPasswords\s\+.*/PermitEmptyPasswords no/' "$sc"
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        info "SSH 已重启。"
        echo -e "${YELLOW}另开终端测试密钥后确认${NC}"
        read -r -p "确认？(yes/NO): " ck
        [[ "$ck" != "yes" ]] && { cp "${BACKUP_DIR}/sshd_config.bak" "$sc"; systemctl restart sshd 2>/dev/null || true; error "已回滚"; return 1; }
    else info "跳过。"; fi
    step_mark_executed ssh_key_config; info "完成。"
}

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 8: 禁止 IPQS
# ═══════════════════════════════════════════════════════════════════════════
step_block_ipqs() {
    step_header "步骤 8/10: 禁止 IPQS"; require_root
    local hf="/etc/hosts"; local es=("127.0.0.1 ipqualityscore.com" "127.0.0.1 www.ipqualityscore.com" "127.0.0.1 api.ipqualityscore.com")
    [[ ! -f "${BACKUP_DIR}/hosts.bak" ]] && { cp "$hf" "${BACKUP_DIR}/hosts.bak"; register_rollback "cp '${BACKUP_DIR}/hosts.bak' '$hf'"; }
    local a=0; for e in "${es[@]}"; do grep -qF "$e" "$hf" 2>/dev/null && log "已有 $e" || { echo "$e" >> "$hf"; log "添加 $e"; ((a++)); }; done
    info "新增 $a 条。"; step_mark_executed block_ipqs
}

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 9: 解除 53 端口占用
# ═══════════════════════════════════════════════════════════════════════════
step_release_port53() {
    step_header "步骤 9/10: 解除 53 端口占用"; require_root
    local rc="/etc/systemd/resolved.conf"; [[ -f "$rc" ]] || touch "$rc"
    [[ ! -f "${BACKUP_DIR}/resolved.conf.bak" ]] && { cp "$rc" "${BACKUP_DIR}/resolved.conf.bak"; register_rollback "cp '${BACKUP_DIR}/resolved.conf.bak' '$rc'; systemctl restart systemd-resolved || true"; }
    if grep -q '^\[Resolve\]' "$rc" 2>/dev/null; then
        grep -q '^DNS=' "$rc" && sed -i 's/^DNS=.*/DNS=8.8.8.8 1.1.1.1/' "$rc" || sed -i '/^\[Resolve\]/a DNS=8.8.8.8 1.1.1.1' "$rc"
        grep -q '^DNSStubListener=' "$rc" && sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' "$rc" || sed -i '/^\[Resolve\]/a DNSStubListener=no' "$rc"
    else cat >> "$rc" << 'EOL'

[Resolve]
DNS=8.8.8.8 1.1.1.1
DNSStubListener=no
EOL
    fi
    log "已配置 resolved.conf"
    local rl="/etc/resolv.conf"; [[ -L "$rl" ]] || cp "$rl" "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || true
    ln -sf /run/systemd/resolve/resolv.conf "$rl" 2>/dev/null || true
    safe_run "重启 systemd-resolved" systemctl restart systemd-resolved
    echo ""; info "53 端口:"; command -v lsof &>/dev/null && lsof -i :53 2>/dev/null || ss -tlnp 2>/dev/null | grep ':53 ' || echo "  (无)"
    echo ""; info "DNS:"; safe_run "nslookup" nslookup google.com 8.8.8.8 2>/dev/null || safe_run "dig" dig +short google.com @8.8.8.8 2>/dev/null || warn "DNS 测试失败。"
    step_mark_executed release_port53; info "完成。"
}

# ═══════════════════════════════════════════════════════════════════════════
# 步骤 10: 系统清理
# ═══════════════════════════════════════════════════════════════════════════
step_system_cleanup() {
    step_header "步骤 10/10: 系统深度清理"; require_root
    warn "清理: 旧内核/孤立包/缓存/残留配置/日志/tmp/snap/pip/npm"
    local c; read -r -p "确认？(yes/NO): " c; [[ "${c,,}" != "yes" ]] && { info "跳过。"; return 0; }
    local rk=$(uname -r | sed 's/-[a-z]*$//;s/-$//'); log "当前内核: $rk"
    local imgs=(); while IFS= read -r p; do imgs+=("$p"); done < <(dpkg -l 'linux-image-*' 'linux-image-unsigned-*' 2>/dev/null | awk '/^ii/{print$2}' | sort -V)
    local purge=() keep=1 cnt=${#imgs[@]} i=0
    for p in "${imgs[@]}"; do local v=$(echo "$p" | sed 's/^linux-image-//;s/^linux-image-unsigned-//'); [[ "$v" == "$rk" ]] && ((keep++)); ((i < cnt - keep)) && purge+=("$p"); ((i++)); done
    [[ ${#purge[@]} -gt 0 ]] && { log "可清理 ${#purge[@]} 个"; local ck; read -r -p "移除？(yes/NO): " ck; [[ "${ck,,}" == "yes" ]] && safe_run "移除内核" apt-get purge -y "${purge[@]}" || info "跳过。"; }
    local hdrs=(); while IFS= read -r p; do hdrs+=("$p"); done < <(dpkg -l 'linux-headers-*' 2>/dev/null | awk '/^ii/{print$2}' | sort -V | head -n -1)
    local hp=(); for p in "${hdrs[@]}"; do local v=$(echo "$p" | sed 's/^linux-headers-//'); [[ "$v" != "$rk" && "$v" != "generic" ]] && hp+=("$p"); done
    [[ ${#hp[@]} -gt 0 ]] && safe_run "移除 headers" apt-get purge -y "${hp[@]}" 2>/dev/null || true
    echo ""; info "--- 2/8 孤立包 ---"; safe_run "autoremove" apt-get autoremove -y
    echo ""; info "--- 3/8 apt 缓存 ---"; safe_run "autoclean" apt-get autoclean; safe_run "clean" apt-get clean; rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
    echo ""; info "--- 4/8 残留配置 ---"
    local rc=$(dpkg -l 2>/dev/null | awk '/^rc/{print$2}' | wc -l) || rc=0
    ((rc)) && { dpkg -l | awk '/^rc/{print$2}' | xargs -r dpkg --purge 2>/dev/null || true; info "已清理 $rc 个。"; } || info "无残留。"
    echo ""; info "--- 5/8 Snap ---"
    command -v snap &>/dev/null && { local sn=$(snap list --all 2>/dev/null | awk '/disabled/{print$1,$3}') || sn=""; [[ -n "$sn" ]] && { echo "$sn"; local cs; read -r -p "移除？(yes/NO): " cs; [[ "${cs,,}" == "yes" ]] && echo "$sn" | while IFS=' ' read -r n r; do safe_run "snap $n ($r)" snap remove "$n" --revision="$r" 2>/dev/null || true; done; }; } || info "Snap 未安装。"
    echo ""; info "--- 6/8 日志 ---"
    command -v journalctl &>/dev/null && { local js=$(journalctl --disk-usage 2>/dev/null | awk '{print$NF}') || js="?"; log "日志: $js"; echo "1)100MB 2)7天 3)跳过"; local jc; read -r -p "选择 [1/2/3]: " jc; case "${jc:-3}" in 1) journalctl --vacuum-size=100M 2>/dev/null || true;; 2) journalctl --vacuum-time=7d 2>/dev/null || true;; *) info "跳过。"; esac; } || info "无 journalctl。"
    echo ""; info "--- 7/8 临时文件 ---"; find /tmp /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    echo ""; info "--- 8/8 缓存 ---"
    command -v pip3 &>/dev/null && pip3 cache purge 2>/dev/null || true; command -v pip &>/dev/null && pip cache purge 2>/dev/null || true
    command -v npm &>/dev/null && npm cache clean --force 2>/dev/null || true; command -v yarn &>/dev/null && yarn cache clean 2>/dev/null || true
    info "完成。"; step_mark_executed system_cleanup
}

# ─── 清理 ─────────────────────────────────────────────────────────────────
step_cleanup() {
    step_header "清理临时文件"; rm -f "${BACKUP_DIR}/bbr.sh" 2>/dev/null || true
    local s=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}') || s="?"; info "备份 $s ($BACKUP_DIR)"
}

# ─── 回滚 ─────────────────────────────────────────────────────────────────
step_global_rollback() {
    step_header "全局回滚"; require_root
    [[ ! -f "$ROLLBACK_FILE" ]] && { info "无记录。"; return 0; }
    local cnt=$(wc -l < "$ROLLBACK_FILE"); ((cnt)) || { info "无操作。"; return 0; }
    warn "执行 $cnt 条回滚…"
    tac "$ROLLBACK_FILE" | while IFS= read -r cmd; do [[ -n "$cmd" ]] && bash -c "$cmd" >> "$LOG_FILE" 2>&1 || true; done
    rm -f "$EXECUTED_STEPS_FILE"; info "回滚完成。"
}

# ─── 菜单 ─────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Debian/Ubuntu 服务器初始化脚本${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo "选择步骤 (逗号分隔, 如 1,2,3):"
    echo "  1) 系统信息    2) 系统更新    3) 软件包"
    echo "  4) BBR         5) NextTrace   6) SSH 端口"
    echo "  7) SSH 密钥    8) 禁止 IPQS   9) 53 端口"
    echo "  10) 系统清理"
    echo "  a) 全部执行    r) 回滚    q) 退出"
    echo ""
    echo -e "  环境变量: ${GREEN}SSH_PORT=2222 SSH_PUBKEY=\"...\" SSH_DISABLE_PASSWORD=yes${NC}"
    echo -e "  静默: ${GREEN}sudo ./debian_setup.sh --all${NC}"
    echo -e "  指定: ${GREEN}sudo ./debian_setup.sh --step 1,6,10${NC}"
}

# ─── 主流程 ───────────────────────────────────────────────────────────────
main() {
    require_root; local all=false sel=""
    while [[ $# -gt 0 ]]; do
        case "$1" in --all) all=true;; --step) sel="${2:-}"; shift;; --rollback) step_global_rollback; exit 0;; -h|--help) show_menu; exit 0;; esac; shift
    done
    if $all; then
        log "全部步骤"; step_sysinfo; step_system_update; step_install_packages; step_install_bbr; step_install_nexttrace
        step_change_ssh_port; step_ssh_key_config; step_block_ipqs; step_release_port53; step_system_cleanup
        step_cleanup; info "完成！备份: $BACKUP_DIR"; return 0
    fi
    if [[ -n "$sel" ]]; then
        log "步骤 $sel"; IFS=',' read -ra S <<< "$sel"
        for s in "${S[@]}"; do s="$(echo "$s" | xargs)"
            case "$s" in 1) step_sysinfo;; 2) step_system_update;; 3) step_install_packages;; 4) step_install_bbr;; 5) step_install_nexttrace;; 6) step_change_ssh_port;; 7) step_ssh_key_config;; 8) step_block_ipqs;; 9) step_release_port53;; 10) step_system_cleanup;; *) warn "跳过 $s";; esac
        done; step_cleanup; info "完成！备份: $BACKUP_DIR"; return 0
    fi
    show_menu; read -r -p "选择 [1-10,a,r,q]: " choice
    case "$choice" in a|A) main --all;; r|R) step_global_rollback;; q|Q) info "退出。"; exit 0;;
        *) IFS=',; ' read -ra S <<< "$choice"; for s in "${S[@]}"; do s="$(echo "$s" | xargs)"
            case "$s" in 1) step_sysinfo;; 2) step_system_update;; 3) step_install_packages;; 4) step_install_bbr;; 5) step_install_nexttrace;; 6) step_change_ssh_port;; 7) step_ssh_key_config;; 8) step_block_ipqs;; 9) step_release_port53;; 10) step_system_cleanup;; *) warn "跳过 $s";; esac
        done; step_cleanup; info "完成！备份: $BACKUP_DIR";;
    esac
}

main "$@"
