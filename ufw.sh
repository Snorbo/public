#!/bin/bash
# ============================================================
# UFW 初始化脚本（安全版）
# 平台：Debian 12/13、Ubuntu 22.04/24.04
#
# 为什么要有这个版本：
#   原版脚本的顺序是 ufw reset -> 放行固定端口 -> ufw enable，
#   而放行列表里没有 SSH 端口。只要 SSH 不在被放行的端口上，
#   执行完就会立刻被锁在门外（当前连接断开、重连被拒），只能靠 VNC 补救。
#
# 本版本的原则：
#   1. 先探测 sshd「实际生效」的 SSH 端口（sshd -T，兼容 sshd_config.d 里的 Port），
#      并把它放到放行列表的最前面 —— 先放行 SSH，再启用防火墙
#   2. 默认不再执行 ufw reset（reset 会清空已有规则，可能弄断 VPN/其它服务）。
#      需要清空时显式传 --reset
#   3. 启用前二次确认，并打印将要放行的端口，避免"手滑 enable"
#   4. 失败时给出明确的补救命令（ufw disable），不会让人无从下手
#
# 用法：
#   sudo bash ufw.sh              # 安装并放行 SSH + 常用端口，然后启用（保留已有规则）
#   sudo bash ufw.sh --reset      # 先清空已有规则再配置
#   sudo bash ufw.sh --check      # 只显示将要执行的动作，不做任何修改
#   sudo bash ufw.sh --help
#
# 退出码：0 成功 / 1 失败 / 2 参数错误
# ============================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 需要放行的端口。SSH 端口会在运行时探测并插到最前面。
# 说明：如果这些端口里没有你实际在用的，请自行增删。
PORTS_TO_ALLOW=(53 80 323 443 1556 1555)

DO_RESET='no'
CHECK_ONLY='no'

info() { echo -e "${BLUE}$1${NC}"; }
ok()   { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }
err()  { echo -e "${RED}$1${NC}" >&2; }

die() {
    err "错误：$1"
    exit 1
}

usage() {
    cat <<'EOF'
用法:
  sudo bash ufw.sh             安装并放行 SSH + 常用端口，然后启用（保留已有规则）
  sudo bash ufw.sh --reset     先执行 ufw reset 清空已有规则，再按上述配置
  sudo bash ufw.sh --check     只打印将要执行的动作，不做任何修改
  sudo bash ufw.sh --help

说明:
  脚本会先用 `sshd -T` 读取 sshd 实际生效的 Port，并优先放行它，
  因此在非 22 端口上运行 SSH 的机器也不会被锁在门外。
  如果探测不到 sshd 配置，脚本会要求你手工确认端口，而不是猜一个。
EOF
}

for arg in "$@"; do
    case "$arg" in
        --reset) DO_RESET='yes' ;;
        --check|--dry-run) CHECK_ONLY='yes' ;;
        -h|--help) usage; exit 0 ;;
        *) err "未知参数：$arg"; usage; exit 2 ;;
    esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die '请以 root 运行（sudo bash ufw.sh）'
fi

# ---------- 1. 探测 SSH 实际生效端口 ----------
detect_ssh_ports() {
    local ports=''
    if command -v sshd >/dev/null 2>&1; then
        # 优先用 sshd -T：它会解析 Include/drop-in，给出真正生效的值
        ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')"
    fi
    if [ -z "${ports//[[:space:]]/}" ]; then
        # 回退：直接解析配置文件（含 drop-in）
        ports="$(grep -rhsE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
            /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null \
            | awk '{print $2}' | sort -un | tr '\n' ' ')"
    fi
    # 统一为「单空格分隔、首尾无空格」，避免调用方的参数展开歧义
    printf '%s' "$ports" | xargs echo
}

SSH_PORTS=()
while IFS= read -r _p; do
    case "$_p" in
        ''|*[!0-9]*) ;;
        *) SSH_PORTS+=("$_p") ;;
    esac
done < <(detect_ssh_ports | tr ' ' '\n')

echo
info '=== UFW 安全初始化 ==='

if [ "${#SSH_PORTS[@]}" -eq 0 ]; then
    warn '无法自动探测 SSH 端口（sshd 未安装或配置不可读）。'
    echo '  为避免把你自己锁在门外，脚本不会猜测端口。'
    echo '  请先确认 SSH 端口，例如执行：'
    echo '    sshd -T | grep -i "^port"'
    echo '    ss -tlnp | grep sshd'
    echo '  然后手动放行后重跑本脚本：ufw allow <你的SSH端口>/tcp'
    die '未能确定 SSH 端口，已中止（未做任何修改）。'
fi

SSH_PORT_LIST="${SSH_PORTS[*]}"
ok "探测到 SSH 端口：${SSH_PORT_LIST}"

# ---------- 2. 先放行 SSH（在任何启停动作之前）----------
allow_ssh_ports() {
    local p rc=0
    for p in "${SSH_PORTS[@]}"; do
        case "$p" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            warn "跳过非法端口：$p"
            continue
        fi
        if [ "$CHECK_ONLY" = 'yes' ]; then
            echo "  [预演] ufw allow ${p}/tcp   # SSH"
            continue
        fi
        if ufw allow "${p}/tcp" >/dev/null 2>&1; then
            ok "  已放行 SSH 端口 ${p}/tcp"
        else
            err "  放行 SSH 端口 ${p}/tcp 失败"
            rc=1
        fi
    done
    return "$rc"
}

# ---------- 3. 安装 ufw ----------
install_ufw() {
    if command -v ufw >/dev/null 2>&1; then
        ok "ufw 已安装：$(command -v ufw)"
        return 0
    fi
    info '正在更新软件包列表并安装 ufw ...'
    if ! apt-get update; then
        warn 'apt-get update 失败，仍尝试安装。'
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ufw; then
        die 'ufw 安装失败，请检查 apt 源后重试。'
    fi
    command -v ufw >/dev/null 2>&1 || die '安装命令已完成但仍找不到 ufw，请人工确认。'
    ok 'ufw 安装完成'
}

# ---------- 4. 主流程 ----------
install_ufw

echo
info '将要执行的动作：'
echo "  1) 放行 SSH 端口：${SSH_PORT_LIST}/tcp        <-- 必须在启用之前"
if [ "$DO_RESET" = 'yes' ]; then
    echo "  2) ufw reset                <-- 会清空已有规则（你用了 --reset）"
else
    echo "  2) 保留已有规则（未使用 --reset）"
fi
echo "  3) 放行端口：${PORTS_TO_ALLOW[*]}"
echo "  4) ufw enable               <-- 默认策略 deny incoming"

if [ "$CHECK_ONLY" = 'yes' ]; then
    echo
    echo '  [预演] ufw default deny incoming'
    echo '  [预演] ufw default allow outgoing'
    for p in "${PORTS_TO_ALLOW[@]}"; do echo "  [预演] ufw allow ${p}"; done
    echo '  [预演] ufw --force enable'
    echo
    ok '--check 模式：未做任何修改。'
    exit 0
fi

echo
warn '注意：启用 UFW 后，只有上面列出的端口可访问。'
warn '如果你还跑着 VPN/其它自定义端口，请先 Ctrl+C 中止，把它们加进脚本里的 PORTS_TO_ALLOW。'
if ! read -r -p '确认继续？(y/N): ' ans; then
    echo '已取消。'
    exit 1
fi
if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo '已取消。'
    exit 1
fi

# 4.1 先放行 SSH（无论后续哪一步失败，SSH 通道都已经保住）
echo
info '步骤 1/4：放行 SSH 端口（先做这一步）'
allow_ssh_ports || warn '有 SSH 端口放行失败，请手动检查后再继续。'

# 4.2 可选：清空已有规则
if [ "$DO_RESET" = 'yes' ]; then
    info '步骤 2/4：ufw reset（清空已有规则）'
    if ufw --force reset; then
        ok '  已重置规则'
        # reset 会清掉刚加的 SSH 规则，必须重加
        info '  重置后重新放行 SSH 端口'
        allow_ssh_ports || warn '  重新放行 SSH 失败，请手动执行 ufw allow <端口>/tcp'
    else
        die 'ufw reset 失败，已中止（未启用防火墙）。'
    fi
else
    info '步骤 2/4：保留已有规则（未使用 --reset）'
fi

# 4.3 放行其它端口
info '步骤 3/4：放行常用端口'
for p in "${PORTS_TO_ALLOW[@]}"; do
    if ufw allow "$p" >/dev/null 2>&1; then
        ok "  已放行 ${p}"
    else
        warn "  放行 ${p} 失败（可忽略，或手动执行 ufw allow ${p}）"
    fi
done

# 4.4 启用
echo
info '步骤 4/4：设置默认策略并启用防火墙'
ufw default deny incoming >/dev/null 2>&1 || warn '设置 deny incoming 失败'
ufw default allow outgoing >/dev/null 2>&1 || warn '设置 allow outgoing 失败'

if ! ufw --force enable; then
    err 'ufw enable 失败。'
    err '当前防火墙未启用，可安全重试；如需彻底关闭请执行：ufw disable'
    exit 1
fi

# ---------- 5. 结果自检 ----------
echo
ufw status verbose || true
echo

if ufw status 2>/dev/null | grep -q '^Status: active'; then
    ok 'UFW 已启用。'
else
    err 'UFW 未显示为 active，请检查上面的输出。'
    exit 1
fi

# 逐条确认 SSH 端口确实在放行列表里
# ufw status 的规则行形如「22/tcp  ALLOW  Anywhere」，用 awk 取第 1 列精确比较，
# 避免 grep 正则把 2222 误判成 22。
allowed_specs="$(ufw status 2>/dev/null | awk '/ALLOW/ {print $1}')"
missing=''
for p in "${SSH_PORTS[@]}"; do
    if printf '%s\n' "$allowed_specs" | grep -qxE "${p}(/tcp)?"; then
        continue
    fi
    missing="${missing} ${p}"
done
if [ -n "$missing" ]; then
    err "以下 SSH 端口未在放行列表中确认到：${missing}"
    err '★ 请勿关闭当前会话！先执行下面任一命令保住连接：'
    err '    ufw allow <端口>/tcp      # 补放行'
    err '    ufw disable               # 紧急关闭防火墙'
    exit 1
fi
ok "SSH 端口已在放行列表中：${SSH_PORT_LIST}"

echo
warn '重要：请保持当前 SSH 会话不要关闭，另开一个新终端验证能登录后再退出。'
echo "  若新终端连不上，可在当前会话执行：ufw disable"
echo
ok '配置完成。'
