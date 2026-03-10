
#!/bin/bash
set -Eeuo pipefail

trap 'echo "[错误] 脚本在第 $LINENO 行失败。" >&2' ERR

RELEASE="bookworm"
ARCH="amd64"

WORKDIR="/netboot"
GRUB_CUSTOM="/etc/grub.d/40_custom"
NETWORK_INFO_FILE="/root/netboot-network-info.txt"

DIST_BASE="https://deb.debian.org/debian/dists/${RELEASE}"
IMG_BASE="${DIST_BASE}/main/installer-${ARCH}/current/images"
NETBOOT_BASE="${IMG_BASE}/netboot/debian-installer/${ARCH}"

NETBOOT_MENU_ID="netboot-debian-${RELEASE}-${ARCH}"
NETBOOT_MENU_TITLE="Netboot Debian ${RELEASE^} Installer ${ARCH^^}"

BEGIN_MARK="# BEGIN managed netboot reinstall entry"
END_MARK="# END managed netboot reinstall entry"

log() {
  echo "[信息] $*"
}

die() {
  echo "[致命错误] $*" >&2
  exit 1
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "请用 root 运行此脚本。"
  fi
}

install_required_packages() {
  log "安装必须软件..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates \
    wget \
    gpgv \
    debian-archive-keyring \
    grub-common \
    grub2-common \
    util-linux

  command -v wget >/dev/null 2>&1 || die "wget 不存在"
  command -v gpgv >/dev/null 2>&1 || die "gpgv 不存在"
  command -v grub-editenv >/dev/null 2>&1 || die "grub-editenv 不存在"
  command -v grub-reboot >/dev/null 2>&1 || die "grub-reboot 不存在"
  command -v update-grub >/dev/null 2>&1 || die "update-grub 不存在"
  command -v ip >/dev/null 2>&1 || die "ip 命令不存在"

  [[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]] || \
    die "缺少 /usr/share/keyrings/debian-archive-keyring.gpg"
}

download_files() {
  log "准备下载目录..."
  install -d -m 0755 "${WORKDIR}"
  cd "${WORKDIR}"

  log "下载 netboot 文件与校验文件..."
  wget -4 -O linux      "${NETBOOT_BASE}/linux"
  wget -4 -O initrd.gz  "${NETBOOT_BASE}/initrd.gz"
  wget -4 -O SHA256SUMS "${IMG_BASE}/SHA256SUMS"
  wget -4 -O InRelease  "${DIST_BASE}/InRelease"

  [[ -s linux ]] || die "linux 下载失败或为空"
  [[ -s initrd.gz ]] || die "initrd.gz 下载失败或为空"
  [[ -s SHA256SUMS ]] || die "SHA256SUMS 下载失败或为空"
  [[ -s InRelease ]] || die "InRelease 下载失败或为空"
}

verify_inrelease_signature() {
  log "验证 InRelease 的 Debian 签名..."
  gpgv --keyring /usr/share/keyrings/debian-archive-keyring.gpg InRelease
}

verify_sha256sums_file() {
  log "用已签名的 InRelease 验证 SHA256SUMS..."
  local expected_line

  expected_line="$(
    awk -v target="main/installer-${ARCH}/current/images/SHA256SUMS" '
      length($1) == 64 && $3 == target {
        print $1 "  SHA256SUMS"
        found=1
        exit
      }
      END {
        if (!found) exit 1
      }
    ' InRelease
  )" || die "无法在 InRelease 中找到 SHA256SUMS 的 SHA256 记录"

  printf '%s\n' "${expected_line}" | sha256sum -c -
}

verify_netboot_files() {
  log "验证 linux 与 initrd.gz 的 SHA256..."
  awk -v prefix="./netboot/debian-installer/${ARCH}/" '
    $2 == prefix "linux" || $2 == prefix "initrd.gz" {
      file = $2
      sub("^" prefix, "", file)
      print $1 "  " file
      found++
    }
    END {
      if (found != 2) exit 1
    }
  ' SHA256SUMS | sha256sum -c - || die "linux/initrd.gz 校验失败"

  ls -l "${WORKDIR}/linux" "${WORKDIR}/initrd.gz"
}

detect_root_uuid() {
  log "查找根文件系统 UUID..."
  ROOT_DEV="$(findmnt -n -o SOURCE / || true)"
  ROOT_UUID="$(findmnt -n -o UUID / || true)"

  if [[ -z "${ROOT_UUID}" && -n "${ROOT_DEV}" ]]; then
    ROOT_UUID="$(blkid -s UUID -o value "${ROOT_DEV}" || true)"
  fi

  [[ -n "${ROOT_DEV}" ]] || die "无法识别根文件系统设备"
  [[ -n "${ROOT_UUID}" ]] || die "无法识别根文件系统 UUID"

  log "ROOT_DEV=${ROOT_DEV}"
  log "ROOT_UUID=${ROOT_UUID}"
}

ensure_40_custom_exists() {
  if [[ ! -e "${GRUB_CUSTOM}" ]]; then
    log "创建 ${GRUB_CUSTOM}..."
    cat > "${GRUB_CUSTOM}" <<'EOF'
#!/bin/sh
exec tail -n +3 $0
# Custom grub menu entries follow.
EOF
    chmod 0755 "${GRUB_CUSTOM}"
  fi

  [[ -x "${GRUB_CUSTOM}" ]] || chmod 0755 "${GRUB_CUSTOM}"
}

write_grub_entry() {
  log "备份并写入 GRUB 菜单..."
  ensure_40_custom_exists

  local backup tmp
  backup="${GRUB_CUSTOM}.bak.$(date +%F-%H%M%S)"
  tmp="$(mktemp)"

  cp -a "${GRUB_CUSTOM}" "${backup}"

  awk -v begin="${BEGIN_MARK}" -v end="${END_MARK}" '
    $0 == begin {skip=1; next}
    $0 == end   {skip=0; next}
    !skip       {print}
  ' "${GRUB_CUSTOM}" > "${tmp}"

  cat >> "${tmp}" <<EOF

${BEGIN_MARK}
menuentry "${NETBOOT_MENU_TITLE}" --id "${NETBOOT_MENU_ID}" {
    insmod mdraid1x
    insmod part_gpt
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /netboot/linux priority=low
    initrd /netboot/initrd.gz
}
${END_MARK}
EOF

  install -m 0755 "${tmp}" "${GRUB_CUSTOM}"
  rm -f "${tmp}"
}

update_grub_config() {
  log "更新 GRUB..."
  update-grub
}

prepare_next_boot() {
  log "准备 GRUB environment block..."
  if [[ ! -e /boot/grub/grubenv ]]; then
    grub-editenv /boot/grub/grubenv create
  fi

  grub-editenv /boot/grub/grubenv list >/dev/null

  log "设置下一次启动自动进入 netboot 安装器..."
  grub-reboot "${NETBOOT_MENU_ID}"

  log "当前 grubenv 内容："
  grub-editenv /boot/grub/grubenv list || true
}

prefix_to_netmask() {
  local prefix="${1:-0}"
  local mask=""
  local full_octets=$((prefix / 8))
  local partial=$((prefix % 8))
  local i val

  for ((i=0; i<4; i++)); do
    if (( i < full_octets )); then
      val=255
    elif (( i == full_octets && partial > 0 )); then
      val=$((256 - 2**(8 - partial)))
    else
      val=0
    fi

    mask+="${val}"
    (( i < 3 )) && mask+="."
  done

  echo "${mask}"
}

get_hostname_value() {
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl --static 2>/dev/null || hostname
  else
    hostname
  fi
}

get_primary_iface() {
  ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

get_iface_mac() {
  local dev="$1"
  cat "/sys/class/net/${dev}/address" 2>/dev/null || echo "N/A"
}

get_iface_ipv4_cidr() {
  local dev="$1"
  ip -o -4 addr show dev "${dev}" scope global 2>/dev/null | awk 'NR==1 {print $4}'
}

get_iface_ipv6_global() {
  local dev="$1"
  ip -o -6 addr show dev "${dev}" scope global 2>/dev/null | awk 'NR==1 {print $4}'
}

get_iface_gateway4() {
  local dev="$1"
  ip -4 route show default dev "${dev}" 2>/dev/null | awk '/default/ {print $3; exit}'
}

get_dns_servers() {
  awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null
}

print_network_config() {
  log "导出当前网络配置到 ${NETWORK_INFO_FILE} ..."

  local hostname_value primary_iface primary_mac primary_ipv4_cidr primary_ipv4 primary_prefix primary_netmask primary_gw4 primary_ipv6
  hostname_value="$(get_hostname_value || true)"
  primary_iface="$(get_primary_iface || true)"

  if [[ -n "${primary_iface}" ]]; then
    primary_mac="$(get_iface_mac "${primary_iface}")"
    primary_ipv4_cidr="$(get_iface_ipv4_cidr "${primary_iface}" || true)"
    primary_gw4="$(get_iface_gateway4 "${primary_iface}" || true)"
    primary_ipv6="$(get_iface_ipv6_global "${primary_iface}" || true)"

    if [[ -n "${primary_ipv4_cidr}" ]]; then
      primary_ipv4="${primary_ipv4_cidr%/*}"
      primary_prefix="${primary_ipv4_cidr#*/}"
      primary_netmask="$(prefix_to_netmask "${primary_prefix}")"
    else
      primary_ipv4="N/A"
      primary_prefix="N/A"
      primary_netmask="N/A"
    fi
  else
    primary_mac="N/A"
    primary_ipv4="N/A"
    primary_prefix="N/A"
    primary_netmask="N/A"
    primary_gw4="N/A"
    primary_ipv6="N/A"
  fi

  {
    echo "============================================================"
    echo " Debian 安装器手动网络配置参考"
    echo "============================================================"
    echo
    echo "请在安装器中优先填写下面这一组信息："
    echo
    printf '  网卡名称：%s\n' "${primary_iface:-N/A}"
    printf '  主机名：%s\n' "${hostname_value:-N/A}"
    printf '  IPv4 地址：%s\n' "${primary_ipv4:-N/A}"
    printf '  子网掩码：%s\n' "${primary_netmask:-N/A}"
    printf '  前缀长度：%s\n' "${primary_prefix:-N/A}"
    printf '  默认网关：%s\n' "${primary_gw4:-N/A}"

    echo "  DNS 服务器："
    if get_dns_servers | grep -q .; then
      get_dns_servers | sed 's/^/    - /'
    else
      echo "    - N/A"
    fi

    printf '  IPv6 地址（如需）：%s\n' "${primary_ipv6:-N/A}"
    printf '  MAC 地址：%s\n' "${primary_mac:-N/A}"
    echo

    echo "------------------------------------------------------------"
    echo " 全部网卡信息"
    echo "------------------------------------------------------------"
    printf '%-12s %-18s %-22s %-22s %-18s\n' "网卡" "MAC 地址" "IPv4 地址" "IPv6 地址" "默认网关"
    printf '%-12s %-18s %-22s %-22s %-18s\n' "------------" "------------------" "----------------------" "----------------------" "------------------"

    while read -r dev; do
      [[ -n "${dev}" ]] || continue
      mac="$(get_iface_mac "${dev}")"
      ipv4="$(get_iface_ipv4_cidr "${dev}" || true)"
      ipv6="$(get_iface_ipv6_global "${dev}" || true)"
      gw4="$(get_iface_gateway4 "${dev}" || true)"

      [[ -n "${ipv4}" ]] || ipv4="-"
      [[ -n "${ipv6}" ]] || ipv6="-"
      [[ -n "${gw4}" ]] || gw4="-"

      printf '%-12s %-18s %-22s %-22s %-18s\n' "${dev}" "${mac}" "${ipv4}" "${ipv6}" "${gw4}"
    done < <(ls /sys/class/net | sort)
    echo

    echo "------------------------------------------------------------"
    echo " DNS 配置"
    echo "------------------------------------------------------------"
    if get_dns_servers | grep -q .; then
      get_dns_servers | nl -w1 -s'. '
    else
      echo "未发现 DNS 服务器配置"
    fi
    echo

    echo "------------------------------------------------------------"
    echo " 原始网络信息（排错时使用）"
    echo "------------------------------------------------------------"
    echo
    echo "[IPv4 地址简表]"
    ip -4 -br addr show || true
    echo
    echo "[IPv6 地址简表]"
    ip -6 -br addr show || true
    echo
    echo "[IPv4 路由表]"
    ip -4 route show || true
    echo
    echo "[IPv6 路由表]"
    ip -6 route show || true
    echo
    echo "[DNS 原始配置]"
    sed -nE '/^(nameserver|search|domain)[[:space:]]+/p' /etc/resolv.conf || true
    echo
    echo "============================================================"
    echo " 填写建议"
    echo "============================================================"
    echo "1. 安装器中优先选择上面“请在安装器中优先填写下面这一组信息”里的网卡。"
    echo "2. 如果只需要手动配置 IPv4，就填写：IPv4 地址、子网掩码、默认网关、DNS、主机名。"
    echo "3. 如果你的 VPS 厂商要求固定 IP，请严格按这里显示的值填写。"
    echo
  } | tee "${NETWORK_INFO_FILE}"

  chmod 600 "${NETWORK_INFO_FILE}" || true
  log "网络配置已保存到 ${NETWORK_INFO_FILE}"
}

print_summary() {
  cat <<EOF

[完成] 已执行以下操作：
  1. 安装必须软件
  2. 下载 Debian netboot 安装器
  3. 验证 InRelease 签名
  4. 验证 SHA256SUMS
  5. 验证 linux / initrd.gz
  6. 写入 ${GRUB_CUSTOM}
  7. 执行 update-grub
  8. 设置下一次启动自动进入：
     ${NETBOOT_MENU_TITLE}
  9. 导出当前网络配置：
     ${NETWORK_INFO_FILE}

现在执行以下任一命令重启后：
  reboot
  systemctl reboot

GRUB 会在“下一次启动”自动选择该安装器入口。
EOF
}

main() {
  need_root
  install_required_packages
  download_files
  verify_inrelease_signature
  verify_sha256sums_file
  verify_netboot_files
  detect_root_uuid
  write_grub_entry
  update_grub_config
  prepare_next_boot
  print_network_config
  print_summary
}

main "$@"
