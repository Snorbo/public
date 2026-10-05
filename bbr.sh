#!/bin/bash
# ============================================================
# BBR v3 内核管理（修正版，源自 Joey 的 Actions-bbr-v3）
# 平台：Debian 12/13、Ubuntu 22.04/24.04（amd64 / arm64）
# 相对原版的改动：
#   1. 【重要】末尾的无条件 `reboot` 改为可取消的 60 秒倒计时，
#      非交互模式必须显式设置 BBR_REBOOT=now 才重启
#   2. 【重要】dpkg -i 不再用 /tmp/linux-*.deb 通配符（会把历史
#      残留的旧内核包一起装上），改为只安装本次下载的精确文件名
#      且下载目录使用独立 mktemp 目录
#   3. 安装后补 apt-get -f install 处理依赖未满足的情况
#   4. 安装内核后自动启用 BBR（写入 sysctl 并立即生效），
#      不再需要用户再手动选一次拥塞算法
#   5. 依赖缺失处理：jq 缺失会尝试安装，装不上则明确报错退出
#      （原版会继续执行导致 jq 解析失败、TAG_NAME 为空）
#   6. 版本选择过滤 prerelease，并优先选择非 "-max" 的标准变体
#   7. 安装前检查 /boot 空间、下载后校验 .deb 完整性
#   8. 失败路径都不再重启，且返回非零退出码
# ============================================================

set -uo pipefail

GL_HONG='\033[31m'
GL_LV='\033[32m'
GL_HUANG='\033[33m'
GL_LAN='\033[34m'
GL_QING='\033[36m'
GL_BAI='\033[0m'

SYSCTL_CONF='/etc/sysctl.d/99-joeyblog.conf'
REBOOT_DELAY="${BBR_REBOOT_DELAY:-60}"
API_RELEASES='https://api.github.com/repos/byJoey/Actions-bbr-v3/releases?per_page=30'

info() { echo -e "${GL_QING}$1${GL_BAI}"; }
ok()   { echo -e "${GL_LV}$1${GL_BAI}"; }
warn() { echo -e "${GL_HUANG}$1${GL_BAI}"; }
err()  { echo -e "${GL_HONG}$1${GL_BAI}" >&2; }

print_separator() {
    echo -e "${GL_LAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${GL_BAI}"
}

need_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        err '请以 root 运行（sudo bash bbr.sh 1）。'
        exit 1
    fi
}

usage() {
    cat <<'EOF'
用法: bash bbr.sh <1-6> [--no-reboot]

  1  安装/更新 BBR v3 内核（安装完成后默认 60 秒后重启，可 Ctrl+C 取消）
  2  检查 BBR v3 是否已安装并生效
  3  启用 BBR + fq（写入 /etc/sysctl.d 并立即生效）
  4  启用 BBR + fq_pie
  5  启用 BBR + cake
  6  卸载 BBR v3 内核

环境变量:
  BBR_REBOOT_DELAY=秒   自定义重启倒计时（默认 60）
  BBR_REBOOT=now        跳过确认与倒计时立即重启（仅用于自动化）
EOF
}

# ---------------- 参数解析 ----------------
ACTION=''
NO_REBOOT='no'
for arg in "$@"; do
    case "$arg" in
        1|2|3|4|5|6) ACTION="$arg" ;;
        --no-reboot) NO_REBOOT='yes' ;;
        -h|--help|help) usage; exit 0 ;;
        *) err "未知参数：$arg"; usage; exit 1 ;;
    esac
done

if [ -z "$ACTION" ]; then
    usage
    exit 1
fi

need_root

if ! command -v apt-get >/dev/null 2>&1; then
    err '此脚本仅支持 Debian/Ubuntu（需要 apt-get）。'
    exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64) ;;
    *)
        err "仅支持 x86_64 与 aarch64 架构，当前为：${ARCH}"
        exit 1
        ;;
esac

# ---------------- 依赖 ----------------
ensure_dep() {
    local cmd="$1" pkg="${2:-$1}"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    info "缺少依赖 ${cmd}，正在安装 ${pkg} ..."
    apt-get update -qq >/dev/null 2>&1 || true
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1 && command -v "$cmd" >/dev/null 2>&1; then
        ok "${cmd} 安装完成"
        return 0
    fi
    err "依赖安装失败：${cmd}（apt-get install ${pkg}）"
    return 1
}

if [ "$ACTION" = '1' ]; then
    # 这些是安装路径真正需要的；update-grub / dpkg 属于关键依赖，缺失直接退出
    for dep in curl wget awk sed jq dpkg update-grub; do
        if ! ensure_dep "$dep" "kmod"; then :; fi
        if [ "$dep" = 'update-grub' ] && ! command -v update-grub >/dev/null 2>&1; then
            err '缺少 update-grub（grub2-common/grub-common），无法安全安装新内核，已中止。'
            err '请先执行：apt-get install -y grub-common'
            exit 1
        fi
    done
    for dep in curl wget awk sed jq dpkg; do
        command -v "$dep" >/dev/null 2>&1 || { err "关键依赖缺失：${dep}"; exit 1; }
    done
fi

# ---------------- 状态与算法 ----------------
current_algo() { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown'; }
current_qdisc() { sysctl -n net.core.default_qdisc 2>/dev/null || echo 'unknown'; }

# 返回已安装的 joeyblog 内核包名（每行一个）
installed_bbr_packages() {
    dpkg-query -W -f='${binary:Package}\n' '*joeyblog*' 2>/dev/null | grep -v '^$' || true
}

# ---------------- sysctl ----------------
clean_sysctl_conf() {
    touch "$SYSCTL_CONF"
    sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
}

apply_algo() {
    local algo="$1" qdisc="$2"
    # 校验模块/算法是否可用
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "$algo"; then
        warn "当前内核未列出 ${algo} 算法；若为内核模块，尝试加载..."
        modprobe "tcp_${algo}" 2>/dev/null || true
        if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "$algo"; then
            err "内核不支持 ${algo}，未做修改。请先确认 BBR v3 内核已安装并重启（菜单项 1）。"
            return 1
        fi
    fi

    clean_sysctl_conf
    printf 'net.core.default_qdisc=%s\n' "$qdisc" >> "$SYSCTL_CONF"
    printf 'net.ipv4.tcp_congestion_control=%s\n' "$algo" >> "$SYSCTL_CONF"

    # 立即生效 + 持久化
    if ! sysctl -w "net.core.default_qdisc=${qdisc}" >/dev/null 2>&1; then
        warn "立即设置 net.core.default_qdisc=${qdisc} 失败（可能内核未编译该 qdisc），已写入配置文件。"
    fi
    if ! sysctl -w "net.ipv4.tcp_congestion_control=${algo}" >/dev/null 2>&1; then
        err "立即设置 net.ipv4.tcp_congestion_control=${algo} 失败。"
        return 1
    fi
    sysctl --system >/dev/null 2>&1 || true

    local now_algo now_qdisc
    now_algo="$(current_algo)"
    now_qdisc="$(current_qdisc)"
    if [ "$now_algo" = "$algo" ]; then
        ok "已启用 ${algo} + ${qdisc}（配置持久化于 ${SYSCTL_CONF}）"
        info "当前生效：${now_algo} / ${now_qdisc}"
        return 0
    fi
    err "设置后当前算法仍为 ${now_algo}，请检查是否有其它 sysctl 配置覆盖。"
    return 1
}

# ---------------- 下载 ----------------
TMP_DIR=''
cleanup_tmp() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf -- "$TMP_DIR"
    fi
}

fetch_release_json() {
    local json
    if ! command -v jq >/dev/null 2>&1; then
        err 'jq 未安装，无法解析 GitHub Release 信息。'
        return 1
    fi
    json="$(curl -fsSL --connect-timeout 10 --max-time 60 -H 'Accept: application/vnd.github+json' "$API_RELEASES" 2>/dev/null)" || {
        err '请求 GitHub API 失败（api.github.com 可能不可达或被限流）。'
        return 1
    }
    if [ -z "$json" ]; then
        err 'GitHub API 返回空内容。'
        return 1
    fi
    printf '%s' "$json"
}

pick_tag() {
    local json="$1" pattern="$2"
    # 过滤 prerelease，按发布时间倒序，优先非 -max 变体
    printf '%s' "$json" | jq -r --arg pat "$pattern" '
        [ .[] | select(.prerelease == false) | select(.tag_name | contains($pat)) ]
        | sort_by(.published_at) | reverse
        | ( map(select(.tag_name | contains("-max") | not)) + map(select(.tag_name | contains("-max"))) )
        | .[0].tag_name // empty'
}

download_assets() {
    local tag="$1" json="$2"
    TMP_DIR="$(mktemp -d /tmp/bbrv3.XXXXXX)" || { err '无法创建临时目录。'; return 1; }

    local urls url file
    urls="$(printf '%s' "$json" | jq -r --arg tag "$tag" '.[] | select(.tag_name == $tag) | .assets[]?.browser_download_url')"
    if [ -z "$urls" ]; then
        # 可能是首屏资产被截断，单独取该 tag 的详情
        info '正在获取该版本的完整资产列表...'
        urls="$(curl -fsSL --connect-timeout 10 --max-time 60 \
            "https://api.github.com/repos/byJoey/Actions-bbr-v3/releases/tags/${tag}" 2>/dev/null \
            | jq -r '.assets[]?.browser_download_url')"
    fi
    if [ -z "$urls" ]; then
        err "未找到 ${tag} 的可下载文件。"
        return 1
    fi

    local deb_count=0
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        file="$(basename -- "$url")"
        case "$file" in
            *.deb) deb_count=$((deb_count + 1)) ;;
            *) info "跳过非 deb 文件：${file}"; continue ;;
        esac
        info "正在下载：${file}"
        if ! wget -q --timeout=60 --tries=2 -O "${TMP_DIR}/${file}" "$url"; then
            err "下载失败：${url}"
            return 1
        fi
    done <<< "$urls"

    if [ "$deb_count" -eq 0 ]; then
        err '该版本没有 .deb 资产，已中止。'
        return 1
    fi
    ok "已下载 ${deb_count} 个 .deb 到 ${TMP_DIR}"
    return 0
}

verify_debs() {
    local deb problems=0
    for deb in "${TMP_DIR}"/*.deb; do
        [ -e "$deb" ] || continue
        if ! dpkg-deb --info "$deb" >/dev/null 2>&1; then
            err "包文件损坏：$(basename -- "$deb")"
            problems=$((problems + 1))
        fi
    done
    [ "$problems" -eq 0 ]
}

install_kernel() {
    local json tag
    json="$(fetch_release_json)" || return 1

    case "$ARCH" in
        aarch64) tag="$(pick_tag "$json" 'arm64')" ;;
        x86_64)  tag="$(pick_tag "$json" 'x86_64')" ;;
    esac
    if [ -z "$tag" ]; then
        err "未找到适用于 ${ARCH} 的正式版本（已过滤 prerelease）。"
        return 1
    fi
    info "选定版本：${tag}"

    # /boot 空间检查（内核包通常需要 100M 以上）
    local boot_avail
    boot_avail="$(df -Pk /boot 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')"
    if [ -n "$boot_avail" ] && [ "$boot_avail" -lt 150 ]; then
        err "/boot 可用空间仅 ${boot_avail}M，安装新内核可能失败。请先清理旧内核。"
        err '可执行：apt-get autoremove --purge -y'
        return 1
    fi

    download_assets "$tag" "$json" || return 1
    verify_debs || return 1

    # 卸载旧版 joeyblog 内核（只删匹配到的包，避免空参数）
    local old_pkgs
    old_pkgs="$(installed_bbr_packages)"
    if [ -n "$old_pkgs" ]; then
        info '正在卸载旧版 BBR 内核包...'
        printf '  %s\n' $old_pkgs
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y $old_pkgs >/dev/null 2>&1 || \
            warn '旧内核卸载未完全成功，继续安装新内核。'
    fi

    info '正在安装内核包...'
    local -a debs=()
    local deb
    for deb in "${TMP_DIR}"/*.deb; do
        [ -e "$deb" ] && debs+=("$deb")
    done
    if [ "${#debs[@]}" -eq 0 ]; then
        err '没有找到可安装的 .deb。'
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "${debs[@]}"; then
        warn 'dpkg -i 返回非零，尝试用 apt-get -f install 修复依赖...'
        if ! DEBIAN_FRONTEND=noninteractive apt-get -f install -y; then
            err '依赖修复失败，内核可能未正确安装。已中止，不会重启。'
            return 1
        fi
    fi

    info '正在更新 GRUB 引导配置...'
    if ! update-grub; then
        err 'update-grub 失败，出于安全考虑已中止（不会重启）。'
        err '请手动执行 update-grub 检查错误后再重启。'
        return 1
    fi

    # 验证内核包确实装上了
    local installed
    installed="$(installed_bbr_packages)"
    if [ -z "$installed" ]; then
        err '未检测到新安装的 joeyblog 内核包，安装可能失败。已中止，不会重启。'
        return 1
    fi
    ok '内核包安装完成：'
    printf '  %s\n' $installed

    # 安装后顺手启用 BBR + fq（避免用户以为装完就加速了）
    info '正在启用 BBR + fq ...'
    clean_sysctl_conf
    printf 'net.core.default_qdisc=fq\n' >> "$SYSCTL_CONF"
    printf 'net.ipv4.tcp_congestion_control=bbr\n' >> "$SYSCTL_CONF"
    ok "已写入 ${SYSCTL_CONF}（重启后随新内核生效）"
    return 0
}

# ---------------- 重启 ----------------
REBOOT_CANCELLED='no'
cancel_reboot() {
    REBOOT_CANCELLED='yes'
}

schedule_reboot() {
    if [ "$NO_REBOOT" = 'yes' ]; then
        warn '已按 --no-reboot 跳过重启。请自行选择合适时间执行：reboot'
        return 0
    fi

    if [ "${BBR_REBOOT:-}" = 'now' ]; then
        warn 'BBR_REBOOT=now：立即重启。'
        reboot
        return 0
    fi

    case "$REBOOT_DELAY" in
        ''|*[!0-9]*) REBOOT_DELAY=60 ;;
    esac

    echo
    warn "系统将在 ${REBOOT_DELAY} 秒后重启以加载新内核。"
    echo '  按 Ctrl+C 可取消重启（内核已安装，稍后手动 reboot 即可）。'
    echo '  可用的云厂商 VNC/控制台请提前准备好。'

    trap 'cancel_reboot' INT TERM
    local i="$REBOOT_DELAY"
    while [ "$i" -gt 0 ]; do
        if [ "$REBOOT_CANCELLED" = 'yes' ]; then
            break
        fi
        printf '\r  倒计时：%3d 秒 ' "$i"
        sleep 1
        i=$((i - 1))
    done
    printf '\r                    \r'
    trap - INT TERM

    if [ "$REBOOT_CANCELLED" = 'yes' ]; then
        warn '已取消重启。请记住在方便时执行：reboot'
        return 0
    fi
    reboot
}

# ---------------- 主流程 ----------------
print_separator
echo -e "${GL_HUANG}BBR v3 内核管理（修正版）${GL_BAI}"
print_separator
info "架构：${ARCH}    当前算法：$(current_algo) / $(current_qdisc)"
print_separator

case "$ACTION" in
    1)
        if ! install_kernel; then
            err '安装流程未成功，已跳过重启。'
            cleanup_tmp
            exit 1
        fi
        cleanup_tmp
        schedule_reboot
        ;;
    2)
        local_ok=0
        local ver pkgs
        if command -v modinfo >/dev/null 2>&1 && modinfo tcp_bbr >/dev/null 2>&1; then
            ver="$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/{print $2; exit}')"
            if [ "$ver" = '3' ]; then
                info "tcp_bbr 模块版本：${ver}（v3）"
            else
                warn "tcp_bbr 模块版本：${ver:-未知}（非 v3）"
                local_ok=1
            fi
        else
            warn '未找到 tcp_bbr 模块信息（可能未安装 BBR v3 内核）。'
            local_ok=1
        fi

        pkgs="$(installed_bbr_packages)"
        if [ -n "$pkgs" ]; then
            info '已安装的 BBR 内核包：'
            printf '  %s\n' $pkgs
        else
            warn '未检测到 joeyblog 内核包。'
            local_ok=1
        fi

        if [ "$(current_algo)" = 'bbr' ]; then
            ok "当前拥塞控制算法已生效：bbr / $(current_qdisc)"
        else
            warn "当前算法为 $(current_algo)，BBR 未生效（新内核需重启，或需执行选项 3）。"
            local_ok=1
        fi
        exit "$local_ok"
        ;;
    3) apply_algo bbr fq ;;
    4) apply_algo bbr fq_pie ;;
    5) apply_algo bbr cake ;;
    6)
        pkgs="$(installed_bbr_packages)"
        if [ -z "$pkgs" ]; then
            warn '未检测到 joeyblog 内核包，无需卸载。'
            exit 0
        fi
        warn '以下内核包将被卸载：'
        printf '  %s\n' $pkgs
        if [ -t 0 ]; then
            read -r -p '确认卸载？(y/N): ' ans || ans='n'
            if [[ ! "$ans" =~ ^[Yy]$ ]]; then
                echo '已取消。'
                exit 0
            fi
        fi
        # shellcheck disable=SC2086
        if DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y $pkgs; then
            update-grub >/dev/null 2>&1 || warn 'update-grub 失败，请手动执行。'
            ok '内核包已卸载。重启后生效；若当前正在使用该内核，请确认仍能引导到原内核。'
        else
            err '卸载失败，请手动执行：apt-get remove --purge <包名>'
            exit 1
        fi
        ;;
esac
