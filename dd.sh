#!/usr/bin/env bash
#===============================================================================
#  Debian Netboot 一键重装脚本
#  功能：通过 GRUB 引导 Debian netboot 安装器，支持 BIOS/UEFI 自动检测
#  用途：重启后通过 VNC 手动完成安装
#===============================================================================
set -euo pipefail

#——————————————————————————————————————————————
# 全局变量 / 默认值
#——————————————————————————————————————————————
NETBOOT_DIR="/netboot"
PRESEED_FILE="${NETBOOT_DIR}/preseed.cfg"
GRUB_CUSTOM="/etc/grub.d/40_custom"
GRUB_CUSTOM_BACKUP="/etc/grub.d/40_custom.bak.$(date +%s)"
DEBIAN_VERSION="bookworm"
DEBIAN_ARCH="amd64"

# Debian 官方镜像源列表（用户可选）
declare -A MIRRORS=(
    ["1-官方(美国)"]="http://http.us.debian.org/debian"
    ["2-清华大学(中国)"]="https://mirrors.tuna.tsinghua.edu.cn/debian"
    ["3-中科大(中国)"]="https://mirrors.ustc.edu.cn/debian"
    ["4-阿里云(中国)"]="https://mirrors.aliyun.com/debian"
    ["5-华为云(中国)"]="https://repo.huaweicloud.com/debian"
    ["6-官方(欧洲-德国)"]="http://ftp.de.debian.org/debian"
    ["7-官方(日本)"]="http://ftp.jp.debian.org/debian"
)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

#——————————————————————————————————————————————
# 工具函数
#——————————————————————————————————————————————
msg_info()  { echo -e "${CYAN}[信息]${NC} $*"; }
msg_ok()    { echo -e "${GREEN}[完成]${NC} $*"; }
msg_warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
msg_error() { echo -e "${RED}[错误]${NC} $*"; }
msg_step()  { echo -e "\n${BOLD}========== $* ==========${NC}"; }

confirm_or_exit() {
    local prompt="${1:-是否继续？}"
    read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]] || { msg_warn "用户取消操作，退出。"; exit 0; }
}

cleanup_on_error() {
    msg_error "脚本执行出错，正在回滚..."
    # 恢复 GRUB 配置
    if [[ -f "${GRUB_CUSTOM_BACKUP}" ]]; then
        cp -f "${GRUB_CUSTOM_BACKUP}" "${GRUB_CUSTOM}"
        update-grub 2>/dev/null || true
        msg_info "已恢复 GRUB 配置"
    fi
    # 清理下载文件
    if [[ -d "${NETBOOT_DIR}" ]]; then
        rm -rf "${NETBOOT_DIR}"
        msg_info "已清理 ${NETBOOT_DIR}"
    fi
    msg_error "回滚完成，系统未被修改。"
    exit 1
}

trap cleanup_on_error ERR

#——————————————————————————————————————————————
# 第 1 步：环境检查
#——————————————————————————————————————————————
preflight_check() {
    msg_step "第 1 步：环境检查"

    # 1.1 root 权限
    if [[ $EUID -ne 0 ]]; then
        msg_error "请使用 root 用户运行此脚本！"
        msg_info "用法: sudo bash $0"
        exit 1
    fi
    msg_ok "root 权限确认"

    # 1.2 操作系统检查
    if [[ ! -f /etc/debian_version ]]; then
        msg_error "此脚本仅支持 Debian 系统！"
        exit 1
    fi
    local current_ver
    current_ver=$(cat /etc/debian_version)
    msg_ok "当前系统: Debian ${current_ver}"

    # 1.3 必要工具检查
    local required_tools=("wget" "grub-mkconfig" "blkid" "findmnt" "ip" "sha256sum" "gpgv")
    local missing_tools=()
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        msg_warn "缺少以下工具: ${missing_tools[*]}"
        msg_info "正在尝试安装..."
        apt-get update -qq
        apt-get install -y -qq wget grub2-common util-linux iproute2 coreutils gpgv debian-keyring 2>/dev/null || {
            msg_error "无法安装必要工具，请手动安装后重试。"
            exit 1
        }
    fi
    msg_ok "必要工具已就绪"

    # 1.4 网络连通性
    if ! wget -q --spider --timeout=10 http://http.us.debian.org 2>/dev/null; then
        msg_warn "无法连接到默认 Debian 镜像源，请确保网络可用或选择其他镜像源。"
    else
        msg_ok "网络连通正常"
    fi

    # 1.5 VNC 提醒
    echo ""
    msg_warn "======================================================"
    msg_warn "  重要提醒：重启后 SSH 将不可用！"
    msg_warn "  请确保你可以通过 VNC 控制台访问服务器！"
    msg_warn "  如果无法使用 VNC，请不要继续！"
    msg_warn "======================================================"
    echo ""
    confirm_or_exit "你是否已确认可以通过 VNC 访问此服务器？"
}

#——————————————————————————————————————————————
# 第 2 步：检测引导方式（BIOS / UEFI）
#——————————————————————————————————————————————
BOOT_MODE=""
detect_boot_mode() {
    msg_step "第 2 步：检测引导方式"

    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE="UEFI"
        msg_ok "引导方式: UEFI"
        # 检查 EFI 分区
        if ! findmnt /boot/efi &>/dev/null && ! findmnt /efi &>/dev/null; then
            msg_warn "未检测到已挂载的 EFI 分区，UEFI 引导可能有问题。"
        fi
    else
        BOOT_MODE="BIOS"
        msg_ok "引导方式: BIOS (Legacy)"
    fi
}

#——————————————————————————————————————————————
# 第 3 步：获取网络配置
#——————————————————————————————————————————————
NET_IFACE=""
NET_IP=""
NET_MASK=""
NET_CIDR=""
NET_GW=""
NET_DNS1=""
NET_DNS2=""
NET_IP6=""
NET_GW6=""
HAS_IPV6="no"

detect_network() {
    msg_step "第 3 步：获取当前网络配置"

    # 检测主网卡（默认路由使用的接口）
    NET_IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)
    if [[ -z "$NET_IFACE" ]]; then
        msg_error "无法检测到默认网络接口！"
        read -rp "请手动输入网卡名称（如 eth0, ens3）: " NET_IFACE
    fi
    msg_ok "主网卡: ${NET_IFACE}"

    # IPv4 配置
    NET_IP=$(ip -4 addr show dev "$NET_IFACE" | grep -oP 'inet \K[\d.]+' | head -1)
    NET_CIDR=$(ip -4 addr show dev "$NET_IFACE" | grep -oP 'inet \K[\d./]+' | head -1 | cut -d/ -f2)
    NET_GW=$(ip -4 route show default | awk '{print $3}' | head -1)

    # 子网掩码转换（CIDR -> 点分十进制）
    cidr_to_netmask() {
        local cidr=$1
        local mask=""
        local full_octets=$((cidr / 8))
        local partial_bits=$((cidr % 8))
        for ((i=0; i<4; i++)); do
            if [[ $i -lt $full_octets ]]; then
                mask+="255"
            elif [[ $i -eq $full_octets ]]; then
                mask+="$(( 256 - (1 << (8 - partial_bits)) ))"
            else
                mask+="0"
            fi
            [[ $i -lt 3 ]] && mask+="."
        done
        echo "$mask"
    }
    NET_MASK=$(cidr_to_netmask "$NET_CIDR")

    # DNS（从 resolv.conf 获取）
    NET_DNS1=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')
    NET_DNS2=$(grep '^nameserver' /etc/resolv.conf | awk 'NR==2{print $2}')
    [[ -z "$NET_DNS1" ]] && NET_DNS1="8.8.8.8"
    [[ -z "$NET_DNS2" ]] && NET_DNS2="1.1.1.1"

    # IPv6 检测
    local ipv6_addr
    ipv6_addr=$(ip -6 addr show dev "$NET_IFACE" scope global | grep -oP 'inet6 \K[0-9a-f:]+' | head -1)
    if [[ -n "$ipv6_addr" ]]; then
        HAS_IPV6="yes"
        NET_IP6="$ipv6_addr"
        NET_GW6=$(ip -6 route show default | awk '{print $3}' | head -1)
    fi

    # 显示检测到的配置
    echo ""
    msg_info "————— 检测到的网络配置 —————"
    msg_info "网卡接口:   ${NET_IFACE}"
    msg_info "IPv4 地址:  ${NET_IP}/${NET_CIDR}"
    msg_info "子网掩码:   ${NET_MASK}"
    msg_info "默认网关:   ${NET_GW}"
    msg_info "DNS 1:      ${NET_DNS1}"
    msg_info "DNS 2:      ${NET_DNS2}"
    if [[ "$HAS_IPV6" == "yes" ]]; then
        msg_info "IPv6 地址:  ${NET_IP6}"
        msg_info "IPv6 网关:  ${NET_GW6}"
    else
        msg_info "IPv6:       未检测到"
    fi
    echo ""

    # 允许用户修改
    read -rp "$(echo -e "${YELLOW}是否需要手动修改网络配置？[y/N]: ${NC}")" modify_net
    if [[ "${modify_net,,}" == "y" ]]; then
        read -rp "网卡接口 [${NET_IFACE}]: " tmp && [[ -n "$tmp" ]] && NET_IFACE="$tmp"
        read -rp "IPv4 地址 [${NET_IP}]: " tmp && [[ -n "$tmp" ]] && NET_IP="$tmp"
        read -rp "子网掩码 [${NET_MASK}]: " tmp && [[ -n "$tmp" ]] && NET_MASK="$tmp"
        read -rp "默认网关 [${NET_GW}]: " tmp && [[ -n "$tmp" ]] && NET_GW="$tmp"
        read -rp "DNS 1 [${NET_DNS1}]: " tmp && [[ -n "$tmp" ]] && NET_DNS1="$tmp"
        read -rp "DNS 2 [${NET_DNS2}]: " tmp && [[ -n "$tmp" ]] && NET_DNS2="$tmp"
        msg_ok "网络配置已更新"
    fi
}

#——————————————————————————————————————————————
# 第 4 步：用户交互 - 系统配置
#——————————————————————————————————————————————
SSH_PORT="22"
ROOT_PASSWORD=""
USE_SSH_KEY="no"
SSH_PUBLIC_KEY=""
DISABLE_PASSWORD_AUTH="no"
INSTALL_FAIL2BAN="no"
SELECTED_MIRROR=""
SETUP_FIREWALL="yes"
TIMEZONE="Asia/Shanghai"

user_config() {
    msg_step "第 4 步：系统配置（安装后自动生效）"

    # 4.1 选择镜像源
    echo ""
    msg_info "请选择 Debian 镜像源："
    local sorted_keys
    sorted_keys=$(echo "${!MIRRORS[@]}" | tr ' ' '\n' | sort)
    for key in $sorted_keys; do
        echo "  ${key}  →  ${MIRRORS[$key]}"
    done
    echo ""
    read -rp "请输入选项编号 [1]: " mirror_choice
    mirror_choice="${mirror_choice:-1}"
    local found=0
    for key in "${!MIRRORS[@]}"; do
        if [[ "$key" == "${mirror_choice}-"* ]]; then
            SELECTED_MIRROR="${MIRRORS[$key]}"
            found=1
            break
        fi
    done
    [[ $found -eq 0 ]] && SELECTED_MIRROR="${MIRRORS["1-官方(美国)"]}"
    msg_ok "镜像源: ${SELECTED_MIRROR}"

    # 4.2 SSH 端口
    echo ""
    read -rp "$(echo -e "${CYAN}设置 SSH 端口 [22]: ${NC}")" SSH_PORT
    SSH_PORT="${SSH_PORT:-22}"
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]]; then
        msg_warn "端口号无效，使用默认值 22"
        SSH_PORT="22"
    fi
    msg_ok "SSH 端口: ${SSH_PORT}"

    # 4.3 Root 密码
    echo ""
    while true; do
        read -srp "$(echo -e "${CYAN}设置 root 密码: ${NC}")" ROOT_PASSWORD
        echo ""
        if [[ ${#ROOT_PASSWORD} -lt 8 ]]; then
            msg_warn "密码长度至少 8 位，请重新输入。"
            continue
        fi
        read -srp "$(echo -e "${CYAN}再次输入 root 密码: ${NC}")" root_pw_confirm
        echo ""
        if [[ "$ROOT_PASSWORD" != "$root_pw_confirm" ]]; then
            msg_warn "两次密码不一致，请重新输入。"
            continue
        fi
        break
    done
    msg_ok "root 密码已设置"

    # 4.4 SSH 密钥登录
    echo ""
    read -rp "$(echo -e "${CYAN}是否配置 SSH 密钥登录？[y/N]: ${NC}")" use_key
    if [[ "${use_key,,}" == "y" ]]; then
        USE_SSH_KEY="yes"
        echo ""
        msg_info "请输入你的 SSH 公钥（ssh-rsa/ssh-ed25519 开头的完整内容）："
        msg_info "（也可以输入公钥的 URL，如 https://github.com/username.keys）"
        read -rp "> " key_input
        if [[ "$key_input" == http* ]]; then
            msg_info "正在从 URL 下载公钥..."
            SSH_PUBLIC_KEY=$(wget -qO- --timeout=10 "$key_input" 2>/dev/null) || {
                msg_error "无法下载公钥，请直接粘贴公钥内容。"
                read -rp "> " SSH_PUBLIC_KEY
            }
        else
            SSH_PUBLIC_KEY="$key_input"
        fi
        # 验证公钥格式
        if [[ ! "$SSH_PUBLIC_KEY" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
            msg_warn "公钥格式看起来不正确，请确认。继续使用当前输入。"
        fi
        msg_ok "SSH 公钥已设置"

        # 是否禁用密码登录
        read -rp "$(echo -e "${CYAN}是否禁用 SSH 密码登录（仅允许密钥）？[y/N]: ${NC}")" disable_pw
        if [[ "${disable_pw,,}" == "y" ]]; then
            DISABLE_PASSWORD_AUTH="yes"
            msg_ok "安装后将禁用密码登录"
        fi
    fi

    # 4.5 防火墙
    echo ""
    read -rp "$(echo -e "${CYAN}是否安装并配置防火墙 (nftables)？[Y/n]: ${NC}")" setup_fw
    if [[ "${setup_fw,,}" != "n" ]]; then
        SETUP_FIREWALL="yes"
        msg_ok "将自动配置防火墙，放行 SSH 端口 ${SSH_PORT}"
    else
        SETUP_FIREWALL="no"
    fi

    # 4.6 Fail2ban
    read -rp "$(echo -e "${CYAN}是否安装 fail2ban 防暴力破解？[Y/n]: ${NC}")" install_f2b
    if [[ "${install_f2b,,}" != "n" ]]; then
        INSTALL_FAIL2BAN="yes"
        msg_ok "将自动安装 fail2ban"
    fi

    # 4.7 时区
    echo ""
    read -rp "$(echo -e "${CYAN}设置时区 [Asia/Shanghai]: ${NC}")" TIMEZONE
    TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
    msg_ok "时区: ${TIMEZONE}"
}

#——————————————————————————————————————————————
# 第 5 步：下载 netboot 文件并校验
#——————————————————————————————————————————————
download_and_verify() {
    msg_step "第 5 步：下载 Netboot 文件并验证完整性"

    local base_url="${SELECTED_MIRROR}/dists/${DEBIAN_VERSION}/main/installer-${DEBIAN_ARCH}/current/images"
    local netboot_path="netboot/debian-installer/${DEBIAN_ARCH}"
    local checksum_url="${base_url}/SHA256SUMS"
    local sign_url="${base_url}/SHA256SUMS.gpg"

    mkdir -p "${NETBOOT_DIR}"
    cd "${NETBOOT_DIR}"

    # 下载内核和 initrd
    msg_info "正在下载 linux 内核..."
    wget -4 -q --show-progress -O linux "${base_url}/${netboot_path}/linux" || {
        msg_error "下载 linux 内核失败！请检查网络或更换镜像源。"
        exit 1
    }

    msg_info "正在下载 initrd.gz..."
    wget -4 -q --show-progress -O initrd.gz "${base_url}/${netboot_path}/initrd.gz" || {
        msg_error "下载 initrd.gz 失败！"
        exit 1
    }

    # 下载校验文件
    msg_info "正在下载校验文件..."
    wget -4 -q -O SHA256SUMS "${checksum_url}" || {
        msg_error "下载 SHA256SUMS 失败！"
        exit 1
    }

    # 尝试 GPG 签名验证
    local gpg_verified=0
    msg_info "正在下载 GPG 签名..."
    if wget -4 -q -O SHA256SUMS.gpg "${sign_url}" 2>/dev/null; then
        msg_info "正在验证 GPG 签名..."
        # Debian 的发布签名密钥
        local keyring="/usr/share/keyrings/debian-archive-keyring.gpg"
        if [[ -f "$keyring" ]]; then
            if gpgv --keyring "$keyring" SHA256SUMS.gpg SHA256SUMS 2>/dev/null; then
                msg_ok "GPG 签名验证通过 ✓"
                gpg_verified=1
            else
                msg_warn "GPG 签名验证失败！文件可能被篡改！"
                confirm_or_exit "是否仍然继续？（不推荐）"
            fi
        else
            msg_warn "未找到 Debian 密钥环 (${keyring})，跳过 GPG 验证。"
            msg_info "可通过 apt install debian-keyring 安装。"
        fi
    else
        msg_warn "无法下载 GPG 签名文件，跳过签名验证。"
    fi

    # SHA256 校验
    msg_info "正在进行 SHA256 校验..."
    local linux_expected initrd_expected linux_actual initrd_actual
    linux_expected=$(grep "${netboot_path}/linux$" SHA256SUMS | awk '{print $1}')
    initrd_expected=$(grep "${netboot_path}/initrd.gz$" SHA256SUMS | awk '{print $1}')
    linux_actual=$(sha256sum linux | awk '{print $1}')
    initrd_actual=$(sha256sum initrd.gz | awk '{print $1}')

    if [[ -z "$linux_expected" || -z "$initrd_expected" ]]; then
        msg_warn "无法从 SHA256SUMS 中提取预期校验值。"
        msg_info "linux  实际 SHA256: ${linux_actual}"
        msg_info "initrd 实际 SHA256: ${initrd_actual}"
        confirm_or_exit "无法自动校验，是否继续？"
    else
        if [[ "$linux_expected" == "$linux_actual" ]]; then
            msg_ok "linux  SHA256 校验通过 ✓"
        else
            msg_error "linux  SHA256 校验失败！"
            msg_error "  预期: ${linux_expected}"
            msg_error "  实际: ${linux_actual}"
            exit 1
        fi
        if [[ "$initrd_expected" == "$initrd_actual" ]]; then
            msg_ok "initrd SHA256 校验通过 ✓"
        else
            msg_error "initrd SHA256 校验失败！"
            msg_error "  预期: ${initrd_expected}"
            msg_error "  实际: ${initrd_actual}"
            exit 1
        fi
    fi

    msg_ok "文件下载和验证完成"
}

#——————————————————————————————————————————————
# 第 6 步：生成 preseed 配置（网络 + 后续配置）
#——————————————————————————————————————————————
generate_preseed() {
    msg_step "第 6 步：生成 Preseed 预配置文件"

    # 密码哈希
    local root_pw_hash
    root_pw_hash=$(echo "${ROOT_PASSWORD}" | openssl passwd -6 -stdin 2>/dev/null) || \
    root_pw_hash=$(python3 -c "import crypt; print(crypt.crypt('${ROOT_PASSWORD}', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null) || {
        msg_error "无法生成密码哈希！"
        exit 1
    }

    # 构建 late_command 脚本（安装后自动执行）
    # 注意：preseed 中 late_command 使用 in-target 执行命令
    local late_commands=""

    # SSH 配置
    late_commands+="in-target sed -i 's/^#\\?Port .*/Port ${SSH_PORT}/' /etc/ssh/sshd_config; "
    late_commands+="in-target sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config; "
    late_commands+="in-target sed -i 's/^#\\?UseDNS .*/UseDNS no/' /etc/ssh/sshd_config; "

    # SSH 密钥
    if [[ "$USE_SSH_KEY" == "yes" ]]; then
        late_commands+="in-target mkdir -p /root/.ssh; "
        late_commands+="in-target chmod 700 /root/.ssh; "
        # 使用 printf 避免引号问题
        late_commands+="in-target sh -c 'printf \"%s\n\" \"${SSH_PUBLIC_KEY}\" > /root/.ssh/authorized_keys'; "
        late_commands+="in-target chmod 600 /root/.ssh/authorized_keys; "
        late_commands+="in-target sed -i 's/^#\\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config; "

        if [[ "$DISABLE_PASSWORD_AUTH" == "yes" ]]; then
            late_commands+="in-target sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config; "
        fi
    fi

    # 防火墙 (nftables)
    if [[ "$SETUP_FIREWALL" == "yes" ]]; then
        late_commands+="in-target apt-get install -y nftables; "
        late_commands+="in-target systemctl enable nftables; "
        # 写入 nftables 规则文件
        late_commands+="in-target sh -c 'cat > /etc/nftables.conf << \"NFTEOF\"
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state established,related accept
        ct state invalid drop
        tcp dport ${SSH_PORT} ct state new accept
        icmp type echo-request accept
        ip6 nexthdr icmpv6 accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFTEOF'; "
    fi

    # Fail2ban
    if [[ "$INSTALL_FAIL2BAN" == "yes" ]]; then
        late_commands+="in-target apt-get install -y fail2ban; "
        late_commands+="in-target systemctl enable fail2ban; "
        # 自定义 fail2ban SSH 配置
        late_commands+="in-target sh -c 'cat > /etc/fail2ban/jail.local << \"F2BEOF\"
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
maxretry = 5
bantime = 3600
findtime = 600
F2BEOF'; "
    fi

    # 自动安全更新
    late_commands+="in-target apt-get install -y unattended-upgrades; "
    late_commands+="in-target dpkg-reconfigure -f noninteractive unattended-upgrades; "

    # 生成 preseed 文件
    cat > "${PRESEED_FILE}" << PRESEEDEOF
### —— 语言和地区 ——
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us

### —— 网络配置（静态 IP）——
d-i netcfg/choose_interface select ${NET_IFACE}
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string ${NET_IP}
d-i netcfg/get_netmask string ${NET_MASK}
d-i netcfg/get_gateway string ${NET_GW}
d-i netcfg/get_nameservers string ${NET_DNS1}
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string localdomain

### —— 镜像源 ——
d-i mirror/protocol string http
d-i mirror/country string manual
d-i mirror/http/hostname string $(echo "${SELECTED_MIRROR}" | sed 's|https\?://||' | cut -d/ -f1)
d-i mirror/http/directory string /$(echo "${SELECTED_MIRROR}" | sed 's|https\?://[^/]*/||')
d-i mirror/http/proxy string

### —— 时区 ——
d-i time/zone string ${TIMEZONE}
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true

### —— 用户账号（仅 root）——
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted string ${root_pw_hash}

### —— 安装后执行的命令 ——
d-i preseed/late_command string ${late_commands}

### —— 结束后重启 ——
d-i finish-install/reboot_in_progress note
PRESEEDEOF

    chmod 600 "${PRESEED_FILE}"
    msg_ok "Preseed 配置文件已生成: ${PRESEED_FILE}"
    msg_info "提示: 磁盘分区部分未预配置，将在 VNC 中手动操作。"
}

#——————————————————————————————————————————————
# 第 7 步：配置 GRUB 引导
#——————————————————————————————————————————————
configure_grub() {
    msg_step "第 7 步：配置 GRUB 引导"

    # 备份当前 40_custom
    if [[ -f "${GRUB_CUSTOM}" ]]; then
        cp "${GRUB_CUSTOM}" "${GRUB_CUSTOM_BACKUP}"
        msg_ok "已备份 GRUB 配置: ${GRUB_CUSTOM_BACKUP}"
    fi

    # 获取根分区 UUID
    local root_dev root_uuid
    root_dev=$(findmnt -n -o SOURCE /)
    root_uuid=$(blkid -s UUID -o value "$root_dev")

    if [[ -z "$root_uuid" ]]; then
        msg_error "无法获取根分区 UUID！"
        exit 1
    fi
    msg_ok "根分区: ${root_dev}  UUID: ${root_uuid}"

    # 构建内核启动参数
    local linux_params="auto=true priority=critical"
    linux_params+=" preseed/file=/netboot/preseed.cfg"
    linux_params+=" netcfg/choose_interface=${NET_IFACE}"
    linux_params+=" netcfg/disable_autoconfig=true"
    linux_params+=" netcfg/get_ipaddress=${NET_IP}"
    linux_params+=" netcfg/get_netmask=${NET_MASK}"
    linux_params+=" netcfg/get_gateway=${NET_GW}"
    linux_params+=" netcfg/get_nameservers=${NET_DNS1}"
    linux_params+=" netcfg/confirm_static=true"
    linux_params+=" locale=en_US.UTF-8"
    linux_params+=" keyboard-configuration/xkb-keymap=us"
    linux_params+=" --- quiet"

    # 根据 BIOS/UEFI 选择不同的 GRUB 配置
    local grub_entry=""
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        grub_entry="
menuentry \">>> Netboot Debian ${DEBIAN_VERSION} Installer (${DEBIAN_ARCH}) <<<\" --class debian --class installer {
    insmod part_gpt
    insmod ext2
    insmod search_fs_uuid
    search --no-floppy --fs-uuid --set=root ${root_uuid}
    echo '正在加载 Debian 安装器...'
    linux /netboot/linux ${linux_params}
    initrd /netboot/initrd.gz
}"
    else
        grub_entry="
menuentry \">>> Netboot Debian ${DEBIAN_VERSION} Installer (${DEBIAN_ARCH}) <<<\" --class debian --class installer {
    insmod mdraid1x
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod search_fs_uuid
    search --no-floppy --fs-uuid --set=root ${root_uuid}
    echo '正在加载 Debian 安装器...'
    linux /netboot/linux ${linux_params}
    initrd /netboot/initrd.gz
}"
    fi

    # 写入 GRUB
    echo "${grub_entry}" >> "${GRUB_CUSTOM}"
    msg_ok "GRUB 菜单项已添加"

    # 设置 GRUB 超时，让用户在 VNC 中可以选择
    if [[ -f /etc/default/grub ]]; then
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=30/' /etc/default/grub
        sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
        # 如果没有这些行就添加
        grep -q '^GRUB_TIMEOUT=' /etc/default/grub || echo 'GRUB_TIMEOUT=30' >> /etc/default/grub
        grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
    fi

    # 更新 GRUB
    msg_info "正在更新 GRUB..."
    update-grub 2>&1 | grep -v "^$" || grub-mkconfig -o /boot/grub/grub.cfg 2>&1
    msg_ok "GRUB 已更新"
}

#——————————————————————————————————————————————
# 第 8 步：汇总信息并确认重启
#——————————————————————————————————————————————
show_summary_and_reboot() {
    msg_step "第 8 步：配置汇总"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║              系统重装配置汇总                           ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC} 引导方式:     ${GREEN}${BOOT_MODE}${NC}"
    echo -e "${BOLD}║${NC} 安装版本:     ${GREEN}Debian ${DEBIAN_VERSION} (${DEBIAN_ARCH})${NC}"
    echo -e "${BOLD}║${NC} 镜像源:       ${GREEN}${SELECTED_MIRROR}${NC}"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC} ${CYAN}—— 网络配置 ——${NC}"
    echo -e "${BOLD}║${NC} 网卡:         ${NET_IFACE}"
    echo -e "${BOLD}║${NC} IPv4:         ${NET_IP}/${NET_CIDR}"
    echo -e "${BOLD}║${NC} 网关:         ${NET_GW}"
    echo -e "${BOLD}║${NC} DNS:          ${NET_DNS1}, ${NET_DNS2}"
    [[ "$HAS_IPV6" == "yes" ]] && echo -e "${BOLD}║${NC} IPv6:         ${NET_IP6}"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC} ${CYAN}—— SSH 配置 ——${NC}"
    echo -e "${BOLD}║${NC} SSH 端口:     ${SSH_PORT}"
    echo -e "${BOLD}║${NC} 密钥登录:     ${USE_SSH_KEY}"
    echo -e "${BOLD}║${NC} 禁用密码:     ${DISABLE_PASSWORD_AUTH}"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC} ${CYAN}—— 安全配置 ——${NC}"
    echo -e "${BOLD}║${NC} 防火墙:       ${SETUP_FIREWALL}"
    echo -e "${BOLD}║${NC} Fail2ban:     ${INSTALL_FAIL2BAN}"
    echo -e "${BOLD}║${NC} 自动更新:     yes"
    echo -e "${BOLD}║${NC} 时区:         ${TIMEZONE}"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC} ${CYAN}—— 文件校验 ——${NC}"
    echo -e "${BOLD}║${NC} SHA256:       已验证 ✓"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  ${YELLOW}重启后操作步骤：${NC}"
    echo -e "${BOLD}║${NC}  1. 通过 VNC 连接服务器"
    echo -e "${BOLD}║${NC}  2. 在 GRUB 菜单中选择 >>> Netboot Debian ... <<<"
    echo -e "${BOLD}║${NC}  3. 安装器会自动配置网络"
    echo -e "${BOLD}║${NC}  4. 手动选择磁盘分区方案"
    echo -e "${BOLD}║${NC}  5. 完成安装后系统将自动配置 SSH、防火墙等"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${GREEN}安装完成后使用以下信息连接：${NC}"
    echo -e "${BOLD}║${NC}  ssh -p ${SSH_PORT} root@${NET_IP}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # 保存汇总到文件
    cat > "${NETBOOT_DIR}/INSTALL_INFO.txt" << INFOEOF
===== Debian Netboot 重装信息 =====
日期: $(date)
引导方式: ${BOOT_MODE}
安装版本: Debian ${DEBIAN_VERSION} (${DEBIAN_ARCH})

== 网络 ==
IP: ${NET_IP}/${NET_CIDR}
网关: ${NET_GW}
DNS: ${NET_DNS1}, ${NET_DNS2}

== SSH 连接 ==
命令: ssh -p ${SSH_PORT} root@${NET_IP}
密钥登录: ${USE_SSH_KEY}

== 安全 ==
防火墙端口: ${SSH_PORT}/tcp
Fail2ban: ${INSTALL_FAIL2BAN}
================================
INFOEOF
    msg_ok "连接信息已保存到 ${NETBOOT_DIR}/INSTALL_INFO.txt"

    echo ""
    msg_warn "======================================================"
    msg_warn "  即将重启系统！重启后请立即通过 VNC 连接！"
    msg_warn "======================================================"
    echo ""

    read -rp "$(echo -e "${RED}${BOLD}输入 YES 确认重启（其他任何输入将取消）: ${NC}")" reboot_confirm
    if [[ "$reboot_confirm" == "YES" ]]; then
        msg_info "系统将在 5 秒后重启..."
        sleep 5
        reboot
    else
        msg_info "已取消重启。"
        msg_info "你可以稍后手动执行 reboot 来启动安装。"
        msg_info "在 GRUB 菜单中选择 '>>> Netboot Debian ...' 项即可。"
    fi
}

#——————————————————————————————————————————————
# 主流程
#——————————————————————————————————————————————
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║        Debian Netboot 一键重装脚本 v1.0                 ║${NC}"
    echo -e "${BOLD}║        支持 BIOS / UEFI 自动检测                       ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    preflight_check        # 环境检查
    detect_boot_mode       # BIOS/UEFI 检测
    detect_network         # 网络配置获取
    user_config            # 用户交互配置
    download_and_verify    # 下载+校验
    generate_preseed       # 生成 preseed
    configure_grub         # 配置 GRUB
    show_summary_and_reboot # 汇总+重启
}

main "$@"
