#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 (trixie) amd64 netboot installer bootstrap for an existing Debian host.
#
# This script does NOT repartition or install Debian by itself. It downloads and
# verifies the official Debian installer, adds a dedicated GRUB entry, and arms
# that entry for the next boot only. The actual installation is performed from
# the VPS/provider console after reboot.
#
# Optional environment variables:
#   FORCE_IPV4=1                 Force IPv4 for downloads (default: 1)
#   ASSUME_YES=1                 Skip the destructive-action confirmation
#   ALLOW_UNSAFE_GRUBENV=1       Allow LVM/RAID/encrypted/unsupported grubenv
#   INSTALLER_ARGS='...'         Extra Debian-installer kernel arguments
#
# Supported target: Debian 13 (trixie), amd64.

export LC_ALL=C
umask 077

readonly RELEASE="trixie"
readonly ARCH="amd64"
readonly MIRROR="https://deb.debian.org/debian"
readonly DIST_BASE="${MIRROR}/dists/${RELEASE}"
readonly IMG_BASE="${DIST_BASE}/main/installer-${ARCH}/current/images"
readonly NETBOOT_BASE="${IMG_BASE}/netboot/debian-installer/${ARCH}"

readonly WORKDIR="/boot/debian-netboot"
readonly GRUB_SCRIPT="/etc/grub.d/41_debian_netboot_reinstall"
readonly GRUB_CFG="/boot/grub/grub.cfg"
readonly GRUBENV="/boot/grub/grubenv"
readonly NETWORK_INFO_FILE="/root/debian-reinstall-network.txt"
readonly BACKUP_DIR="/root/debian-reinstall-backups"

readonly MENU_ID="debian-netboot-${RELEASE}-${ARCH}"
readonly MENU_TITLE="Debian 13 (trixie) netboot installer (amd64)"
readonly KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
readonly MIN_FREE_KIB=131072

FORCE_IPV4="${FORCE_IPV4:-1}"
ASSUME_YES="${ASSUME_YES:-0}"
ALLOW_UNSAFE_GRUBENV="${ALLOW_UNSAFE_GRUBENV:-0}"
INSTALLER_ARGS="${INSTALLER_ARGS:-}"

TMPDIR_PATH=""
GRUB_SCRIPT_BACKUP=""
GRUB_SCRIPT_EXISTED=0
GRUB_CHANGE_PENDING=0
NEXT_ENTRY_ARMED=0

BOOT_MOUNT=""
BOOT_UUID=""
GRUB_WORKDIR=""
GRUB_FS=""
GRUB_PARTMAPS=""
GRUB_ABSTRACTIONS=""
KERNEL_CMDLINE=""

log() {
  printf '[信息] %s\n' "$*"
}

warn() {
  printf '[警告] %s\n' "$*" >&2
}

die() {
  printf '[致命错误] %s\n' "$*" >&2
  exit 1
}

on_err() {
  local rc=$?
  local line=${BASH_LINENO[0]:-${LINENO}}
  printf '[错误] 脚本在第 %s 行失败，退出码：%s\n' "${line}" "${rc}" >&2
  return 0
}

rollback_grub_change() {
  (( GRUB_CHANGE_PENDING == 1 )) || return 0

  warn "正在回滚本次 GRUB 菜单修改..."

  if (( GRUB_SCRIPT_EXISTED == 1 )); then
    if [[ -n "${GRUB_SCRIPT_BACKUP}" && -f "${GRUB_SCRIPT_BACKUP}" ]]; then
      cp -a -- "${GRUB_SCRIPT_BACKUP}" "${GRUB_SCRIPT}"
    else
      warn "找不到原 GRUB 脚本备份，无法自动恢复 ${GRUB_SCRIPT}"
      return 1
    fi
  else
    rm -f -- "${GRUB_SCRIPT}"
  fi

  if command -v update-grub >/dev/null 2>&1; then
    update-grub >/dev/null 2>&1 || {
      warn "回滚文件后 update-grub 失败，请手动执行 update-grub。"
      return 1
    }
  fi

  GRUB_CHANGE_PENDING=0
}

cleanup() {
  local rc=$?
  trap - EXIT
  set +e

  if (( rc != 0 && NEXT_ENTRY_ARMED == 1 )); then
    warn "脚本异常退出，正在清除 GRUB 一次性启动项..."
    grub-editenv "${GRUBENV}" unset next_entry >/dev/null 2>&1 || \
      warn "无法自动清除 next_entry，请运行：grub-editenv '${GRUBENV}' unset next_entry"
  fi

  if (( rc != 0 )); then
    rollback_grub_change || true
  fi

  if [[ -n "${TMPDIR_PATH}" && -d "${TMPDIR_PATH}" ]]; then
    rm -rf -- "${TMPDIR_PATH}"
  fi

  exit "${rc}"
}

trap on_err ERR
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请以 root 身份运行此脚本。"
}

validate_switches() {
  local safe_args_re='^[A-Za-z0-9_./,:=@%+-]+([[:space:]][A-Za-z0-9_./,:=@%+-]+)*$'

  [[ "${FORCE_IPV4}" =~ ^[01]$ ]] || die "FORCE_IPV4 只能是 0 或 1。"
  [[ "${ASSUME_YES}" =~ ^[01]$ ]] || die "ASSUME_YES 只能是 0 或 1。"
  [[ "${ALLOW_UNSAFE_GRUBENV}" =~ ^[01]$ ]] || \
    die "ALLOW_UNSAFE_GRUBENV 只能是 0 或 1。"

  if [[ -n "${INSTALLER_ARGS}" ]]; then
    [[ "${INSTALLER_ARGS}" != *$'\n'* && "${INSTALLER_ARGS}" != *$'\r'* ]] || \
      die "INSTALLER_ARGS 不能包含换行符。"
    [[ "${INSTALLER_ARGS}" =~ ${safe_args_re} ]] || \
      die "INSTALLER_ARGS 含有不安全字符。"
  fi
}

check_host_os_and_arch() {
  [[ -r /etc/os-release ]] || die "找不到 /etc/os-release。"

  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || \
    die "当前系统不是 Debian；为避免破坏引导配置，脚本拒绝继续。"

  command -v dpkg >/dev/null 2>&1 || die "缺少 dpkg。"
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || \
    die "当前系统不是 amd64，脚本仅支持 amd64。"
  [[ "$(uname -m)" == "x86_64" ]] || \
    die "当前内核架构不是 x86_64，脚本拒绝继续。"
  [[ -d /etc/grub.d && -d /boot/grub ]] || \
    die "当前系统未发现标准 Debian GRUB 配置目录，脚本拒绝继续。"
}

install_required_packages() {
  log "更新 APT 索引并安装必要软件..."

  export DEBIAN_FRONTEND=noninteractive
  export APT_LISTCHANGES_FRONTEND=none

  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    coreutils \
    debian-archive-keyring \
    file \
    gpgv \
    grep \
    gzip \
    hostname \
    iproute2 \
    mawk \
    sed \
    util-linux \
    wget \
    grub-common \
    grub2-common
}

require_commands_and_files() {
  local cmd
  local -a commands=(
    awk basename cat chmod chown cp date df file findmnt grep grub-editenv
    grub-mkrelpath grub-probe grub-reboot grub-script-check gzip head hostname
    install ip mktemp mv rm sed sha256sum stat sync uname update-grub wget
  )

  for cmd in "${commands[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "缺少命令：${cmd}"
  done

  [[ -r "${KEYRING}" ]] || die "缺少 Debian archive keyring：${KEYRING}"
  [[ -d /etc/grub.d ]] || die "找不到 /etc/grub.d；系统似乎未使用 Debian GRUB。"
  [[ -d /boot/grub ]] || die "找不到 /boot/grub；系统似乎未安装 GRUB。"
  [[ ! -L "${GRUB_SCRIPT}" ]] || die "${GRUB_SCRIPT} 是符号链接，拒绝覆盖。"
}

check_grub_environment() {
  local abstractions fs existing_next

  abstractions="$(grub-probe --target=abstraction /boot/grub 2>/dev/null)" || \
    die "无法探测 /boot/grub 的 GRUB 抽象层。"
  fs="$(grub-probe --target=fs /boot/grub 2>/dev/null)" || \
    die "无法探测 /boot/grub 的文件系统。"
  [[ -n "${fs}" ]] || die "grub-probe 未返回 /boot/grub 的文件系统类型。"

  if [[ -n "${abstractions}" || "${fs}" == "zfs" || "${fs}" == "btrfs" ]]; then
    if (( ALLOW_UNSAFE_GRUBENV == 0 )); then
      die "GRUB environment block 所在存储不适合安全使用 grub-reboot（abstraction='${abstractions:-none}', fs='${fs:-unknown}'）。这可能导致安装器启动项无法自动清除并形成重启循环。若你已确认风险，可设置 ALLOW_UNSAFE_GRUBENV=1 后重新运行。"
    fi
    warn "已允许高风险 grubenv 布局：abstraction='${abstractions:-none}', fs='${fs:-unknown}'。"
  fi

  if [[ ! -e "${GRUBENV}" ]]; then
    log "创建 GRUB environment block..."
    grub-editenv "${GRUBENV}" create
  fi

  [[ -f "${GRUBENV}" ]] || die "${GRUBENV} 不是普通文件。"
  grub-editenv "${GRUBENV}" list >/dev/null

  existing_next="$(
    grub-editenv "${GRUBENV}" list |
      sed -n 's/^next_entry=//p' |
      head -n 1
  )"
  [[ -z "${existing_next}" ]] || \
    die "GRUB 已存在一次性启动项 next_entry=${existing_next}；请先确认并清除它。"
}

prepare_workdir() {
  local available_kib

  [[ ! -L "${WORKDIR}" ]] || die "${WORKDIR} 是符号链接，拒绝使用。"
  install -d -o root -g root -m 0755 -- "${WORKDIR}"

  [[ -d "${WORKDIR}" && -w "${WORKDIR}" ]] || die "${WORKDIR} 不可写。"

  available_kib="$(df -Pk "${WORKDIR}" | awk 'NR==2 {print $4}')"
  [[ "${available_kib}" =~ ^[0-9]+$ ]] || die "无法读取 ${WORKDIR} 的可用空间。"
  (( available_kib >= MIN_FREE_KIB )) || \
    die "${WORKDIR} 可用空间不足：${available_kib} KiB；至少需要 ${MIN_FREE_KIB} KiB。"

  TMPDIR_PATH="$(mktemp -d "${WORKDIR}/.download.XXXXXXXX")"
  chmod 0700 "${TMPDIR_PATH}"
}

download_one() {
  local url=$1
  local output=$2
  local -a args=(
    --https-only
    --secure-protocol=TLSv1_2
    --timeout=30
    --dns-timeout=15
    --connect-timeout=15
    --read-timeout=30
    --tries=3
    --retry-connrefused
    --max-redirect=5
    --no-verbose
  )

  if (( FORCE_IPV4 == 1 )); then
    args+=( -4 )
  fi

  wget "${args[@]}" -O "${output}" "${url}"
  [[ -s "${output}" ]] || die "下载结果为空：${url}"
}

download_metadata_files() {
  log "下载 Debian ${RELEASE} 签名元数据..."

  download_one "${DIST_BASE}/InRelease" "${TMPDIR_PATH}/InRelease"
  download_one "${IMG_BASE}/SHA256SUMS" "${TMPDIR_PATH}/SHA256SUMS"
}

download_payload_files() {
  log "下载 Debian ${RELEASE} 官方 netboot 内核与 initrd..."

  download_one "${NETBOOT_BASE}/linux" "${TMPDIR_PATH}/linux"
  download_one "${NETBOOT_BASE}/initrd.gz" "${TMPDIR_PATH}/initrd.gz"
}

verify_inrelease() {
  log "验证 Debian InRelease 签名与发行版身份..."

  gpgv --keyring "${KEYRING}" "${TMPDIR_PATH}/InRelease"

  grep -Fxq "Codename: ${RELEASE}" "${TMPDIR_PATH}/InRelease" || \
    die "InRelease 的 Codename 不是 ${RELEASE}。"

  awk -v arch="${ARCH}" '
    /^Architectures:[[:space:]]/ {
      for (i=2; i<=NF; i++) {
        if ($i == arch) found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${TMPDIR_PATH}/InRelease" || \
    die "InRelease 未声明支持 ${ARCH}。"
}

verify_sha256sums_metadata() {
  local target expected_hash expected_size actual_size
  target="main/installer-${ARCH}/current/images/SHA256SUMS"

  log "用已签名的 InRelease 验证 SHA256SUMS..."

  local metadata_line
  metadata_line="$(
    awk -v target="${target}" '
      $1 == "SHA256:" { in_sha256=1; next }
      in_sha256 && /^[A-Za-z][A-Za-z0-9-]*:/ { in_sha256=0 }
      in_sha256 && length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && $3 == target {
        print $1, $2
        found++
      }
      END {
        if (found != 1) exit 1
      }
    ' "${TMPDIR_PATH}/InRelease"
  )" || die "无法从 InRelease 唯一定位 ${target}。"
  read -r expected_hash expected_size <<<"${metadata_line}"

  [[ "${expected_size}" =~ ^[0-9]+$ ]] || die "InRelease 中的 SHA256SUMS 大小无效。"
  actual_size="$(stat -c '%s' "${TMPDIR_PATH}/SHA256SUMS")"
  [[ "${actual_size}" == "${expected_size}" ]] || \
    die "SHA256SUMS 文件大小不匹配：期望 ${expected_size}，实际 ${actual_size}。"

  printf '%s  %s\n' "${expected_hash}" "${TMPDIR_PATH}/SHA256SUMS" |
    sha256sum --check --strict -
}

verify_installer_payloads() {
  local checks_file="${TMPDIR_PATH}/installer-checksums"

  log "验证 linux 与 initrd.gz 的 SHA256..."

  awk -v arch="${ARCH}" '
    {
      hash=$1
      name=$2
      sub(/^\*/, "", name)
      sub(/^\.\//, "", name)
      prefix="netboot/debian-installer/" arch "/"

      if (name == prefix "linux") {
        print hash "  linux"
        linux_count++
      } else if (name == prefix "initrd.gz") {
        print hash "  initrd.gz"
        initrd_count++
      }
    }
    END {
      if (linux_count != 1 || initrd_count != 1) exit 1
    }
  ' "${TMPDIR_PATH}/SHA256SUMS" > "${checks_file}" || \
    die "SHA256SUMS 中未唯一找到 linux 和 initrd.gz。"

  (
    cd "${TMPDIR_PATH}"
    sha256sum --check --strict "$(basename "${checks_file}")"
  )

  gzip -t "${TMPDIR_PATH}/initrd.gz"

  file "${TMPDIR_PATH}/linux" | grep -Eqi 'Linux kernel|Linux/x86 Kernel' || \
    die "下载的 linux 文件未被识别为 Linux x86 内核。"
  file "${TMPDIR_PATH}/initrd.gz" | grep -qi 'gzip compressed data' || \
    die "下载的 initrd.gz 未被识别为 gzip 数据。"
}

install_verified_payloads() {
  log "将已验证文件原子安装到 ${WORKDIR}..."

  chmod 0644 \
    "${TMPDIR_PATH}/linux" \
    "${TMPDIR_PATH}/initrd.gz" \
    "${TMPDIR_PATH}/SHA256SUMS" \
    "${TMPDIR_PATH}/InRelease"

  mv -fT -- "${TMPDIR_PATH}/linux" "${WORKDIR}/linux"
  mv -fT -- "${TMPDIR_PATH}/initrd.gz" "${WORKDIR}/initrd.gz"
  mv -fT -- "${TMPDIR_PATH}/SHA256SUMS" "${WORKDIR}/SHA256SUMS"
  mv -fT -- "${TMPDIR_PATH}/InRelease" "${WORKDIR}/InRelease"

  chown root:root \
    "${WORKDIR}/linux" \
    "${WORKDIR}/initrd.gz" \
    "${WORKDIR}/SHA256SUMS" \
    "${WORKDIR}/InRelease"
  chmod 0644 \
    "${WORKDIR}/linux" \
    "${WORKDIR}/initrd.gz" \
    "${WORKDIR}/SHA256SUMS" \
    "${WORKDIR}/InRelease"

  sync
}

probe_grub_paths() {
  local module

  log "探测 GRUB 访问 ${WORKDIR} 所需信息..."

  BOOT_MOUNT="$(findmnt -n -o TARGET -T "${WORKDIR}")"
  [[ -n "${BOOT_MOUNT}" ]] || die "无法确定 ${WORKDIR} 所在挂载点。"

  GRUB_WORKDIR="$(grub-mkrelpath "${WORKDIR}")"
  [[ "${GRUB_WORKDIR}" == /* ]] || die "生成的 GRUB 路径无效：${GRUB_WORKDIR}"
  [[ "${GRUB_WORKDIR}" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
    die "GRUB 路径包含不安全字符：${GRUB_WORKDIR}"

  BOOT_UUID="$(grub-probe --target=fs_uuid "${WORKDIR}")"
  GRUB_FS="$(grub-probe --target=fs "${WORKDIR}")"
  GRUB_PARTMAPS="$(grub-probe --target=partmap "${WORKDIR}" 2>/dev/null || true)"
  GRUB_ABSTRACTIONS="$(grub-probe --target=abstraction "${WORKDIR}" 2>/dev/null || true)"

  [[ -n "${BOOT_UUID}" ]] || die "grub-probe 未返回文件系统 UUID。"
  [[ "${BOOT_UUID}" =~ ^[A-Fa-f0-9-]+$ ]] || die "文件系统 UUID 格式异常：${BOOT_UUID}"
  [[ -n "${GRUB_FS}" ]] || die "grub-probe 未返回文件系统模块。"

  for module in ${GRUB_FS} ${GRUB_PARTMAPS} ${GRUB_ABSTRACTIONS}; do
    [[ "${module}" =~ ^[A-Za-z0-9_+-]+$ ]] || die "GRUB 模块名称异常：${module}"
  done
}

build_kernel_cmdline() {
  local token
  local -a args=( "priority=low" )
  local -a current_cmdline=()

  # Preserve an existing serial-console setting so remote serial consoles keep
  # receiving installer output. VGA-only systems normally have no console= token.
  read -r -a current_cmdline < /proc/cmdline
  for token in "${current_cmdline[@]}"; do
    if [[ "${token}" == console=* ]]; then
      [[ "${token}" =~ ^console=[A-Za-z0-9_,.-]+$ ]] || \
        die "当前内核 console 参数包含异常字符：${token}"
      args+=( "${token}" )
    fi
  done

  if [[ -n "${INSTALLER_ARGS}" ]]; then
    local -a extra=()
    read -r -a extra <<<"${INSTALLER_ARGS}"
    args+=( "${extra[@]}" )
  fi

  KERNEL_CMDLINE="${args[*]}"
}

backup_existing_grub_script() {
  install -d -o root -g root -m 0700 -- "${BACKUP_DIR}"

  if [[ -e "${GRUB_SCRIPT}" ]]; then
    [[ -f "${GRUB_SCRIPT}" ]] || die "${GRUB_SCRIPT} 不是普通文件。"
    GRUB_SCRIPT_EXISTED=1
    GRUB_SCRIPT_BACKUP="$(mktemp "${BACKUP_DIR}/$(basename "${GRUB_SCRIPT}").$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX.bak")"
    cp -a -- "${GRUB_SCRIPT}" "${GRUB_SCRIPT_BACKUP}"
  fi
}

write_grub_script() {
  local tmp module
  local -a module_lines=()

  log "写入独立 GRUB 菜单脚本 ${GRUB_SCRIPT}..."
  backup_existing_grub_script

  for module in ${GRUB_PARTMAPS}; do
    module_lines+=( "    insmod part_${module}" )
  done
  for module in ${GRUB_ABSTRACTIONS}; do
    module_lines+=( "    insmod ${module}" )
  done
  for module in ${GRUB_FS}; do
    module_lines+=( "    insmod ${module}" )
  done

  tmp="$(mktemp "/etc/grub.d/.41_debian_netboot_reinstall.XXXXXXXX")"

  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'exec tail -n +3 "$0"'
    printf '%s\n' '# Generated by debian-netboot-reinstall.sh'
    printf '%s\n' "menuentry '${MENU_TITLE}' --id '${MENU_ID}' {"
    if (( ${#module_lines[@]} > 0 )); then
      printf '%s\n' "${module_lines[@]}"
    fi
    printf '    search --no-floppy --fs-uuid --set=root %s\n' "${BOOT_UUID}"
    printf '    linux %s/linux %s\n' "${GRUB_WORKDIR}" "${KERNEL_CMDLINE}"
    printf '    initrd %s/initrd.gz\n' "${GRUB_WORKDIR}"
    printf '%s\n' '}'
  } > "${tmp}"

  chown root:root "${tmp}"
  chmod 0755 "${tmp}"
  mv -fT -- "${tmp}" "${GRUB_SCRIPT}"
  GRUB_CHANGE_PENDING=1
}

regenerate_and_verify_grub() {
  log "重新生成并验证 GRUB 配置..."

  if ! update-grub; then
    die "update-grub 执行失败。"
  fi

  [[ -s "${GRUB_CFG}" ]] || die "生成后的 ${GRUB_CFG} 不存在或为空。"
  grub-script-check "${GRUB_CFG}"

  grep -Fq -- "--id '${MENU_ID}'" "${GRUB_CFG}" || \
    grep -Fq -- "--id ${MENU_ID}" "${GRUB_CFG}" || \
    die "生成后的 grub.cfg 中找不到菜单 ID：${MENU_ID}"

  grep -Fq -- "linux ${GRUB_WORKDIR}/linux ${KERNEL_CMDLINE}" "${GRUB_CFG}" || \
    die "生成后的 grub.cfg 中找不到预期 linux 行。"
  grep -Fq -- "initrd ${GRUB_WORKDIR}/initrd.gz" "${GRUB_CFG}" || \
    die "生成后的 grub.cfg 中找不到预期 initrd 行。"
}

prefix_to_netmask() {
  local prefix=$1
  local mask=""
  local full_octets partial i value

  [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 )) || return 1

  full_octets=$((prefix / 8))
  partial=$((prefix % 8))

  for ((i=0; i<4; i++)); do
    if (( i < full_octets )); then
      value=255
    elif (( i == full_octets && partial > 0 )); then
      value=$((256 - (1 << (8 - partial))))
    else
      value=0
    fi

    mask+="${value}"
    (( i < 3 )) && mask+='.'
  done

  printf '%s\n' "${mask}"
}

get_real_dns_servers() {
  local file

  for file in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
    [[ -r "${file}" ]] || continue
    awk '
      /^nameserver[[:space:]]+/ {
        address=$2
        if (address !~ /^127\./ && address != "::1") print address
      }
    ' "${file}"
  done | awk '!seen[$0]++'
}

collect_network_info() {
  local route4 iface4 gateway4 source4 cidr4 prefix4 netmask4
  local hostname_value mac4 route6 source6 dns_output

  log "导出当前网络配置到 ${NETWORK_INFO_FILE}..."

  route4="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1 || true)"
  iface4="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"${route4}")"
  gateway4="$(awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}' <<<"${route4}")"
  source4="$(awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' <<<"${route4}")"

  cidr4=""
  if [[ -n "${iface4}" ]]; then
    if [[ -n "${source4}" ]]; then
      cidr4="$(
        ip -o -4 addr show dev "${iface4}" scope global 2>/dev/null |
          awk -v source="${source4}" '{split($4, address, "/"); if (address[1] == source) {print $4; exit}}'
      )"
    fi
    if [[ -z "${cidr4}" ]]; then
      cidr4="$(ip -o -4 addr show dev "${iface4}" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
    fi
  fi

  prefix4=""
  netmask4=""
  if [[ -n "${cidr4}" ]]; then
    source4="${cidr4%/*}"
    prefix4="${cidr4#*/}"
    netmask4="$(prefix_to_netmask "${prefix4}")"
  fi

  mac4="N/A"
  if [[ -n "${iface4}" && -r "/sys/class/net/${iface4}/address" ]]; then
    mac4="$(<"/sys/class/net/${iface4}/address")"
  fi

  hostname_value="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)"
  route6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -n 1 || true)"
  source6="$(awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' <<<"${route6}")"
  dns_output="$(get_real_dns_servers || true)"

  {
    printf '%s\n' '============================================================'
    printf '%s\n' ' Debian 安装器手动网络配置参考'
    printf '%s\n' '============================================================'
    printf '\n'
    printf '主机名：%s\n' "${hostname_value:-N/A}"
    printf '网卡名称：%s\n' "${iface4:-N/A}"
    printf 'MAC 地址：%s\n' "${mac4}"
    printf 'IPv4 地址：%s\n' "${source4:-N/A}"
    printf 'IPv4 CIDR：%s\n' "${cidr4:-N/A}"
    printf '前缀长度：%s\n' "${prefix4:-N/A}"
    printf '子网掩码：%s\n' "${netmask4:-N/A}"
    printf '默认网关：%s\n' "${gateway4:-N/A}"
    printf 'IPv6 源地址：%s\n' "${source6:-N/A}"
    printf 'DNS 服务器：\n'
    if [[ -n "${dns_output}" ]]; then
      sed 's/^/  - /' <<<"${dns_output}"
    else
      printf '%s\n' '  - N/A'
    fi
    printf '\n'
    printf '%s\n' '------------------------------------------------------------'
    printf '%s\n' ' 原始网络信息'
    printf '%s\n' '------------------------------------------------------------'
    printf '\n[IPv4 地址]\n'
    ip -4 -br addr show || true
    printf '\n[IPv6 地址]\n'
    ip -6 -br addr show || true
    printf '\n[IPv4 路由]\n'
    ip -4 route show table all || true
    printf '\n[IPv6 路由]\n'
    ip -6 route show table all || true
    printf '\n[策略路由规则]\n'
    ip rule show || true
    printf '\n[DNS 配置]\n'
    get_real_dns_servers || true
    printf '\n%s\n' '注意：VPS 的 /32、点对点或网关不在子网内等特殊网络配置，'
    printf '%s\n' '可能需要在安装器中按服务商文档配置，而不能只依赖传统子网掩码。'
  } > "${NETWORK_INFO_FILE}"

  chown root:root "${NETWORK_INFO_FILE}"
  chmod 0600 "${NETWORK_INFO_FILE}"
  cat "${NETWORK_INFO_FILE}"
}

show_payload_summary() {
  local linux_hash initrd_hash

  linux_hash="$(sha256sum "${WORKDIR}/linux" | awk '{print $1}')"
  initrd_hash="$(sha256sum "${WORKDIR}/initrd.gz" | awk '{print $1}')"

  cat <<EOF

============================================================
重启前核对
============================================================
目标版本：Debian 13 (${RELEASE}) ${ARCH}
GRUB 菜单：${MENU_TITLE}
安装器目录：${WORKDIR}
网络信息：${NETWORK_INFO_FILE}
linux SHA256：${linux_hash}
initrd.gz SHA256：${initrd_hash}
GRUB 文件系统：${GRUB_FS}
GRUB 文件系统 UUID：${BOOT_UUID}
GRUB 中的安装器路径：${GRUB_WORKDIR}
内核参数：${KERNEL_CMDLINE}

必须确认：
  1. 已备份所有重要数据；安装过程会清除或覆盖磁盘数据。
  2. 已打开并测试 VPS 服务商的 VNC/KVM/noVNC/串口控制台。
  3. 已把 ${NETWORK_INFO_FILE} 的内容保存到本地。
  4. 知道如何从服务商控制台修复启动失败或重装失败。
============================================================
EOF
}

confirm_arm_next_boot() {
  local answer

  if (( ASSUME_YES == 1 )); then
    warn "ASSUME_YES=1：已跳过人工确认。"
    return 0
  fi

  [[ -t 0 ]] || die "当前不是交互式终端。请在 SSH 终端中直接运行脚本，或明确设置 ASSUME_YES=1。"

  printf '\n输入大写 REINSTALL 以设置下一次启动进入 Debian 安装器：'
  IFS= read -r answer
  [[ "${answer}" == "REINSTALL" ]] || die "操作已取消，未设置下一次启动项。"
}

arm_next_boot() {
  local actual_next

  log "设置下一次启动进入 Debian netboot 安装器..."
  grub-reboot "${MENU_ID}"
  NEXT_ENTRY_ARMED=1

  actual_next="$(
    grub-editenv "${GRUBENV}" list |
      sed -n 's/^next_entry=//p' |
      head -n 1
  )"

  if [[ "${actual_next}" != "${MENU_ID}" ]]; then
    grub-editenv "${GRUBENV}" unset next_entry >/dev/null 2>&1 || true
    NEXT_ENTRY_ARMED=0
    die "无法确认 GRUB next_entry 已正确写入。"
  fi

  sync
}

print_final_summary() {
  cat <<EOF

[完成] Debian 安装器已准备并通过本机可执行的校验：
  - Debian InRelease 签名有效
  - SHA256SUMS 与 InRelease 一致
  - linux 与 initrd.gz 的 SHA256 有效
  - initrd.gz 压缩流有效
  - update-grub 成功
  - grub.cfg 语法检查成功
  - GRUB 菜单项和路径检查成功
  - next_entry=${MENU_ID}

脚本不会自动重启。确认服务商控制台仍可使用后，执行：

  systemctl reboot

下一次启动应进入 Debian 13 安装器。SSH 会断开，后续操作必须通过
VNC/KVM/noVNC/串口控制台完成。

若尚未重启并希望取消，请立即执行：

  grub-editenv '${GRUBENV}' unset next_entry
EOF
}

main() {
  require_root
  validate_switches
  check_host_os_and_arch
  install_required_packages
  require_commands_and_files
  check_grub_environment
  prepare_workdir

  download_metadata_files
  verify_inrelease
  verify_sha256sums_metadata
  download_payload_files
  verify_installer_payloads
  install_verified_payloads

  probe_grub_paths
  build_kernel_cmdline
  collect_network_info
  write_grub_script
  regenerate_and_verify_grub

  show_payload_summary
  confirm_arm_next_boot
  arm_next_boot
  print_final_summary

  GRUB_CHANGE_PENDING=0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
