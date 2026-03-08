#!/usr/bin/env bash
###############################################################################
# debian-netboot-prepare.sh
#
# 一键准备 Debian netboot 重装环境（非全自动安装）
#   - 自动检测环境（BIOS/UEFI、网络、依赖）
#   - 交互选择 Debian 12 bookworm / 13 trixie
#   - 交互配置网络（IPv4/IPv6）、账户、SSH、内核
#   - 下载并校验 netboot 内核与 initrd
#   - 生成 preseed 文件
#   - 写入 GRUB 菜单项（仅下一次启动生效）
#   - 重启前显示完整摘要并二次确认
#
# 用法:  sudo bash debian-netboot-prepare.sh
#
# 风险提示:
#   1. 本脚本会修改 /etc/grub.d/40_custom 并执行 update-grub
#   2. 使用 grub-reboot 设置一次性启动
#   3. 重启后将进入 Debian 安装器（通过 VNC 手动完成安装）
#   4. 分区和最终 bootloader 安装目标由用户在 VNC 中手动决定
#
# 取消下次启动进入安装器:
#   sudo grub-reboot 0
#   # 或删除 /etc/grub.d/40_custom 中的 netboot 条目后 sudo update-grub
###############################################################################

set -euo pipefail

# =============================================================================
# 全局常量
# =============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly NETBOOT_DIR="/boot/debian-netboot"
readonly PRESEED_FILE="/boot/debian-netboot/preseed.cfg"
readonly GRUB_CUSTOM="/etc/grub.d/40_custom"
readonly GRUB_CUSTOM_BACKUP="/etc/grub.d/40_custom.bak.$(date +%Y%m%d%H%M%S)"
readonly GRUB_MENUENTRY_ID="debian-netboot-installer"
readonly LOG_FILE="/var/log/debian-netboot-prepare.log"

# Debian 镜像基础 URL（优先 HTTPS）
readonly DEB12_BASE="https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64"
readonly DEB13_BASE="https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64"
# 校验文件 URL
readonly DEB12_SUMS_BASE="https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images"
readonly DEB13_SUMS_BASE="https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images"

# =============================================================================
# 用户选择变量（脚本运行时填充）
# =============================================================================
DEBIAN_VERSION=""       # 12 或 13
DEBIAN_CODENAME=""      # bookworm 或 trixie
BOOT_MODE=""            # bios 或 uefi
DOWNLOAD_TOOL=""        # wget 或 curl

# 网络配置
NET_MODE=""             # ipv4 / ipv6 / dual
NET_IFACE=""
IPV4_ADDR="" ; IPV4_GW="" ; IPV4_MASK="" ; IPV4_PREFIX=""
IPV6_ADDR="" ; IPV6_GW="" ; IPV6_PREFIX=""
DNS_SERVERS=""
HOSTNAME_NEW=""

# 账户
USER_STRATEGY=""        # root_only / create_user
NORMAL_USER=""
ROOT_PW_HASH=""
USER_PW_HASH=""

# SSH
SSH_PORT="22"
SSH_PUBKEYS=""
SSH_ROOT_POLICY=""      # pubkey_only / password_allowed

# 内核
INSTALL_CLOUD_KERNEL="" # yes / no
ENABLE_BACKPORTS=""     # yes / no (仅 Debian 12)

# =============================================================================
# 日志函数
# =============================================================================
log_info()  { echo -e "\033[32m[INFO]\033[0m  $*"; echo "[INFO]  $(date '+%F %T') $*" >> "$LOG_FILE"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; echo "[WARN]  $(date '+%F %T') $*" >> "$LOG_FILE"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*"; echo "[ERROR] $(date '+%F %T') $*" >> "$LOG_FILE"; }
log_step()  { echo ""; echo -e "\033[36m========== $* ==========\033[0m"; echo "[STEP]  $(date '+%F %T') $*" >> "$LOG_FILE"; }

die() {
    log_error "$*"
    echo ""
    echo "脚本已终止。请检查上面的错误信息。"
    exit 1
}

# =============================================================================
# 辅助函数
# =============================================================================

# 带默认值的交互输入
# 注意：显示内容走 stderr，只有返回值走 stdout（供 $() 捕获）
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local result
    if [[ -n "$default" ]]; then
        read -rp "${prompt} [${default}]: " result
        echo "${result:-$default}"
    else
        read -rp "${prompt}: " result
        echo "$result"
    fi
}

# 带重试的必填输入
prompt_required() {
    local prompt="$1"
    local result=""
    while [[ -z "$result" ]]; do
        read -rp "${prompt}: " result
        [[ -z "$result" ]] && echo "  ⚠ 此项不能为空，请重新输入。" >&2
    done
    echo "$result"
}

# 选择菜单（返回选项编号）
# 菜单和错误提示走 stderr，只有最终编号走 stdout
prompt_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice=""
    while true; do
        echo "$prompt" >&2
        for i in "${!options[@]}"; do
            echo "  $((i+1)). ${options[$i]}" >&2
        done
        read -rp "请输入编号 [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "$choice"
            return 0
        fi
        echo "  ⚠ 无效选择，请重新输入。" >&2
    done
}

# 安全密码输入（带确认）
# 提示和错误走 stderr，只有最终哈希走 stdout
prompt_password() {
    local label="$1"
    local pw1 pw2
    while true; do
        read -rsp "请输入 ${label} 密码: " pw1; echo "" >&2
        if [[ -z "$pw1" ]]; then
            echo "  ⚠ 密码不能为空。" >&2
            continue
        fi
        if [[ ${#pw1} -lt 8 ]]; then
            echo "  ⚠ 密码长度建议至少 8 位，当前 ${#pw1} 位。确定使用？(y/N)" >&2
            local confirm
            read -r confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                continue
            fi
        fi
        read -rsp "请再次输入 ${label} 密码: " pw2; echo "" >&2
        if [[ "$pw1" == "$pw2" ]]; then
            # 使用 mkpasswd 或 openssl 生成 SHA-512 哈希
            local hash
            if command -v mkpasswd &>/dev/null; then
                hash=$(mkpasswd -m sha-512 "$pw1")
            elif command -v openssl &>/dev/null; then
                local salt
                salt=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
                hash=$(openssl passwd -6 -salt "$salt" "$pw1")
            else
                die "无法找到 mkpasswd 或 openssl 来生成密码哈希"
            fi
            # 清除明文（bash 中无法完全保证，但至少不保留在变量中）
            pw1=""; pw2=""
            echo "$hash"
            return 0
        fi
        echo "  ⚠ 两次密码不一致，请重新输入。" >&2
    done
}

# 检查命令是否存在
require_cmd() {
    command -v "$1" &>/dev/null || return 1
}

# =============================================================================
# 第一阶段：前置检查
# =============================================================================
check_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 权限运行本脚本：sudo bash $SCRIPT_NAME"
}

check_os() {
    if [[ ! -f /etc/debian_version ]]; then
        die "本脚本仅支持在 Debian/Ubuntu 系统上运行（未找到 /etc/debian_version）"
    fi
    log_info "当前系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
}

detect_boot_mode() {
    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE="uefi"
    else
        BOOT_MODE="bios"
    fi
    log_info "启动模式: ${BOOT_MODE^^}"
}

detect_download_tool() {
    if require_cmd wget; then
        DOWNLOAD_TOOL="wget"
    elif require_cmd curl; then
        DOWNLOAD_TOOL="curl"
    else
        DOWNLOAD_TOOL=""
    fi
}

install_dependencies() {
    log_step "安装必要依赖"

    local pkgs_to_install=()

    # wget 或 curl 至少需要一个
    if ! require_cmd wget && ! require_cmd curl; then
        pkgs_to_install+=(wget)
    fi

    # grub 工具
    if ! require_cmd update-grub; then
        if [[ "$BOOT_MODE" == "uefi" ]]; then
            pkgs_to_install+=(grub-efi-amd64)
        else
            pkgs_to_install+=(grub-pc)
        fi
    fi

    # grub-reboot 需要 grub-common（通常已装）
    if ! require_cmd grub-reboot; then
        pkgs_to_install+=(grub-common)
    fi

    # mkpasswd（在 whois 包中）或 openssl
    if ! require_cmd mkpasswd && ! require_cmd openssl; then
        pkgs_to_install+=(whois)
    fi

    if (( ${#pkgs_to_install[@]} > 0 )); then
        log_info "需要安装: ${pkgs_to_install[*]}"
        apt-get update -qq || die "apt-get update 失败"
        apt-get install -y -qq "${pkgs_to_install[@]}" || die "依赖安装失败: ${pkgs_to_install[*]}"
    else
        log_info "所有依赖已满足"
    fi

    # 重新检测下载工具
    detect_download_tool
    [[ -n "$DOWNLOAD_TOOL" ]] || die "下载工具不可用（需要 wget 或 curl）"
    log_info "下载工具: $DOWNLOAD_TOOL"

    # 最终验证关键命令
    require_cmd update-grub || die "update-grub 不可用"
    require_cmd grub-reboot || die "grub-reboot 不可用"
}

# =============================================================================
# 第二阶段：检测网络
# =============================================================================
detect_network() {
    log_step "检测当前网络配置"

    # 检测默认网卡
    NET_IFACE=$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' || true)
    if [[ -z "$NET_IFACE" ]]; then
        # 尝试 IPv6
        NET_IFACE=$(ip -o -6 route get 2001:4860:4860::8888 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' || true)
    fi
    if [[ -z "$NET_IFACE" ]]; then
        # 最后尝试第一个非 lo 接口
        NET_IFACE=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}' | tr -d ' ')
    fi
    [[ -n "$NET_IFACE" ]] || die "无法检测到网络接口"
    log_info "网络接口: $NET_IFACE"

    # IPv4
    IPV4_ADDR=$(ip -4 addr show dev "$NET_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1 | cut -d/ -f1 || true)
    IPV4_PREFIX=$(ip -4 addr show dev "$NET_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1 | cut -d/ -f2 || true)
    IPV4_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || true)

    # 将 CIDR 前缀转为子网掩码
    if [[ -n "$IPV4_PREFIX" ]]; then
        IPV4_MASK=$(python3 -c "
import ipaddress, sys
try:
    n = ipaddress.IPv4Network('0.0.0.0/${IPV4_PREFIX}')
    print(str(n.netmask))
except Exception:
    print('')
" 2>/dev/null || true)
    fi

    # IPv6（排除 link-local fe80::）
    IPV6_ADDR=$(ip -6 addr show dev "$NET_IFACE" scope global 2>/dev/null | awk '/inet6/{print $2}' | head -1 | cut -d/ -f1 || true)
    IPV6_PREFIX=$(ip -6 addr show dev "$NET_IFACE" scope global 2>/dev/null | awk '/inet6/{print $2}' | head -1 | cut -d/ -f2 || true)
    IPV6_GW=$(ip -6 route show default 2>/dev/null | awk '{print $3; exit}' || true)

    # DNS
    DNS_SERVERS=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null | xargs || true)
    if [[ -z "$DNS_SERVERS" ]]; then
        DNS_SERVERS="8.8.8.8 8.8.4.4"
    fi

    # Hostname
    HOSTNAME_NEW=$(hostname 2>/dev/null || echo "debian")

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        当前检测到的网络配置               ║"
    echo "╠══════════════════════════════════════════╣"
    echo "║ 网络接口:  $NET_IFACE"
    echo "║ IPv4 地址: ${IPV4_ADDR:-(未检测到)}"
    echo "║ IPv4 掩码: ${IPV4_MASK:-(未检测到)}  (/${IPV4_PREFIX:-?})"
    echo "║ IPv4 网关: ${IPV4_GW:-(未检测到)}"
    echo "║ IPv6 地址: ${IPV6_ADDR:-(未检测到)}"
    echo "║ IPv6 前缀: ${IPV6_PREFIX:-(未检测到)}"
    echo "║ IPv6 网关: ${IPV6_GW:-(未检测到)}"
    echo "║ DNS:       ${DNS_SERVERS:-(未检测到)}"
    echo "║ Hostname:  ${HOSTNAME_NEW}"
    echo "╚══════════════════════════════════════════╝"
    echo ""
}

# =============================================================================
# 第三阶段：用户交互配置
# =============================================================================

choose_debian_version() {
    log_step "选择 Debian 版本"
    local c
    c=$(prompt_choice "请选择要安装的 Debian 版本:" "Debian 12 (bookworm) — 当前稳定版" "Debian 13 (trixie) — 当前测试版")
    if [[ "$c" == "1" ]]; then
        DEBIAN_VERSION="12"
        DEBIAN_CODENAME="bookworm"
    else
        DEBIAN_VERSION="13"
        DEBIAN_CODENAME="trixie"
    fi
    log_info "已选择: Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
}

configure_network_interactive() {
    log_step "配置网络参数"

    # 选择网络模式
    local c
    c=$(prompt_choice "请选择网络配置模式:" "仅 IPv4" "仅 IPv6" "IPv4 + IPv6（双栈）")
    case "$c" in
        1) NET_MODE="ipv4" ;;
        2) NET_MODE="ipv6" ;;
        3) NET_MODE="dual" ;;
    esac
    log_info "网络模式: $NET_MODE"

    echo ""
    echo "接下来逐项确认网络参数（直接回车使用检测值）:"
    echo ""

    if [[ "$NET_MODE" == "ipv4" || "$NET_MODE" == "dual" ]]; then
        echo "--- IPv4 配置 ---"
        if [[ -z "$IPV4_ADDR" ]]; then
            log_warn "未检测到 IPv4 地址，请手动输入"
            IPV4_ADDR=$(prompt_required "IPv4 地址")
        else
            IPV4_ADDR=$(prompt_with_default "IPv4 地址" "$IPV4_ADDR")
        fi

        if [[ -z "$IPV4_MASK" ]]; then
            log_warn "未检测到子网掩码，请手动输入"
            IPV4_MASK=$(prompt_required "IPv4 子网掩码 (如 255.255.255.0)")
        else
            IPV4_MASK=$(prompt_with_default "IPv4 子网掩码" "$IPV4_MASK")
        fi

        if [[ -z "$IPV4_GW" ]]; then
            log_warn "未检测到 IPv4 网关，请手动输入"
            IPV4_GW=$(prompt_required "IPv4 网关")
        else
            IPV4_GW=$(prompt_with_default "IPv4 网关" "$IPV4_GW")
        fi
        echo ""
    fi

    if [[ "$NET_MODE" == "ipv6" || "$NET_MODE" == "dual" ]]; then
        echo "--- IPv6 配置 ---"
        if [[ -z "$IPV6_ADDR" ]]; then
            log_warn "未检测到 IPv6 地址，请手动输入"
            IPV6_ADDR=$(prompt_required "IPv6 地址")
        else
            IPV6_ADDR=$(prompt_with_default "IPv6 地址" "$IPV6_ADDR")
        fi

        if [[ -z "$IPV6_PREFIX" ]]; then
            log_warn "未检测到 IPv6 前缀长度，请手动输入"
            IPV6_PREFIX=$(prompt_required "IPv6 前缀长度 (如 64)")
        else
            IPV6_PREFIX=$(prompt_with_default "IPv6 前缀长度" "$IPV6_PREFIX")
        fi

        if [[ -z "$IPV6_GW" ]]; then
            log_warn "未检测到 IPv6 网关，请手动输入"
            IPV6_GW=$(prompt_required "IPv6 网关")
        else
            IPV6_GW=$(prompt_with_default "IPv6 网关" "$IPV6_GW")
        fi
        echo ""
    fi

    echo "--- 通用网络配置 ---"
    DNS_SERVERS=$(prompt_with_default "DNS 服务器（空格分隔多个）" "$DNS_SERVERS")
    HOSTNAME_NEW=$(prompt_with_default "Hostname" "$HOSTNAME_NEW")

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║        最终写入的网络配置                 ║"
    echo "╠══════════════════════════════════════════╣"
    echo "║ 模式:      $NET_MODE"
    if [[ "$NET_MODE" == "ipv4" || "$NET_MODE" == "dual" ]]; then
        echo "║ IPv4 地址: $IPV4_ADDR"
        echo "║ IPv4 掩码: $IPV4_MASK"
        echo "║ IPv4 网关: $IPV4_GW"
    fi
    if [[ "$NET_MODE" == "ipv6" || "$NET_MODE" == "dual" ]]; then
        echo "║ IPv6 地址: $IPV6_ADDR"
        echo "║ IPv6 前缀: $IPV6_PREFIX"
        echo "║ IPv6 网关: $IPV6_GW"
    fi
    echo "║ DNS:       $DNS_SERVERS"
    echo "║ Hostname:  $HOSTNAME_NEW"
    echo "╚══════════════════════════════════════════╝"
    echo ""
}

configure_accounts() {
    log_step "配置账户"

    local c
    c=$(prompt_choice "用户策略:" "仅使用 root，不创建普通用户" "创建一个普通用户（同时也会有 root）")
    if [[ "$c" == "1" ]]; then
        USER_STRATEGY="root_only"
        NORMAL_USER=""
    else
        USER_STRATEGY="create_user"
        NORMAL_USER=$(prompt_required "请输入普通用户名")
    fi

    echo ""
    echo "设置 root 密码:"
    ROOT_PW_HASH=$(prompt_password "root")

    if [[ "$USER_STRATEGY" == "create_user" ]]; then
        echo ""
        echo "设置 ${NORMAL_USER} 用户密码:"
        USER_PW_HASH=$(prompt_password "$NORMAL_USER")
    fi

    log_info "用户策略: $USER_STRATEGY"
    if [[ -n "$NORMAL_USER" ]]; then
        log_info "普通用户: $NORMAL_USER"
    fi
}

configure_ssh() {
    log_step "配置 SSH"

    SSH_PORT=$(prompt_with_default "SSH 端口" "22")
    # 端口校验
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        log_warn "端口无效，使用默认 22"
        SSH_PORT="22"
    fi

    echo ""
    echo "请输入 SSH 公钥（每行一个，输入空行结束）:"
    echo "（如果没有公钥，直接按回车跳过）"
    SSH_PUBKEYS=""
    while true; do
        local line
        read -rp "> " line
        if [[ -z "$line" ]]; then
            break
        fi
        # 基础格式检查
        if [[ "$line" =~ ^ssh-(rsa|ed25519|ecdsa)|^ecdsa-sha2 ]]; then
            SSH_PUBKEYS="${SSH_PUBKEYS}${line}"$'\n'
        else
            echo "  ⚠ 公钥格式似乎不正确（应以 ssh-rsa / ssh-ed25519 / ecdsa-sha2 开头），仍然添加？(y/N)"
            local confirm
            read -r confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                SSH_PUBKEYS="${SSH_PUBKEYS}${line}"$'\n'
            fi
        fi
    done

    if [[ -n "$SSH_PUBKEYS" ]]; then
        SSH_ROOT_POLICY="pubkey_only"
        local key_count
        key_count=$(echo -n "$SSH_PUBKEYS" | grep -c '.' || true)
        log_info "已添加 $key_count 个公钥 → root 仅公钥登录"
    else
        SSH_ROOT_POLICY="password_allowed"
        log_info "未提供公钥 → root 允许密码登录"
    fi
    log_info "SSH 端口: $SSH_PORT"
}

configure_kernel() {
    log_step "配置内核"

    # =========================================================================
    # Cloud 内核说明:
    #
    # Debian 12 (bookworm):
    #   - 默认仓库提供 linux-image-cloud-amd64 (基于 6.1 内核)
    #   - 如需更新版本 cloud 内核，需要启用 bookworm-backports
    #   - backports 中有基于更高版本的 linux-image-cloud-amd64
    #   - 本脚本仅按需启用 backports，且仅安装 cloud kernel，不切换整套系统
    #
    # Debian 13 (trixie):
    #   - 原生仓库直接提供较新版本的 linux-image-cloud-amd64
    #   - 无需额外启用 backports
    #   - 直接从主仓库安装即可
    # =========================================================================

    local c
    c=$(prompt_choice "是否安装 cloud 优化内核？(适合云服务器/VPS)" "是，安装 cloud 内核" "否，使用默认内核")
    if [[ "$c" == "1" ]]; then
        INSTALL_CLOUD_KERNEL="yes"
        if [[ "$DEBIAN_VERSION" == "12" ]]; then
            local bc
            bc=$(prompt_choice "Debian 12 cloud 内核来源:" \
                "使用默认仓库的 cloud 内核 (6.1 系列)" \
                "启用 backports 获取更新版 cloud 内核")
            if [[ "$bc" == "2" ]]; then
                ENABLE_BACKPORTS="yes"
                log_info "将启用 bookworm-backports（仅用于 cloud 内核）"
            else
                ENABLE_BACKPORTS="no"
            fi
        else
            ENABLE_BACKPORTS="no"
            log_info "Debian 13 直接使用主仓库的 cloud 内核"
        fi
    else
        INSTALL_CLOUD_KERNEL="no"
        ENABLE_BACKPORTS="no"
    fi
    log_info "Cloud 内核: $INSTALL_CLOUD_KERNEL | Backports: $ENABLE_BACKPORTS"
}

# =============================================================================
# 第四阶段：下载并校验 netboot 文件
# =============================================================================
download_netboot_files() {
    log_step "下载 netboot 文件"

    mkdir -p "$NETBOOT_DIR"
    chmod 700 "$NETBOOT_DIR"

    local base_url sums_base
    if [[ "$DEBIAN_VERSION" == "12" ]]; then
        base_url="$DEB12_BASE"
        sums_base="$DEB12_SUMS_BASE"
    else
        base_url="$DEB13_BASE"
        sums_base="$DEB13_SUMS_BASE"
    fi

    local linux_url="${base_url}/linux"
    local initrd_url="${base_url}/initrd.gz"
    local sums_url="${sums_base}/SHA256SUMS"

    log_info "下载 linux ..."
    download_file "$linux_url" "${NETBOOT_DIR}/vmlinuz"
    log_info "下载 initrd.gz ..."
    download_file "$initrd_url" "${NETBOOT_DIR}/initrd.gz"
    log_info "下载 SHA256SUMS ..."
    download_file "$sums_url" "${NETBOOT_DIR}/SHA256SUMS"

    # 校验
    log_info "校验文件完整性 ..."
    verify_checksum
    log_info "文件校验通过 ✓"
}

download_file() {
    local url="$1" dest="$2"
    if [[ "$DOWNLOAD_TOOL" == "wget" ]]; then
        wget -q --timeout=30 --tries=3 -O "$dest" "$url" || die "下载失败: $url"
    else
        curl -fsSL --connect-timeout 30 --retry 3 -o "$dest" "$url" || die "下载失败: $url"
    fi
}

verify_checksum() {
    cd "$NETBOOT_DIR" || die "无法进入 $NETBOOT_DIR"

    # SHA256SUMS 中路径格式类似 ./netboot/debian-installer/amd64/linux
    # 我们需要匹配 linux 和 initrd.gz
    local linux_expected initrd_expected

    linux_expected=$(grep -E '(^|/)linux$' SHA256SUMS | head -1 | awk '{print $1}') || true
    initrd_expected=$(grep -E '(^|/)initrd\.gz$' SHA256SUMS | head -1 | awk '{print $1}') || true

    if [[ -z "$linux_expected" || -z "$initrd_expected" ]]; then
        log_warn "SHA256SUMS 中未找到精确匹配条目，尝试宽松匹配 ..."
        linux_expected=$(grep 'linux' SHA256SUMS | grep -v initrd | head -1 | awk '{print $1}') || true
        initrd_expected=$(grep 'initrd.gz' SHA256SUMS | head -1 | awk '{print $1}') || true
    fi

    if [[ -z "$linux_expected" || -z "$initrd_expected" ]]; then
        die "无法从 SHA256SUMS 中提取校验值。请手动检查 ${NETBOOT_DIR}/SHA256SUMS"
    fi

    local linux_actual initrd_actual
    linux_actual=$(sha256sum vmlinuz | awk '{print $1}')
    initrd_actual=$(sha256sum initrd.gz | awk '{print $1}')

    if [[ "$linux_actual" != "$linux_expected" ]]; then
        die "linux 文件校验失败！\n  预期: $linux_expected\n  实际: $linux_actual"
    fi
    if [[ "$initrd_actual" != "$initrd_expected" ]]; then
        die "initrd.gz 文件校验失败！\n  预期: $initrd_expected\n  实际: $initrd_actual"
    fi

    cd - &>/dev/null
}

# =============================================================================
# 第五阶段：生成 preseed
# =============================================================================
generate_preseed() {
    log_step "生成 preseed 配置"

    local preseed_content=""

    # --- 语言和地区 ---
    preseed_content+="# 语言和地区
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
"

    # --- 网络配置 ---
    # 禁用安装器的自动网络检测（避免覆盖手动配置）
    preseed_content+="
# 网络配置 — 禁用自动检测
d-i netcfg/enable boolean true
d-i netcfg/choose_interface select ${NET_IFACE}
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/disable_dhcp boolean true
d-i netcfg/hostname string ${HOSTNAME_NEW}
d-i netcfg/get_hostname string ${HOSTNAME_NEW}
d-i netcfg/get_domain string unassigned-domain
"

    if [[ "$NET_MODE" == "ipv4" || "$NET_MODE" == "dual" ]]; then
        preseed_content+="
# IPv4
d-i netcfg/get_ipaddress string ${IPV4_ADDR}
d-i netcfg/get_netmask string ${IPV4_MASK}
d-i netcfg/get_gateway string ${IPV4_GW}
d-i netcfg/get_nameservers string ${DNS_SERVERS// / }
d-i netcfg/confirm_static boolean true
"
    fi

    # 注意：Debian installer 对 IPv6 的 preseed 支持有限。
    # 对于纯 IPv6 或双栈，我们在 preseed 中尽量配置，
    # 但可能需要在 VNC 安装中手动确认。
    if [[ "$NET_MODE" == "ipv6" ]]; then
        preseed_content+="
# IPv6 (注意：Debian installer 对纯 IPv6 preseed 支持有限，可能需要 VNC 中确认)
d-i netcfg/get_ipaddress string ${IPV6_ADDR}
d-i netcfg/get_netmask string ${IPV6_PREFIX}
d-i netcfg/get_gateway string ${IPV6_GW}
d-i netcfg/get_nameservers string ${DNS_SERVERS// / }
d-i netcfg/confirm_static boolean true
"
    fi

    if [[ "$NET_MODE" == "dual" ]]; then
        preseed_content+="
# 双栈提示：IPv6 可能需要在 VNC 安装过程中手动配置
# installer 的 preseed 主要处理 IPv4，IPv6 部分可能需要通过内核参数或手动设置
"
    fi

    # --- 镜像 ---
    preseed_content+="
# 镜像
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/suite string ${DEBIAN_CODENAME}
"

    # --- 账户 ---
    if [[ "$USER_STRATEGY" == "root_only" ]]; then
        preseed_content+="
# 账户 — 仅 root
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted string ${ROOT_PW_HASH}
"
    else
        preseed_content+="
# 账户 — root + 普通用户
d-i passwd/root-login boolean true
d-i passwd/make-user boolean true
d-i passwd/root-password-crypted string ${ROOT_PW_HASH}
d-i passwd/user-fullname string ${NORMAL_USER}
d-i passwd/username string ${NORMAL_USER}
d-i passwd/user-password-crypted string ${USER_PW_HASH}
"
    fi

    # --- 分区：留给用户在 VNC 中手动 ---
    # 不做任何自动分区配置
    preseed_content+="
# 分区 — 不自动配置，留给 VNC 手动操作
# （不设置 partman-auto 相关选项）
"

    # --- Bootloader：不预设安装目标 ---
    preseed_content+="
# Bootloader — 不预设目标磁盘，由 VNC 中手动确认
# d-i grub-installer/bootdev string （留空，安装器会询问）
"

    # --- 时区 ---
    preseed_content+="
# 时区
d-i time/zone string UTC
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true
"

    # --- 软件包 ---
    preseed_content+="
# 软件选择 — 最小安装 + SSH
tasksel tasksel/first multiselect ssh-server
d-i pkgsel/include string openssh-server
d-i pkgsel/upgrade select safe-upgrade
popularity-contest popularity-contest/participate boolean false
"

    # --- Cloud 内核 & Backports ---
    if [[ "$INSTALL_CLOUD_KERNEL" == "yes" ]]; then
        if [[ "$DEBIAN_VERSION" == "12" && "$ENABLE_BACKPORTS" == "yes" ]]; then
            preseed_content+="
# Cloud 内核 (Debian 12 + backports)
# 在 late_command 中启用 backports 并安装 cloud 内核
"
        elif [[ "$DEBIAN_VERSION" == "12" ]]; then
            preseed_content+="
# Cloud 内核 (Debian 12 默认仓库)
d-i pkgsel/include string openssh-server linux-image-cloud-amd64
"
        else
            preseed_content+="
# Cloud 内核 (Debian 13 主仓库)
d-i pkgsel/include string openssh-server linux-image-cloud-amd64
"
        fi
    fi

    # --- late_command：安装后执行的命令 ---
    local late_cmds=""

    # SSH 配置
    late_cmds+="
# 配置 sshd
in-target bash -c 'mkdir -p /etc/ssh/sshd_config.d';
in-target bash -c 'cat > /etc/ssh/sshd_config.d/99-custom.conf << SSHEOF
Port ${SSH_PORT}
PermitRootLogin ##ROOT_LOGIN##
PasswordAuthentication ##PASSWD_AUTH##
PubkeyAuthentication yes
ChallengeResponseAuthentication no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
SSHEOF';
"

    # SSH Root 策略
    if [[ "$SSH_ROOT_POLICY" == "pubkey_only" ]]; then
        late_cmds="${late_cmds//\#\#ROOT_LOGIN\#\#/prohibit-password}"
        late_cmds="${late_cmds//\#\#PASSWD_AUTH\#\#/no}"
    else
        late_cmds="${late_cmds//\#\#ROOT_LOGIN\#\#/yes}"
        late_cmds="${late_cmds//\#\#PASSWD_AUTH\#\#/yes}"
    fi

    # SSH 公钥
    if [[ -n "$SSH_PUBKEYS" ]]; then
        # 转义公钥中的特殊字符
        local escaped_keys
        escaped_keys=$(echo -n "$SSH_PUBKEYS" | sed '/^$/d')
        late_cmds+="
in-target bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh';
in-target bash -c 'cat > /root/.ssh/authorized_keys << KEYEOF
${escaped_keys}
KEYEOF';
in-target bash -c 'chmod 600 /root/.ssh/authorized_keys';
"
    fi

    # Cloud 内核 backports（仅 Debian 12 且选择了 backports）
    if [[ "$INSTALL_CLOUD_KERNEL" == "yes" && "$DEBIAN_VERSION" == "12" && "$ENABLE_BACKPORTS" == "yes" ]]; then
        late_cmds+="
# 启用 bookworm-backports 并安装 cloud 内核
in-target bash -c 'echo \"deb https://deb.debian.org/debian bookworm-backports main\" > /etc/apt/sources.list.d/backports.list';
in-target bash -c 'cat > /etc/apt/preferences.d/99-backports-cloud-kernel << PREFEOF
Package: linux-image-cloud-amd64 linux-image-*-cloud-amd64
Pin: release a=bookworm-backports
Pin-Priority: 500

Package: *
Pin: release a=bookworm-backports
Pin-Priority: 100
PREFEOF';
in-target bash -c 'apt-get update -qq && apt-get install -y -t bookworm-backports linux-image-cloud-amd64';
"
    fi

    # 组装 late_command
    if [[ -n "$late_cmds" ]]; then
        # 将多行命令合并为一行（preseed late_command 格式要求）
        local joined
        joined=$(echo "$late_cmds" | sed '/^$/d' | sed '/^#/d' | tr '\n' ' ' | sed 's/;  */; /g' | sed 's/^  *//' | sed 's/  *$//')
        preseed_content+="
# 安装后执行
d-i preseed/late_command string ${joined}
"
    fi

    # --- 安装完成 ---
    preseed_content+="
# 安装完成后重启
d-i finish-install/reboot_in_progress note
"

    # 写入文件
    echo "$preseed_content" > "$PRESEED_FILE"
    chmod 600 "$PRESEED_FILE"
    log_info "Preseed 已写入: $PRESEED_FILE"
}

# =============================================================================
# 第六阶段：配置 GRUB
# =============================================================================
configure_grub() {
    log_step "配置 GRUB 启动项"

    # 检查 GRUB_DEFAULT 是否支持 saved（grub-reboot 需要此设置）
    local grub_default
    grub_default=$(grep -E '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)

    if [[ "$grub_default" != "saved" ]]; then
        log_info "设置 GRUB_DEFAULT=saved（grub-reboot 所需）"
        cp /etc/default/grub "/etc/default/grub.bak.$(date +%Y%m%d%H%M%S)"
        if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
            sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
        else
            echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
        fi
    fi

    # 备份 40_custom
    if [[ -f "$GRUB_CUSTOM" ]]; then
        cp "$GRUB_CUSTOM" "$GRUB_CUSTOM_BACKUP"
        log_info "已备份: $GRUB_CUSTOM → $GRUB_CUSTOM_BACKUP"
    fi

    # 构建内核参数
    local kernel_params=""

    # 基础安装器参数
    kernel_params+="auto=true priority=critical"
    kernel_params+=" preseed/file=/boot/debian-netboot/preseed.cfg"
    kernel_params+=" locale=en_US.UTF-8"
    kernel_params+=" keymap=us"
    kernel_params+=" hostname=${HOSTNAME_NEW}"
    kernel_params+=" domain=unassigned-domain"

    # 网络内核参数
    # 使用内核参数静态配置网络，防止安装器 DHCP 覆盖
    if [[ "$NET_MODE" == "ipv4" || "$NET_MODE" == "dual" ]]; then
        kernel_params+=" netcfg/disable_autoconfig=true"
        kernel_params+=" netcfg/get_ipaddress=${IPV4_ADDR}"
        kernel_params+=" netcfg/get_netmask=${IPV4_MASK}"
        kernel_params+=" netcfg/get_gateway=${IPV4_GW}"
        kernel_params+=" netcfg/get_nameservers=${DNS_SERVERS%% *}"
        kernel_params+=" netcfg/confirm_static=true"
    fi

    if [[ "$NET_MODE" == "ipv6" ]]; then
        kernel_params+=" netcfg/disable_autoconfig=true"
        kernel_params+=" netcfg/get_ipaddress=${IPV6_ADDR}"
        kernel_params+=" netcfg/get_netmask=${IPV6_PREFIX}"
        kernel_params+=" netcfg/get_gateway=${IPV6_GW}"
        kernel_params+=" netcfg/get_nameservers=${DNS_SERVERS%% *}"
        kernel_params+=" netcfg/confirm_static=true"
    fi

    kernel_params+=" netcfg/choose_interface=${NET_IFACE}"

    # VGA console（方便 VNC 查看）
    kernel_params+=" vga=788"
    kernel_params+=" --- quiet"

    # 移除旧的 netboot 条目（幂等）
    if [[ -f "$GRUB_CUSTOM" ]]; then
        # 删除旧的 debian-netboot-installer 条目
        local tmp_grub
        tmp_grub=$(mktemp)
        awk '
            /menuentry.*--id '"'${GRUB_MENUENTRY_ID}'"'/{skip=1; brace=0}
            skip && /\{/{brace++}
            skip && /\}/{brace--; if(brace<=0){skip=0; next}}
            !skip
        ' "$GRUB_CUSTOM" > "$tmp_grub"
        mv "$tmp_grub" "$GRUB_CUSTOM"
    fi

    # 确保 40_custom 有正确的头部
    if [[ ! -f "$GRUB_CUSTOM" ]] || ! grep -q 'exec tail' "$GRUB_CUSTOM"; then
        cat > "$GRUB_CUSTOM" << 'HEADER'
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.
HEADER
    fi

    # 写入新的 netboot 条目
    cat >> "$GRUB_CUSTOM" << GRUBEOF

menuentry 'Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME}) Netboot Installer' --id '${GRUB_MENUENTRY_ID}' {
    insmod gzio
    insmod part_msdos
    insmod part_gpt
    linux  /boot/debian-netboot/vmlinuz ${kernel_params}
    initrd /boot/debian-netboot/initrd.gz
}
GRUBEOF

    chmod +x "$GRUB_CUSTOM"

    # 更新 GRUB
    log_info "更新 GRUB 配置 ..."
    update-grub 2>&1 | tee -a "$LOG_FILE" || die "update-grub 失败！请检查 GRUB 配置"

    # 验证条目存在
    if ! grep -q "${GRUB_MENUENTRY_ID}" /boot/grub/grub.cfg 2>/dev/null; then
        die "GRUB 配置更新后未找到 netboot 条目。请检查 ${GRUB_CUSTOM}"
    fi

    # 使用 grub-reboot 设置一次性启动
    log_info "设置下一次启动进入安装器 (grub-reboot) ..."
    grub-reboot "${GRUB_MENUENTRY_ID}" || die "grub-reboot 失败"

    log_info "GRUB 配置完成 ✓"
    echo ""
    echo "  ℹ 取消下次启动进入安装器的方法:"
    echo "    sudo grub-reboot 0"
    echo "    # 这会将下次启动恢复为默认条目"
    echo ""
}

# =============================================================================
# 第七阶段：摘要确认和重启
# =============================================================================
show_summary_and_confirm() {
    log_step "最终摘要"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                     安 装 摘 要                             ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║"
    echo "║  Debian 版本:    ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
    echo "║  启动模式:       ${BOOT_MODE^^}"
    echo "║"
    echo "║  ─── 网络配置 ───"
    echo "║  网络模式:       ${NET_MODE}"
    echo "║  网络接口:       ${NET_IFACE}"
    if [[ "$NET_MODE" == "ipv4" || "$NET_MODE" == "dual" ]]; then
        echo "║  IPv4 地址:      ${IPV4_ADDR}"
        echo "║  IPv4 掩码:      ${IPV4_MASK}"
        echo "║  IPv4 网关:      ${IPV4_GW}"
    fi
    if [[ "$NET_MODE" == "ipv6" || "$NET_MODE" == "dual" ]]; then
        echo "║  IPv6 地址:      ${IPV6_ADDR}"
        echo "║  IPv6 前缀:      ${IPV6_PREFIX}"
        echo "║  IPv6 网关:      ${IPV6_GW}"
    fi
    echo "║  DNS:            ${DNS_SERVERS}"
    echo "║  Hostname:       ${HOSTNAME_NEW}"
    echo "║"
    echo "║  ─── 账户 ───"
    if [[ "$USER_STRATEGY" == "root_only" ]]; then
        echo "║  用户策略:       仅 root"
    else
        echo "║  用户策略:       root + ${NORMAL_USER}"
    fi
    echo "║"
    echo "║  ─── SSH ───"
    echo "║  SSH 端口:       ${SSH_PORT}"
    if [[ "$SSH_ROOT_POLICY" == "pubkey_only" ]]; then
        echo "║  Root 登录:      仅公钥（禁止密码）"
        echo "║  已添加公钥:     是"
    else
        echo "║  Root 登录:      允许密码"
        echo "║  已添加公钥:     否"
    fi
    echo "║"
    echo "║  ─── 内核 ───"
    if [[ "$INSTALL_CLOUD_KERNEL" == "yes" ]]; then
        echo "║  Cloud 内核:     是"
        if [[ "$ENABLE_BACKPORTS" == "yes" ]]; then
            echo "║  Backports:      是（仅用于 cloud 内核）"
        else
            echo "║  Backports:      否"
        fi
    else
        echo "║  Cloud 内核:     否（使用默认内核）"
        echo "║  Backports:      否"
    fi
    echo "║"
    echo "║  ─── 重要提醒 ───"
    echo "║  • 分区将在 VNC 中手动完成"
    echo "║  • Bootloader 安装目标将在 VNC 中手动确认"
    echo "║  • 重启后请立即连接 VNC 完成安装"
    echo "║  • 下次启动将一次性进入安装器"
    echo "║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    if [[ "$NET_MODE" == "ipv6" || "$NET_MODE" == "dual" ]]; then
        echo "  ⚠ 警告: Debian installer 对 IPv6 preseed 支持有限。"
        echo "    IPv6 配置可能需要在 VNC 安装过程中手动确认或修改。"
        echo ""
    fi

    echo "════════════════════════════════════════════════"
    echo "  重启后将进入 Debian 安装器。"
    echo "  如需取消: sudo grub-reboot 0"
    echo "════════════════════════════════════════════════"
    echo ""
    echo -n "确认重启？请输入大写 YES 继续，其他任何输入将安全退出: "
    local confirm
    read -r confirm

    if [[ "$confirm" != "YES" ]]; then
        echo ""
        log_info "用户取消了重启。"
        echo "  GRUB 配置已写入但未重启。你可以："
        echo "    1. 手动重启:  sudo reboot"
        echo "    2. 取消安装:  sudo grub-reboot 0"
        echo "    3. 重新运行本脚本"
        echo ""
        exit 0
    fi

    echo ""
    log_info "即将重启 ..."
    echo "  请立即准备好 VNC 连接！"
    echo "  5 秒后重启 ..."
    sleep 5
    reboot
}

# =============================================================================
# 清理函数
# =============================================================================
cleanup_sensitive() {
    # 清除内存中的敏感变量
    ROOT_PW_HASH=""
    USER_PW_HASH=""
    SSH_PUBKEYS=""

    # 确保日志中没有密码哈希
    if [[ -f "$LOG_FILE" ]]; then
        chmod 600 "$LOG_FILE"
    fi
}

# =============================================================================
# 主函数
# =============================================================================
main() {
    # 初始化日志
    touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" || true

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     Debian Netboot 重装准备脚本 v${SCRIPT_VERSION}                     ║"
    echo "║     仅准备环境，不做全自动安装                                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # 阶段一：前置检查
    log_step "环境检查"
    check_root
    check_os
    detect_boot_mode
    detect_download_tool
    install_dependencies

    # 阶段二：检测网络
    detect_network

    # 阶段三：用户交互
    choose_debian_version
    configure_network_interactive
    configure_accounts
    configure_ssh
    configure_kernel

    # 阶段四：下载
    download_netboot_files

    # 阶段五：生成 preseed
    generate_preseed

    # 阶段六：GRUB
    configure_grub

    # 阶段七：确认和重启
    show_summary_and_confirm

    # 清理（正常情况下 reboot 后不会到达这里）
    cleanup_sensitive
}

# 注册退出清理
trap cleanup_sensitive EXIT

# 运行
main "$@"
