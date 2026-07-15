#!/usr/bin/env bash
set -Eeuo pipefail

# 在现有 Debian 主机上准备 Debian 13 (trixie) amd64 netboot 安装器。
#
# 本脚本不会自动分区、安装或重启。它会：
#   1. 从 Debian 官方镜像下载 InRelease、SHA256SUMS、linux 和 initrd.gz；
#   2. 用 Debian archive keyring 验证完整签名链与文件哈希；
#   3. 创建独立 GRUB 菜单项；
#   4. 在 grubenv 可安全写入时设置一次性启动；否则显示 GRUB 菜单，
#      要求从 VPS 控制台手动选择安装器，避免重启循环。
#
# 支持的目标：Debian 13 (trixie)，amd64。
#
# 可选环境变量：
#   FORCE_IPV4=1          下载时强制 IPv4；设为 0 时由系统选择（默认：1）
#   ASSUME_YES=1          跳过最后的 REINSTALL 人工确认（默认：0）
#   BOOT_MODE=auto        auto、oneshot 或 manual（默认：auto）
#                         auto：安全时用一次性启动，否则自动改为手动选择
#                         oneshot：必须使用一次性启动；存储不安全时拒绝继续
#                         manual：始终从 GRUB 菜单手动选择，不写 next_entry
#   MANUAL_TIMEOUT=30     manual 模式显示 GRUB 菜单的秒数（5～300）
#   INSTALLER_ARGS='...'  追加 Debian Installer 内核参数
#
# 旧版的 ALLOW_UNSAFE_GRUBENV 不再生效。强行在 Btrfs、LVM、MD RAID、ZFS
# 等布局上使用 grub-reboot，可能使安装器成为持续默认项并造成重启循环。

export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly RELEASE="trixie"
readonly ARCH="amd64"
readonly MIRROR="https://deb.debian.org/debian"
readonly DIST_BASE="${MIRROR}/dists/${RELEASE}"
readonly IMG_BASE="${DIST_BASE}/main/installer-${ARCH}/current/images"
readonly NETBOOT_BASE="${IMG_BASE}/netboot/debian-installer/${ARCH}"

readonly WORKROOT="/boot/debian-netboot"
readonly GRUB_SCRIPT="/etc/grub.d/41_debian_netboot_reinstall"
readonly GRUB_CFG="/boot/grub/grub.cfg"
readonly GRUBENV="/boot/grub/grubenv"
readonly NETWORK_INFO_FILE="/root/debian-reinstall-network.txt"
readonly BACKUP_DIR="/root/debian-reinstall-backups"
readonly LOCK_FILE="/run/debian-netboot-reinstall.lock"

readonly MENU_ID="debian-netboot-${RELEASE}-${ARCH}"
readonly MENU_TITLE="Debian 13 (trixie) netboot installer (amd64)"
readonly KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
readonly MIN_FREE_KIB=131072

FORCE_IPV4="${FORCE_IPV4:-1}"
ASSUME_YES="${ASSUME_YES:-0}"
BOOT_MODE="${BOOT_MODE:-auto}"
MANUAL_TIMEOUT="${MANUAL_TIMEOUT:-30}"
INSTALLER_ARGS="${INSTALLER_ARGS:-}"

LOCK_FD=""
TMPDIR_PATH=""
PAYLOAD_STAGING=""
NETWORK_TMP_PATH=""

PAYLOAD_DIR=""
EXPECTED_LINUX_HASH=""
EXPECTED_INITRD_HASH=""

GRUB_SCRIPT_BACKUP=""
GRUB_CFG_BACKUP=""
GRUB_SCRIPT_EXISTED=0
GRUB_CHANGE_PENDING=0
NEXT_ENTRY_ARMED=0

GRUBENV_SAFE=0
GRUBENV_FS=""
GRUBENV_ABSTRACTIONS=""
EFFECTIVE_BOOT_MODE=""

BOOT_MOUNT=""
BOOT_SOURCE=""
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

usage() {
  cat <<'EOF'
用法：
  bash debian-netboot-reinstall-optimized.sh

可选环境变量：
  FORCE_IPV4=0|1
  ASSUME_YES=0|1
  BOOT_MODE=auto|oneshot|manual
  MANUAL_TIMEOUT=5..300
  INSTALLER_ARGS='参数1 参数2=值'

示例：
  BOOT_MODE=auto bash debian-netboot-reinstall-optimized.sh
  BOOT_MODE=manual MANUAL_TIMEOUT=45 bash debian-netboot-reinstall-optimized.sh
EOF
}

on_err() {
  local rc=$?
  local line=${BASH_LINENO[0]:-${LINENO}}
  printf '[错误] 脚本在第 %s 行失败，退出码：%s\n' "${line}" "${rc}" >&2
  return 0
}

restore_grub_cfg_backup() {
  local tmp=""

  [[ -n "${GRUB_CFG_BACKUP}" && -f "${GRUB_CFG_BACKUP}" ]] || return 1

  tmp="$(mktemp "/boot/grub/.grub.cfg.restore.XXXXXXXX")" || return 1
  if ! cp -a -- "${GRUB_CFG_BACKUP}" "${tmp}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  if ! mv -fT -- "${tmp}" "${GRUB_CFG}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  sync
}

rollback_grub_change() {
  local tmp=""

  (( GRUB_CHANGE_PENDING == 1 )) || return 0
  warn "正在回滚本次 GRUB 修改..."

  if (( GRUB_SCRIPT_EXISTED == 1 )); then
    if [[ -z "${GRUB_SCRIPT_BACKUP}" || ! -f "${GRUB_SCRIPT_BACKUP}" ]]; then
      warn "找不到原 GRUB 脚本备份，无法自动恢复 ${GRUB_SCRIPT}。"
      return 1
    fi

    tmp="$(mktemp "/etc/grub.d/.debian-netboot.restore.XXXXXXXX")" || return 1
    if ! cp -a -- "${GRUB_SCRIPT_BACKUP}" "${tmp}"; then
      rm -f -- "${tmp}"
      return 1
    fi
    if ! mv -fT -- "${tmp}" "${GRUB_SCRIPT}"; then
      rm -f -- "${tmp}"
      return 1
    fi
  else
    rm -f -- "${GRUB_SCRIPT}" || return 1
  fi

  if update-grub >/dev/null 2>&1; then
    GRUB_CHANGE_PENDING=0
    return 0
  fi

  warn "回滚 GRUB 菜单脚本后 update-grub 失败，尝试恢复修改前的 grub.cfg。"
  if restore_grub_cfg_backup; then
    GRUB_CHANGE_PENDING=0
    warn "已恢复修改前的 grub.cfg；请在方便时检查 update-grub 失败原因。"
    return 0
  fi

  warn "无法恢复 ${GRUB_CFG}，请立即通过控制台检查 GRUB 配置。"
  return 1
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

  if [[ -n "${NETWORK_TMP_PATH}" && -e "${NETWORK_TMP_PATH}" ]]; then
    rm -f -- "${NETWORK_TMP_PATH}"
  fi
  if [[ -n "${PAYLOAD_STAGING}" && -d "${PAYLOAD_STAGING}" ]]; then
    rm -rf -- "${PAYLOAD_STAGING}"
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

parse_arguments() {
  if (( $# == 0 )); then
    return 0
  fi
  if (( $# == 1 )) && [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
    exit 0
  fi
  die "不支持位置参数。使用 --help 查看用法；其余选项请通过环境变量设置。"
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请以 root 身份运行此脚本。"
}

validate_switches() {
  local safe_args_re='^[A-Za-z0-9_./,:=@%+-]+([[:space:]][A-Za-z0-9_./,:=@%+-]+)*$'

  [[ "${FORCE_IPV4}" =~ ^[01]$ ]] || die "FORCE_IPV4 只能是 0 或 1。"
  [[ "${ASSUME_YES}" =~ ^[01]$ ]] || die "ASSUME_YES 只能是 0 或 1。"
  [[ "${BOOT_MODE}" =~ ^(auto|oneshot|manual)$ ]] || \
    die "BOOT_MODE 只能是 auto、oneshot 或 manual。"
  [[ "${MANUAL_TIMEOUT}" =~ ^[0-9]+$ ]] || \
    die "MANUAL_TIMEOUT 必须是整数。"
  (( MANUAL_TIMEOUT >= 5 && MANUAL_TIMEOUT <= 300 )) || \
    die "MANUAL_TIMEOUT 必须在 5～300 秒之间。"

  if [[ -n "${INSTALLER_ARGS}" ]]; then
    [[ "${INSTALLER_ARGS}" != *$'\n'* && "${INSTALLER_ARGS}" != *$'\r'* ]] || \
      die "INSTALLER_ARGS 不能包含换行符。"
    [[ "${INSTALLER_ARGS}" =~ ${safe_args_re} ]] || \
      die "INSTALLER_ARGS 含有不安全字符，或首尾/相邻空白不符合要求。"
  fi

  if [[ -n "${ALLOW_UNSAFE_GRUBENV+x}" ]]; then
    warn "ALLOW_UNSAFE_GRUBENV 已停用并会被忽略；不安全布局将使用 manual 模式。"
  fi
}

check_host_os_and_arch() {
  [[ -r /etc/os-release ]] || die "找不到 /etc/os-release。"

  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || \
    die "当前系统不是 Debian；为避免破坏引导配置，脚本拒绝继续。"

  command -v dpkg >/dev/null 2>&1 || die "缺少 dpkg。"
  command -v apt-get >/dev/null 2>&1 || die "缺少 apt-get。"
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || \
    die "当前系统不是 amd64，脚本仅支持 amd64。"
  [[ "$(uname -m)" == "x86_64" ]] || \
    die "当前内核架构不是 x86_64，脚本拒绝继续。"

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt --quiet --chroot; then
      die "检测到 chroot 环境；不能在 chroot 中修改实际启动配置。"
    fi
    if systemd-detect-virt --quiet --container; then
      die "检测到容器环境；容器通常不控制宿主机 GRUB，脚本拒绝继续。"
    fi
  fi

  [[ -r /proc/cmdline ]] || die "无法读取 /proc/cmdline。"
  [[ -d /etc/grub.d && -d /boot/grub ]] || \
    die "当前系统未发现标准 Debian GRUB 配置目录，脚本拒绝继续。"
}

acquire_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    log "安装并发锁所需的 util-linux..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends util-linux
  fi

  exec {LOCK_FD}>"${LOCK_FILE}"
  flock -n "${LOCK_FD}" || die "已有另一个本脚本实例正在运行。"
}

install_required_packages() {
  log "更新 APT 索引并安装/确认必要软件..."

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
    apt-get awk basename cat chmod chown cp date df file findmnt flock gpgv
    grep grub-editenv grub-mkrelpath grub-probe grub-reboot grub-script-check
    gzip head hostname install ip mktemp mv rm sed sha256sum stat sync tail
    uname update-grub wget
  )

  for cmd in "${commands[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "缺少命令：${cmd}"
  done

  [[ -r "${KEYRING}" ]] || die "缺少 Debian archive keyring：${KEYRING}"
  [[ -d /etc/grub.d ]] || die "找不到 /etc/grub.d；系统似乎未使用 Debian GRUB。"
  [[ -d /boot/grub ]] || die "找不到 /boot/grub；系统似乎未安装 GRUB。"
  [[ ! -L "${GRUB_SCRIPT}" ]] || die "${GRUB_SCRIPT} 是符号链接，拒绝覆盖。"
  [[ ! -L "${WORKROOT}" ]] || die "${WORKROOT} 是符号链接，拒绝使用。"
  [[ ! -L "${BACKUP_DIR}" ]] || die "${BACKUP_DIR} 是符号链接，拒绝使用。"
}

check_boot_mounts() {
  local fstab_targets

  # 如果 fstab 声明了独立 /boot，它必须已实际挂载。否则可能把安装器和
  # grub.cfg 写进根文件系统中被遮蔽的 /boot 目录，重启时完全不会生效。
  fstab_targets="$(findmnt --fstab --noheadings --output TARGET 2>/dev/null || true)"
  if grep -Fxq '/boot' <<<"${fstab_targets}"; then
    findmnt --noheadings --mountpoint /boot >/dev/null || \
      die "fstab 声明了独立 /boot，但它当前未挂载。请先正确挂载 /boot。"
  fi
}

check_grub_environment() {
  local existing_next=""
  local env_listing=""

  GRUBENV_ABSTRACTIONS="$(grub-probe --target=abstraction /boot/grub 2>/dev/null)" || \
    die "无法探测 /boot/grub 的 GRUB 抽象层。"
  GRUBENV_FS="$(grub-probe --target=fs /boot/grub 2>/dev/null)" || \
    die "无法探测 /boot/grub 的文件系统。"
  [[ -n "${GRUBENV_FS}" ]] || die "grub-probe 未返回 /boot/grub 的文件系统类型。"

  GRUBENV_SAFE=1
  if [[ -n "${GRUBENV_ABSTRACTIONS}" || \
        "${GRUBENV_FS}" == "btrfs" || \
        "${GRUBENV_FS}" == "zfs" ]]; then
    GRUBENV_SAFE=0
  fi

  case "${BOOT_MODE}" in
    auto)
      if (( GRUBENV_SAFE == 1 )); then
        EFFECTIVE_BOOT_MODE="oneshot"
      else
        EFFECTIVE_BOOT_MODE="manual"
        warn "grubenv 位于不适合可靠一次性写入的存储：abstraction='${GRUBENV_ABSTRACTIONS:-none}', fs='${GRUBENV_FS}'."
        warn "已自动切换到 manual：不会写入 next_entry；重启后需从控制台选择安装器。"
      fi
      ;;
    oneshot)
      (( GRUBENV_SAFE == 1 )) || \
        die "BOOT_MODE=oneshot 不可用于当前 grubenv 存储（abstraction='${GRUBENV_ABSTRACTIONS:-none}', fs='${GRUBENV_FS}'）。请改用 BOOT_MODE=manual 或默认 auto。"
      EFFECTIVE_BOOT_MODE="oneshot"
      ;;
    manual)
      EFFECTIVE_BOOT_MODE="manual"
      ;;
  esac

  if [[ -e "${GRUBENV}" ]]; then
    [[ -f "${GRUBENV}" ]] || die "${GRUBENV} 不是普通文件。"
    env_listing="$(grub-editenv "${GRUBENV}" list)" || \
      die "无法读取现有 GRUB environment block。"
    existing_next="$(sed -n 's/^next_entry=//p' <<<"${env_listing}" | head -n 1)"
    [[ -z "${existing_next}" ]] || \
      die "GRUB 已存在一次性启动项 next_entry=${existing_next}。请先确认并清除：grub-editenv '${GRUBENV}' unset next_entry"
  elif [[ "${EFFECTIVE_BOOT_MODE}" == "oneshot" ]]; then
    log "创建 GRUB environment block..."
    grub-editenv "${GRUBENV}" create
    [[ -f "${GRUBENV}" ]] || die "无法创建 ${GRUBENV}。"
    grub-editenv "${GRUBENV}" list >/dev/null
  fi
}

prepare_workroot() {
  local available_kib

  install -d -o root -g root -m 0755 -- "${WORKROOT}"
  [[ -d "${WORKROOT}" && -w "${WORKROOT}" ]] || die "${WORKROOT} 不可写。"

  available_kib="$(df -Pk "${WORKROOT}" | awk 'NR==2 {print $4}')"
  [[ "${available_kib}" =~ ^[0-9]+$ ]] || die "无法读取 ${WORKROOT} 的可用空间。"
  (( available_kib >= MIN_FREE_KIB )) || \
    die "${WORKROOT} 可用空间不足：${available_kib} KiB；至少需要 ${MIN_FREE_KIB} KiB。"

  TMPDIR_PATH="$(mktemp -d "${WORKROOT}/.download.XXXXXXXX")"
  chmod 0700 "${TMPDIR_PATH}"
}

download_one() {
  local url=$1
  local output=$2
  local -a args=(
    --https-only
    --secure-protocol=TLSv1_2
    --no-hsts
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

download_and_verify_release() {
  local codename_count

  log "下载并验证 Debian ${RELEASE} InRelease..."
  download_one "${DIST_BASE}/InRelease" "${TMPDIR_PATH}/InRelease"

  gpgv --keyring "${KEYRING}" \
    --output "${TMPDIR_PATH}/Release" \
    "${TMPDIR_PATH}/InRelease"
  [[ -s "${TMPDIR_PATH}/Release" ]] || die "无法从 InRelease 提取已签名的 Release 内容。"

  codename_count="$(grep -Fxc "Codename: ${RELEASE}" "${TMPDIR_PATH}/Release" || true)"
  [[ "${codename_count}" == "1" ]] || \
    die "已签名 Release 中的 Codename 不是唯一的 ${RELEASE}。"

  awk -v arch="${ARCH}" '
    /^Architectures:[[:space:]]/ {
      for (i=2; i<=NF; i++) {
        if ($i == arch) found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${TMPDIR_PATH}/Release" || \
    die "已签名 Release 未声明支持 ${ARCH}。"
}

download_and_verify_sha256sums() {
  local target expected_hash expected_size actual_size metadata_line
  target="main/installer-${ARCH}/current/images/SHA256SUMS"

  log "下载并用已签名的 Release 验证 SHA256SUMS..."
  download_one "${IMG_BASE}/SHA256SUMS" "${TMPDIR_PATH}/SHA256SUMS"

  metadata_line="$(
    awk -v target="${target}" '
      $1 == "SHA256:" { in_sha256=1; next }
      in_sha256 && /^[A-Za-z][A-Za-z0-9-]*:/ { in_sha256=0 }
      in_sha256 && length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && $3 == target {
        print $1, $2
        found++
      }
      END { if (found != 1) exit 1 }
    ' "${TMPDIR_PATH}/Release"
  )" || die "无法从已签名 Release 唯一定位 ${target}。"

  read -r expected_hash expected_size <<<"${metadata_line}"
  [[ "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] || die "Release 中的 SHA256SUMS 哈希无效。"
  [[ "${expected_size}" =~ ^[0-9]+$ ]] || die "Release 中的 SHA256SUMS 大小无效。"

  actual_size="$(stat -c '%s' "${TMPDIR_PATH}/SHA256SUMS")"
  [[ "${actual_size}" == "${expected_size}" ]] || \
    die "SHA256SUMS 文件大小不匹配：期望 ${expected_size}，实际 ${actual_size}。"

  printf '%s  %s\n' "${expected_hash}" "${TMPDIR_PATH}/SHA256SUMS" |
    sha256sum --check --strict -
}

extract_payload_checksums() {
  local payload_metadata checks_file
  checks_file="${TMPDIR_PATH}/installer-checksums"

  payload_metadata="$(
    awk -v arch="${ARCH}" '
      {
        hash=$1
        name=$2
        sub(/^\*/, "", name)
        sub(/^\.\//, "", name)
        prefix="netboot/debian-installer/" arch "/"

        if (name == prefix "linux") {
          print "linux", hash
          linux_count++
        } else if (name == prefix "initrd.gz") {
          print "initrd.gz", hash
          initrd_count++
        }
      }
      END {
        if (linux_count != 1 || initrd_count != 1) exit 1
      }
    ' "${TMPDIR_PATH}/SHA256SUMS"
  )" || die "SHA256SUMS 中未唯一找到 linux 和 initrd.gz。"

  EXPECTED_LINUX_HASH="$(awk '$1 == "linux" {print $2}' <<<"${payload_metadata}")"
  EXPECTED_INITRD_HASH="$(awk '$1 == "initrd.gz" {print $2}' <<<"${payload_metadata}")"

  [[ "${EXPECTED_LINUX_HASH}" =~ ^[0-9a-f]{64}$ ]] || die "linux 的 SHA256 格式无效。"
  [[ "${EXPECTED_INITRD_HASH}" =~ ^[0-9a-f]{64}$ ]] || die "initrd.gz 的 SHA256 格式无效。"

  printf '%s  linux\n%s  initrd.gz\n' \
    "${EXPECTED_LINUX_HASH}" "${EXPECTED_INITRD_HASH}" > "${checks_file}"
}

download_and_verify_payloads() {
  log "下载 Debian ${RELEASE} 官方 netboot 内核与 initrd..."
  download_one "${NETBOOT_BASE}/linux" "${TMPDIR_PATH}/linux"
  download_one "${NETBOOT_BASE}/initrd.gz" "${TMPDIR_PATH}/initrd.gz"

  log "验证 linux 与 initrd.gz..."
  (
    cd "${TMPDIR_PATH}"
    sha256sum --check --strict installer-checksums
  )

  gzip -t "${TMPDIR_PATH}/initrd.gz"
  file "${TMPDIR_PATH}/linux" | grep -Eqi 'Linux kernel|Linux/x86 Kernel' || \
    die "下载的 linux 文件未被识别为 Linux x86 内核。"
  file "${TMPDIR_PATH}/initrd.gz" | grep -qi 'gzip compressed data' || \
    die "下载的 initrd.gz 未被识别为 gzip 数据。"
}

verify_existing_generation() {
  local directory=$1

  [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
  [[ -f "${directory}/linux" && -f "${directory}/initrd.gz" ]] || return 1

  (
    cd "${directory}"
    printf '%s  linux\n%s  initrd.gz\n' \
      "${EXPECTED_LINUX_HASH}" "${EXPECTED_INITRD_HASH}" |
      sha256sum --check --strict - >/dev/null
  ) || return 1
  gzip -t "${directory}/initrd.gz" >/dev/null 2>&1
}

install_verified_payloads() {
  local generation_name
  generation_name="payload-${EXPECTED_LINUX_HASH:0:16}-${EXPECTED_INITRD_HASH:0:16}"
  PAYLOAD_DIR="${WORKROOT}/${generation_name}"

  if [[ -e "${PAYLOAD_DIR}" ]]; then
    verify_existing_generation "${PAYLOAD_DIR}" || \
      die "已存在的版本目录 ${PAYLOAD_DIR} 不完整或校验失败；为避免误删数据，请人工检查后重试。"
    log "复用已验证的安装器版本目录：${PAYLOAD_DIR}"
    return 0
  fi

  log "将已验证文件安装到新的版本目录..."
  PAYLOAD_STAGING="$(mktemp -d "${WORKROOT}/.payload.XXXXXXXX")"
  chmod 0755 "${PAYLOAD_STAGING}"

  mv -- "${TMPDIR_PATH}/linux" "${PAYLOAD_STAGING}/linux"
  mv -- "${TMPDIR_PATH}/initrd.gz" "${PAYLOAD_STAGING}/initrd.gz"
  mv -- "${TMPDIR_PATH}/InRelease" "${PAYLOAD_STAGING}/InRelease"
  mv -- "${TMPDIR_PATH}/Release" "${PAYLOAD_STAGING}/Release"
  mv -- "${TMPDIR_PATH}/SHA256SUMS" "${PAYLOAD_STAGING}/SHA256SUMS"

  chown root:root \
    "${PAYLOAD_STAGING}/linux" \
    "${PAYLOAD_STAGING}/initrd.gz" \
    "${PAYLOAD_STAGING}/InRelease" \
    "${PAYLOAD_STAGING}/Release" \
    "${PAYLOAD_STAGING}/SHA256SUMS"
  chmod 0644 \
    "${PAYLOAD_STAGING}/linux" \
    "${PAYLOAD_STAGING}/initrd.gz" \
    "${PAYLOAD_STAGING}/InRelease" \
    "${PAYLOAD_STAGING}/Release" \
    "${PAYLOAD_STAGING}/SHA256SUMS"

  sync
  mv -T -- "${PAYLOAD_STAGING}" "${PAYLOAD_DIR}"
  PAYLOAD_STAGING=""
  sync
}

probe_grub_paths() {
  local module

  log "探测 GRUB 访问 ${PAYLOAD_DIR} 所需信息..."

  BOOT_MOUNT="$(findmnt -n -o TARGET -T "${PAYLOAD_DIR}")"
  BOOT_SOURCE="$(findmnt -n -o SOURCE -T "${PAYLOAD_DIR}")"
  [[ -n "${BOOT_MOUNT}" ]] || die "无法确定 ${PAYLOAD_DIR} 所在挂载点。"

  GRUB_WORKDIR="$(grub-mkrelpath "${PAYLOAD_DIR}")"
  [[ "${GRUB_WORKDIR}" == /* ]] || die "生成的 GRUB 路径无效：${GRUB_WORKDIR}"
  [[ "${GRUB_WORKDIR}" =~ ^/[A-Za-z0-9._/@+,:=-]+$ ]] || \
    die "GRUB 路径包含脚本无法安全转义的字符：${GRUB_WORKDIR}"

  BOOT_UUID="$(grub-probe --target=fs_uuid "${PAYLOAD_DIR}")"
  GRUB_FS="$(grub-probe --target=fs "${PAYLOAD_DIR}")"
  GRUB_PARTMAPS="$(grub-probe --target=partmap "${PAYLOAD_DIR}" 2>/dev/null || true)"
  GRUB_ABSTRACTIONS="$(grub-probe --target=abstraction "${PAYLOAD_DIR}" 2>/dev/null || true)"

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

  # 保留现有串口 console= 参数，确保 VPS 串口控制台继续显示安装器输出。
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

  NETWORK_TMP_PATH="$(mktemp "/root/.debian-reinstall-network.XXXXXXXX")"
  {
    printf '%s\n' '============================================================'
    printf '%s\n' ' Debian 安装器手动网络配置参考'
    printf '%s\n' '============================================================'
    printf '\n'
    printf '主机名：%s\n' "${hostname_value:-N/A}"
    printf '推断的出口网卡：%s\n' "${iface4:-N/A}"
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
    printf '\n%s\n' '注意：上面的首组选项由当前到公网的路由推断。VPN、隧道、策略路由、'
    printf '%s\n' 'VPS 的 /32、点对点或网关不在子网内等配置，必须以服务商文档为准。'
  } > "${NETWORK_TMP_PATH}"

  chown root:root "${NETWORK_TMP_PATH}"
  chmod 0600 "${NETWORK_TMP_PATH}"
  mv -fT -- "${NETWORK_TMP_PATH}" "${NETWORK_INFO_FILE}"
  NETWORK_TMP_PATH=""
  cat "${NETWORK_INFO_FILE}"
}

backup_existing_grub_files() {
  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

  install -d -o root -g root -m 0700 -- "${BACKUP_DIR}"

  if [[ -e "${GRUB_SCRIPT}" ]]; then
    [[ -f "${GRUB_SCRIPT}" ]] || die "${GRUB_SCRIPT} 不是普通文件。"
    GRUB_SCRIPT_EXISTED=1
    GRUB_SCRIPT_BACKUP="$(mktemp "${BACKUP_DIR}/$(basename "${GRUB_SCRIPT}").${timestamp}.XXXXXXXX.bak")"
    cp -a -- "${GRUB_SCRIPT}" "${GRUB_SCRIPT_BACKUP}"
  fi

  if [[ -e "${GRUB_CFG}" ]]; then
    [[ -f "${GRUB_CFG}" ]] || die "${GRUB_CFG} 不是普通文件。"
    GRUB_CFG_BACKUP="$(mktemp "${BACKUP_DIR}/grub.cfg.${timestamp}.XXXXXXXX.bak")"
    cp -a -- "${GRUB_CFG}" "${GRUB_CFG_BACKUP}"
  fi
}

write_grub_script() {
  local tmp module
  local -a module_lines=()
  local -A seen_modules=()

  log "写入独立 GRUB 菜单脚本 ${GRUB_SCRIPT}..."
  backup_existing_grub_files

  for module in ${GRUB_PARTMAPS}; do
    if [[ -z "${seen_modules[part_${module}]+x}" ]]; then
      module_lines+=( "    insmod part_${module}" )
      seen_modules["part_${module}"]=1
    fi
  done
  for module in ${GRUB_ABSTRACTIONS}; do
    if [[ -z "${seen_modules[${module}]+x}" ]]; then
      module_lines+=( "    insmod ${module}" )
      seen_modules["${module}"]=1
    fi
  done
  for module in ${GRUB_FS}; do
    if [[ -z "${seen_modules[${module}]+x}" ]]; then
      module_lines+=( "    insmod ${module}" )
      seen_modules["${module}"]=1
    fi
  done

  tmp="$(mktemp "/etc/grub.d/.41_debian_netboot_reinstall.XXXXXXXX")"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'exec tail -n +3 "$0"'
    printf '%s\n' '# Generated by debian-netboot-reinstall-optimized.sh'
    if [[ "${EFFECTIVE_BOOT_MODE}" == "manual" ]]; then
      printf '%s\n' '# Keep the normal default, but make the menu visible for manual selection.'
      printf '%s\n' 'set timeout_style=menu'
      printf 'set timeout=%s\n' "${MANUAL_TIMEOUT}"
    fi
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
  GRUB_CHANGE_PENDING=1
  mv -fT -- "${tmp}" "${GRUB_SCRIPT}"
}

verify_oneshot_logic_in_grub_cfg() {
  grep -Eq '^[[:space:]]*load_env([[:space:]]|$)' "${GRUB_CFG}" || \
    die "grub.cfg 中找不到 load_env，无法保证 next_entry 会被读取。"
  grep -Eq '^[[:space:]]*save_env[[:space:]]+next_entry([[:space:]]|$)' "${GRUB_CFG}" || \
    die "grub.cfg 中找不到 save_env next_entry，无法保证一次性启动项会被清除。"
}

regenerate_and_verify_grub() {
  local menu_id_count

  log "重新生成并验证 GRUB 配置..."

  if ! update-grub; then
    die "update-grub 执行失败。"
  fi

  [[ -s "${GRUB_CFG}" ]] || die "生成后的 ${GRUB_CFG} 不存在或为空。"
  grub-script-check "${GRUB_CFG}"

  menu_id_count="$(grep -Fc -- "--id '${MENU_ID}'" "${GRUB_CFG}" || true)"
  [[ "${menu_id_count}" == "1" ]] || \
    die "生成后的 grub.cfg 中菜单 ID ${MENU_ID} 出现 ${menu_id_count} 次；必须恰好一次。"
  grep -Fq -- "linux ${GRUB_WORKDIR}/linux ${KERNEL_CMDLINE}" "${GRUB_CFG}" || \
    die "生成后的 grub.cfg 中找不到预期 linux 行。"
  grep -Fq -- "initrd ${GRUB_WORKDIR}/initrd.gz" "${GRUB_CFG}" || \
    die "生成后的 grub.cfg 中找不到预期 initrd 行。"

  if [[ "${EFFECTIVE_BOOT_MODE}" == "oneshot" ]]; then
    verify_oneshot_logic_in_grub_cfg
  else
    grep -Fq -- "set timeout_style=menu" "${GRUB_CFG}" || \
      die "manual 模式未能在 grub.cfg 中启用可见菜单。"
    grep -Fq -- "set timeout=${MANUAL_TIMEOUT}" "${GRUB_CFG}" || \
      die "manual 模式的 GRUB 菜单超时未正确写入。"
  fi
}

show_payload_summary() {
  local mode_text

  if [[ "${EFFECTIVE_BOOT_MODE}" == "oneshot" ]]; then
    mode_text="一次性自动启动（grub-reboot）"
  else
    mode_text="控制台手动选择（不写 next_entry，菜单显示 ${MANUAL_TIMEOUT} 秒）"
  fi

  cat <<EOF

============================================================
重启前核对
============================================================
目标版本：Debian 13 (${RELEASE}) ${ARCH}
GRUB 菜单：${MENU_TITLE}
启动方式：${mode_text}
安装器目录：${PAYLOAD_DIR}
网络信息：${NETWORK_INFO_FILE}
linux SHA256：${EXPECTED_LINUX_HASH}
initrd.gz SHA256：${EXPECTED_INITRD_HASH}
安装器所在挂载点：${BOOT_MOUNT}
安装器所在设备：${BOOT_SOURCE:-N/A}
GRUB 文件系统：${GRUB_FS}
GRUB 文件系统 UUID：${BOOT_UUID}
GRUB 中的安装器路径：${GRUB_WORKDIR}
grubenv 布局：abstraction='${GRUBENV_ABSTRACTIONS:-none}', fs='${GRUBENV_FS}'
内核参数：${KERNEL_CMDLINE}

必须确认：
  1. 已备份所有重要数据；安装过程会清除或覆盖磁盘数据。
  2. 已打开并实际测试 VPS 服务商的 VNC/KVM/noVNC/串口控制台。
  3. 已把 ${NETWORK_INFO_FILE} 的内容保存到本地。
  4. 知道如何从服务商控制台修复启动失败或重装失败。
============================================================
EOF
}

confirm_final_action() {
  local answer

  if (( ASSUME_YES == 1 )); then
    warn "ASSUME_YES=1：已跳过人工确认。"
    return 0
  fi

  [[ -t 0 ]] || die "当前不是交互式终端。请在 SSH 终端中直接运行，或明确设置 ASSUME_YES=1。"

  if [[ "${EFFECTIVE_BOOT_MODE}" == "oneshot" ]]; then
    printf '\n输入大写 REINSTALL 以设置下一次启动自动进入 Debian 安装器：'
  else
    printf '\n输入大写 REINSTALL 以保留安装器菜单项；重启后仍需在控制台手动选择：'
  fi
  IFS= read -r answer
  [[ "${answer}" == "REINSTALL" ]] || die "操作已取消；正在恢复修改前的 GRUB 配置。"
}

arm_next_boot_if_requested() {
  local actual_next

  [[ "${EFFECTIVE_BOOT_MODE}" == "oneshot" ]] || return 0

  log "设置下一次启动进入 Debian netboot 安装器..."
  NEXT_ENTRY_ARMED=1
  grub-reboot "${MENU_ID}"

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

print_removal_instructions() {
  if (( GRUB_SCRIPT_EXISTED == 1 )); then
    cat <<EOF
若要恢复运行本脚本之前的专用菜单脚本，请执行：

  cp -a '${GRUB_SCRIPT_BACKUP}' '${GRUB_SCRIPT}'
  update-grub
EOF
  else
    cat <<EOF
若要删除本脚本添加的安装器菜单项，请执行：

  rm -f '${GRUB_SCRIPT}'
  update-grub
EOF
  fi
}

print_final_summary() {
  cat <<EOF

[完成] Debian 安装器已准备并通过本机可执行的校验：
  - Debian InRelease 签名有效，发行版与架构匹配
  - SHA256SUMS 与已签名 Release 一致
  - linux 与 initrd.gz 的 SHA256 有效
  - initrd.gz 压缩流与内核文件类型检查通过
  - update-grub 与 grub.cfg 语法检查成功
  - GRUB 菜单项、安装器路径及启动模式检查成功

脚本不会自动重启。确认服务商控制台仍可使用后，执行：

  systemctl reboot
EOF

  if [[ "${EFFECTIVE_BOOT_MODE}" == "oneshot" ]]; then
    cat <<EOF

下一次启动应自动进入 Debian 13 安装器。SSH 会断开，后续操作必须通过
VNC/KVM/noVNC/串口控制台完成。

若尚未重启并希望取消一次性启动，请立即执行：

  grub-editenv '${GRUBENV}' unset next_entry
EOF
  else
    cat <<EOF

当前布局未使用 grub-reboot，也没有写入 next_entry。重启后 GRUB 菜单会显示
${MANUAL_TIMEOUT} 秒；请在服务商控制台选择：

  ${MENU_TITLE}

如果不选择，GRUB 仍启动原来的默认项，因此不会因安装器条目形成重启循环。
EOF
  fi

  printf '\n'
  print_removal_instructions
}

main() {
  parse_arguments "$@"
  require_root
  validate_switches
  check_host_os_and_arch
  acquire_lock
  install_required_packages
  require_commands_and_files
  check_boot_mounts
  check_grub_environment
  prepare_workroot

  download_and_verify_release
  download_and_verify_sha256sums
  extract_payload_checksums
  download_and_verify_payloads
  install_verified_payloads

  probe_grub_paths
  build_kernel_cmdline
  collect_network_info
  write_grub_script
  regenerate_and_verify_grub

  show_payload_summary
  confirm_final_action
  arm_next_boot_if_requested
  print_final_summary

  GRUB_CHANGE_PENDING=0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
