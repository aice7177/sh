#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ===== 可按需修改的默认值（也可通过环境变量覆盖） =====
# Debian 版本可选：12 / 13；也接受发行代号：bookworm / trixie
DEBIAN_RELEASE="${DEBIAN_RELEASE:-}"
DEBIAN_CODENAME="${DEBIAN_CODENAME:-}"
DEBIAN_VERSION=""
DEBIAN_ARCH="${DEBIAN_ARCH:-amd64}"
MIRROR_BASE="${MIRROR_BASE:-https://deb.debian.org/debian}"
NETBOOT_DIR="${NETBOOT_DIR:-/netboot}"
GRUB_SCRIPT="${GRUB_SCRIPT:-/etc/grub.d/09_reinstall_debian_netboot}"
MENU_TITLE="${MENU_TITLE:-}"

# 网络模式：auto-copy（复制当前IPv4为静态）、dhcp（安装器里走DHCP）、manual（手填静态）
NETWORK_MODE="${NETWORK_MODE:-}"

# SSH 认证模式：password / key-only / both
SSH_AUTH_MODE="${SSH_AUTH_MODE:-}"
SSH_PORT="${SSH_PORT:-}"

# root 密码：建议不要直接写到脚本里，留空时脚本会安全提示输入
ROOT_PASSWORD="${ROOT_PASSWORD:-}"

# 公钥来源：二选一；如果都为空且 SSH_AUTH_MODE 需要公钥，脚本会尝试读取 /root/.ssh/authorized_keys
PUBKEY_FILE="${PUBKEY_FILE:-}"
PUBKEY_TEXT="${PUBKEY_TEXT:-}"

# yes = 尝试设置下次启动只进入安装器，并立即重启；no = 只准备环境，不自动重启
AUTO_REBOOT="${AUTO_REBOOT:-no}"

# ======================================================

# ---------- 日志函数 ----------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m──── %s ────\033[0m\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

# ---------- 自动安装依赖 ----------
# 命令 → 包名映射
declare -A CMD_PKG_MAP=(
  [awk]=gawk
  [sed]=sed
  [grep]=grep
  [ip]=iproute2
  [findmnt]=util-linux
  [blkid]=util-linux
  [sha256sum]=coreutils
  [gpgv]=gpgv
  [grub-probe]=grub-common
  [cpio]=cpio
  [gzip]=gzip
  [base64]=coreutils
  [curl]=curl
  [openssl]=openssl
  [hostname]=hostname
  [find]=findutils
)

install_dependencies() {
  step "检查并安装依赖"

  local missing_pkgs=()
  local missing_cmds=()

  for cmd in "${!CMD_PKG_MAP[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      local pkg="${CMD_PKG_MAP[$cmd]}"
      missing_cmds+=("$cmd")
      # 去重：检查 pkg 是否已在 missing_pkgs 中
      local already=0
      if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        for p in "${missing_pkgs[@]}"; do
          [[ "$p" == "$pkg" ]] && already=1 && break
        done
      fi
      (( already )) || missing_pkgs+=("$pkg")
    fi
  done

  # debian-archive-keyring 不是命令而是文件，单独检查
  if ! find_debian_keyring >/dev/null 2>&1; then
    missing_pkgs+=("debian-archive-keyring")
  fi

  if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
    log "所有依赖已满足"
    return 0
  fi

  warn "缺少以下软件包: ${missing_pkgs[*]}"
  if [[ ${#missing_cmds[@]} -gt 0 ]]; then
    info "对应缺少的命令: ${missing_cmds[*]}"
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    die "本脚本仅支持 Debian/Ubuntu 系统（apt-get），请手动安装: ${missing_pkgs[*]}"
  fi

  log "正在更新包索引并安装依赖…"
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -qq
  run apt-get install -y -qq "${missing_pkgs[@]}"

  # 安装后再次验证
  for cmd in "${missing_cmds[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || die "安装后仍找不到命令: $cmd（包 ${CMD_PKG_MAP[$cmd]}）"
  done

  log "依赖安装完成"
}

cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

run()  { "$@"; }
trim() { awk '{$1=$1;print}' <<<"$*"; }

# ---------- 欢迎横幅 ----------
banner() {
  cat <<'BANNER'

  ╔══════════════════════════════════════════════════════════════╗
  ║         Debian Netboot 一键重装脚本  v2.0                   ║
  ║                                                              ║
  ║  本脚本将引导您完成以下操作：                               ║
  ║  1. 检测并配置网络（安装器使用的 IP/网关/DNS）              ║
  ║  2. 设置安装后 root 密码                                     ║
  ║  3. 配置 SSH 端口与登录策略                                  ║
  ║  4. 下载并校验 Debian 安装器文件（防篡改）                  ║
  ║  5. 将安装项写入 GRUB，您通过 VNC 手动完成后续安装          ║
  ║                                                              ║
  ║  ⚠  运行后需重启，请务必提前打开 VNC！                     ║
  ╚══════════════════════════════════════════════════════════════╝

BANNER
}

# ---------- Debian 版本选择 ----------
resolve_debian_release() {
  local release_input="${DEBIAN_RELEASE:-${DEBIAN_CODENAME:-}}"

  if [[ -z "$release_input" && -t 0 ]]; then
    step "选择 Debian 版本"
    echo "  1) Debian 12 (bookworm)  — 当前 stable，稳定成熟"
    echo "  2) Debian 13 (trixie)    — 较新，功能更多"
    echo ""
    read -r -p "请输入 1 或 2 [默认 1]: " _choice
    case "${_choice:-1}" in
      2) release_input="13" ;;
      *) release_input="12" ;;
    esac
  fi

  release_input="$(printf '%s' "${release_input:-12}" | tr '[:upper:]' '[:lower:]')"

  case "$release_input" in
    12|bookworm)
      DEBIAN_VERSION="12"
      DEBIAN_CODENAME="bookworm"
      ;;
    13|trixie|stable)
      DEBIAN_VERSION="13"
      DEBIAN_CODENAME="trixie"
      ;;
    "")
      DEBIAN_VERSION="12"
      DEBIAN_CODENAME="bookworm"
      ;;
    *)
      die "DEBIAN_RELEASE 仅支持 12 / 13 / bookworm / trixie"
      ;;
  esac

  if [[ -z "$MENU_TITLE" ]]; then
    MENU_TITLE="Netboot Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME}) Installer ${DEBIAN_ARCH}"
  fi
  log "已选择 Debian $DEBIAN_VERSION ($DEBIAN_CODENAME)"
}

# ---------- 子网掩码转换 ----------
prefix_to_netmask() {
  local p="${1:?}"
  local mask=""
  local i
  for ((i=0; i<4; i++)); do
    if (( p >= 8 )); then
      mask+="255"
      p=$((p-8))
    else
      local oct=0
      if (( p > 0 )); then
        oct=$((256 - 2**(8-p)))
      fi
      mask+="$oct"
      p=0
    fi
    [[ $i -lt 3 ]] && mask+=.
  done
  printf '%s\n' "$mask"
}

# ---------- 密码哈希 ----------
hash_password_sha512() {
  local pw="${1:?}"
  if command -v openssl >/dev/null 2>&1; then
    openssl passwd -6 "$pw"
    return 0
  fi
  if command -v mkpasswd >/dev/null 2>&1; then
    mkpasswd -m sha-512 "$pw"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$pw"
import secrets, subprocess, sys
pw = sys.argv[1]
salt = secrets.token_hex(8)
# 优先 crypt 模块（Python < 3.13），否则回退 openssl 子进程
try:
    import crypt as _c
    print(_c.crypt(pw, "$6$" + salt))
except (ImportError, ModuleNotFoundError):
    r = subprocess.run(["openssl", "passwd", "-6", "-salt", salt, pw],
                       capture_output=True, text=True)
    if r.returncode == 0:
        print(r.stdout.strip())
    else:
        sys.exit(1)
PY
    return 0
  fi
  die "无法生成 SHA-512 密码哈希，请安装 openssl / whois(mkpasswd) / python3"
}

# ---------- 下载函数（强制 HTTPS + TLS 1.2） ----------
download() {
  local url="${1:?}" out="${2:?}"
  if command -v curl >/dev/null 2>&1; then
    run curl -fsSL -4 --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    run wget -4 --https-only -q -O "$out" "$url" 2>/dev/null || \
    run wget -4 -q -O "$out" "$url"
  else
    die "缺少 curl 或 wget，请先安装: apt-get install -y curl"
  fi
}

# ---------- 权限检查 ----------
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 用户运行此脚本（sudo bash dd.sh）"
}

# ---------- 密码输入 ----------
read_secret_twice() {
  local p1 p2
  while true; do
    read -r -s -p "  请输入安装后 root 密码（不显示）: " p1; echo
    [[ -n "$p1" ]] || { warn "密码不能为空，请重新输入"; continue; }
    [[ ${#p1} -ge 8 ]] || { warn "密码至少需要 8 位，请重新输入"; continue; }
    read -r -s -p "  请再次输入确认密码: " p2; echo
    [[ "$p1" == "$p2" ]] || { warn "两次输入不一致，请重试"; continue; }
    ROOT_PASSWORD="$p1"
    log "密码已设置"
    break
  done
}

# ---------- 公钥收集 ----------
collect_pubkey() {
  case "$SSH_AUTH_MODE" in
    password)
      PUBKEY_TEXT=""
      return 0
      ;;
    key-only|both)
      ;;
    *)
      die "SSH_AUTH_MODE 仅支持 password / key-only / both"
      ;;
  esac

  if [[ -n "$PUBKEY_TEXT" ]]; then
    return 0
  fi

  if [[ -n "$PUBKEY_FILE" ]]; then
    [[ -f "$PUBKEY_FILE" ]] || die "找不到公钥文件: $PUBKEY_FILE"
    PUBKEY_TEXT="$(<"$PUBKEY_FILE")"
    log "已读取公钥文件: $PUBKEY_FILE"
    return 0
  fi

  if [[ -f /root/.ssh/authorized_keys ]]; then
    PUBKEY_TEXT="$(< /root/.ssh/authorized_keys)"
    log "已自动读取 /root/.ssh/authorized_keys 作为安装后 root 公钥"
    return 0
  fi

  if [[ -t 0 ]]; then
    echo ""
    info "未找到公钥文件。"
    info "请粘贴您的 SSH 公钥（以 ssh-ed25519 或 ssh-rsa 开头的一整行）。"
    info "若您还没有公钥，请按 Ctrl+C 退出，改用密码模式（SSH_AUTH_MODE=password）。"
    read -r -p "  粘贴公钥: " PUBKEY_TEXT
    [[ -n "$PUBKEY_TEXT" ]] || die "未提供公钥，请重新运行并选择 password 模式"
    return 0
  fi

  die "当前模式需要公钥，但未提供 PUBKEY_FILE / PUBKEY_TEXT，且 /root/.ssh/authorized_keys 不存在"
}

# ---------- 网络检测 ----------
detect_network() {
  DETECT_IFACE="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  DETECT_GATEWAY="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
  DETECT_CIDR=""
  DETECT_IP=""
  DETECT_PREFIX=""
  DETECT_NETMASK=""
  DETECT_DNS="$(awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd ' ' -)"
  DETECT_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
  DETECT_DOMAIN="$(hostname -d 2>/dev/null || true)"

  if [[ -n "$DETECT_IFACE" ]]; then
    DETECT_CIDR="$(ip -4 -o addr show dev "$DETECT_IFACE" scope global 2>/dev/null | awk '{print $4; exit}')"
  fi

  if [[ -n "$DETECT_CIDR" ]]; then
    DETECT_IP="${DETECT_CIDR%/*}"
    DETECT_PREFIX="${DETECT_CIDR#*/}"
    DETECT_NETMASK="$(prefix_to_netmask "$DETECT_PREFIX")"
  fi
}

show_detected_network() {
  step "当前网络信息检测结果"
  printf '  %-10s %s\n' "网卡:"    "${DETECT_IFACE:-<未识别>}"
  printf '  %-10s %s\n' "IPv4:"    "${DETECT_IP:-<未识别>}"
  printf '  %-10s %s\n' "子网掩码:" "${DETECT_NETMASK:-<未识别>}"
  printf '  %-10s %s\n' "网关:"    "${DETECT_GATEWAY:-<未识别>}"
  printf '  %-10s %s\n' "DNS:"     "${DETECT_DNS:-<未识别>}"
  printf '  %-10s %s\n' "主机名:"  "${DETECT_HOSTNAME:-debian}"
  printf '  %-10s %s\n' "域名:"    "${DETECT_DOMAIN:-localdomain}"
  echo ""
}

# ---------- 网络模式选择 ----------
choose_network() {
  # 若未通过环境变量指定，则在向导中交互选择
  if [[ -z "$NETWORK_MODE" && -t 0 ]]; then
    step "选择安装器网络配置方式"
    if [[ -n "${DETECT_IP:-}" && -n "${DETECT_NETMASK:-}" && -n "${DETECT_GATEWAY:-}" ]]; then
      echo "  1) 自动复制当前静态 IP（推荐：${DETECT_IP}/${DETECT_PREFIX} 网关${DETECT_GATEWAY}）"
      echo "  2) 使用 DHCP 自动获取（安装器从 DHCP 获取 IP）"
      echo "  3) 手动填写静态 IP"
      echo ""
      read -r -p "请选择 [默认 1]: " _nc
      case "${_nc:-1}" in
        2) NETWORK_MODE="dhcp" ;;
        3) NETWORK_MODE="manual" ;;
        *) NETWORK_MODE="auto-copy" ;;
      esac
    else
      warn "未能自动识别当前 IP，只能选择 DHCP 或手动填写"
      echo "  1) 使用 DHCP 自动获取"
      echo "  2) 手动填写静态 IP"
      echo ""
      read -r -p "请选择 [默认 1]: " _nc
      case "${_nc:-1}" in
        2) NETWORK_MODE="manual" ;;
        *) NETWORK_MODE="dhcp" ;;
      esac
    fi
  fi

  NETWORK_MODE="${NETWORK_MODE:-dhcp}"

  case "$NETWORK_MODE" in
    auto-copy)
      [[ -n "${DETECT_IP:-}" && -n "${DETECT_NETMASK:-}" && -n "${DETECT_GATEWAY:-}" ]] || \
        die "auto-copy 模式失败：未能完整识别当前 IPv4/掩码/网关，请改用 dhcp 或 manual"
      INSTALL_IP="$DETECT_IP"
      INSTALL_NETMASK="$DETECT_NETMASK"
      INSTALL_GATEWAY="$DETECT_GATEWAY"
      INSTALL_DNS="$(trim "${DETECT_DNS:-$DETECT_GATEWAY}")"
      INSTALL_HOSTNAME="${DETECT_HOSTNAME:-debian}"
      INSTALL_DOMAIN="${DETECT_DOMAIN:-localdomain}"
      log "网络模式: 自动复制当前 IP ($INSTALL_IP)"
      ;;
    dhcp)
      INSTALL_IP=""
      INSTALL_NETMASK=""
      INSTALL_GATEWAY=""
      INSTALL_DNS=""
      INSTALL_HOSTNAME="${DETECT_HOSTNAME:-debian}"
      INSTALL_DOMAIN="${DETECT_DOMAIN:-localdomain}"
      log "网络模式: DHCP（安装器自动获取）"
      ;;
    manual)
      if [[ ! -t 0 ]]; then
        die "manual 模式需要交互式终端"
      fi
      step "手动填写网络参数"
      read -r -p "  安装器使用的 IPv4 地址 [${DETECT_IP:-}]: " INSTALL_IP
      INSTALL_IP="${INSTALL_IP:-${DETECT_IP:-}}"
      read -r -p "  子网掩码 [${DETECT_NETMASK:-255.255.255.0}]: " INSTALL_NETMASK
      INSTALL_NETMASK="${INSTALL_NETMASK:-${DETECT_NETMASK:-255.255.255.0}}"
      read -r -p "  默认网关 [${DETECT_GATEWAY:-}]: " INSTALL_GATEWAY
      INSTALL_GATEWAY="${INSTALL_GATEWAY:-${DETECT_GATEWAY:-}}"
      read -r -p "  DNS 服务器 [${DETECT_DNS:-8.8.8.8}]: " INSTALL_DNS
      INSTALL_DNS="${INSTALL_DNS:-${DETECT_DNS:-8.8.8.8}}"
      read -r -p "  主机名 [${DETECT_HOSTNAME:-debian}]: " INSTALL_HOSTNAME
      INSTALL_HOSTNAME="${INSTALL_HOSTNAME:-${DETECT_HOSTNAME:-debian}}"
      read -r -p "  域名 [${DETECT_DOMAIN:-localdomain}]: " INSTALL_DOMAIN
      INSTALL_DOMAIN="${INSTALL_DOMAIN:-${DETECT_DOMAIN:-localdomain}}"
      [[ -n "$INSTALL_IP" && -n "$INSTALL_NETMASK" && -n "$INSTALL_GATEWAY" ]] || \
        die "IP / 掩码 / 网关不能为空"
      log "网络模式: 手动静态 IP ($INSTALL_IP)"
      ;;
    *)
      die "NETWORK_MODE 仅支持 auto-copy / dhcp / manual"
      ;;
  esac
}

# ---------- SSH 配置向导 ----------
wizard_ssh() {
  if [[ -n "$SSH_PORT" && -n "$SSH_AUTH_MODE" ]]; then
    return 0
  fi

  step "配置 SSH"

  # SSH 端口
  if [[ -z "$SSH_PORT" ]]; then
    echo "  建议修改 SSH 端口以提高安全性（默认 22 容易被扫描攻击）"
    read -r -p "  请输入安装后 SSH 端口 [默认 2222]: " _port
    SSH_PORT="${_port:-2222}"
  fi

  # SSH 登录方式
  if [[ -z "$SSH_AUTH_MODE" ]]; then
    echo ""
    echo "  SSH 登录方式："
    echo "  1) 仅密钥登录（最安全，推荐）"
    echo "  2) 密码 + 密钥均可"
    echo "  3) 仅密码登录"
    echo ""
    read -r -p "  请选择 [默认 1]: " _am
    case "${_am:-1}" in
      2) SSH_AUTH_MODE="both" ;;
      3) SSH_AUTH_MODE="password" ;;
      *) SSH_AUTH_MODE="key-only" ;;
    esac
  fi

  log "SSH 端口: $SSH_PORT  登录方式: $SSH_AUTH_MODE"
}

# ---------- 执行前确认摘要 ----------
confirm_proceed() {
  step "执行前确认 — 请仔细核对以下配置"
  echo ""
  printf '  %-22s %s\n' "Debian 版本:"      "$DEBIAN_VERSION ($DEBIAN_CODENAME)"
  printf '  %-22s %s\n' "架构:"             "$DEBIAN_ARCH"
  printf '  %-22s %s\n' "安装器镜像源:"    "$MIRROR_BASE"
  echo ""
  printf '  %-22s %s\n' "网络配置方式:"    "$NETWORK_MODE"
  if [[ "$NETWORK_MODE" != "dhcp" ]]; then
    printf '  %-22s %s\n' "安装器 IPv4:"    "$INSTALL_IP"
    printf '  %-22s %s\n' "子网掩码:"       "$INSTALL_NETMASK"
    printf '  %-22s %s\n' "网关:"           "$INSTALL_GATEWAY"
    printf '  %-22s %s\n' "DNS:"            "$INSTALL_DNS"
  else
    printf '  %-22s %s\n' "安装器网络:"     "DHCP 自动获取"
  fi
  printf '  %-22s %s\n' "主机名:"          "${INSTALL_HOSTNAME:-debian}"
  printf '  %-22s %s\n' "域名:"            "${INSTALL_DOMAIN:-localdomain}"
  echo ""
  printf '  %-22s %s\n' "root 密码:"       "已设置（不显示）"
  printf '  %-22s %s\n' "SSH 端口:"        "$SSH_PORT"
  printf '  %-22s %s\n' "SSH 登录方式:"    "$SSH_AUTH_MODE"
  if [[ -n "$PUBKEY_TEXT" ]]; then
    local first_line
    first_line="$(printf '%s' "$PUBKEY_TEXT" | head -1)"
    printf '  %-22s %s\n' "SSH 公钥:"       "${first_line:0:60}..."
  fi
  echo ""
  printf '  %-22s %s\n' "自动重启:"        "$AUTO_REBOOT"
  echo ""
  warn "以上配置将被写入 GRUB 和安装器 initrd。重启后将进入 Debian 安装程序。"
  warn "请确保已通过 VNC/控制台 连接，否则重启后将无法访问！"
  echo ""

  if [[ -t 0 ]]; then
    read -r -p "确认无误，继续执行？[y/N]: " _confirm
    case "${_confirm:-n}" in
      [Yy]*) log "已确认，开始执行…" ;;
      *) die "用户取消操作" ;;
    esac
  fi
}

# ---------- 文件校验（GPG + SHA256 全链路） ----------
find_debian_keyring() {
  local candidates=(
    /usr/share/keyrings/debian-archive-keyring.gpg
    /etc/apt/trusted.gpg.d/debian-archive-trixie-stable.gpg
    /etc/apt/trusted.gpg.d/debian-archive-bookworm-stable.gpg
    /etc/apt/trusted.gpg.d/debian-archive-bullseye-stable.gpg
    /etc/apt/trusted.gpg
  )
  local f
  for f in "${candidates[@]}"; do
    if [[ -s "$f" ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

verify_installer_files() {
  step "下载并校验 Debian 安装器文件"
  local keyring
  keyring="$(find_debian_keyring || true)"
  [[ -n "$keyring" ]] || die "没有找到 Debian archive keyring。请先运行：apt-get install -y debian-archive-keyring"

  local inrelease_url sha_url kernel_url initrd_url
  inrelease_url="$MIRROR_BASE/dists/$DEBIAN_CODENAME/InRelease"
  sha_url="$MIRROR_BASE/dists/$DEBIAN_CODENAME/main/installer-$DEBIAN_ARCH/current/images/SHA256SUMS"
  kernel_url="$MIRROR_BASE/dists/$DEBIAN_CODENAME/main/installer-$DEBIAN_ARCH/current/images/netboot/debian-installer/$DEBIAN_ARCH/linux"
  initrd_url="$MIRROR_BASE/dists/$DEBIAN_CODENAME/main/installer-$DEBIAN_ARCH/current/images/netboot/debian-installer/$DEBIAN_ARCH/initrd.gz"

  info "正在下载文件（共 4 个）…"
  log "1/4 下载 InRelease（官方签名元数据）"
  download "$inrelease_url" "$WORKDIR/InRelease"
  log "2/4 下载 SHA256SUMS（校验清单）"
  download "$sha_url" "$WORKDIR/SHA256SUMS"
  log "3/4 下载 linux（内核）"
  download "$kernel_url" "$WORKDIR/linux"
  log "4/4 下载 initrd.gz（安装器内存盘）"
  download "$initrd_url" "$WORKDIR/initrd.orig.gz"

  log "校验 InRelease 的 GPG 签名（防篡改第一步）"
  gpgv --keyring "$keyring" "$WORKDIR/InRelease" >/dev/null || \
    die "GPG 验证失败！InRelease 可能被篡改，请检查网络或镜像源。"

  log "校验 SHA256SUMS 是否受 InRelease 保护（防篡改第二步）"
  local expected_sha256sums actual_sha256sums
  expected_sha256sums="$({
    awk -v f="main/installer-$DEBIAN_ARCH/current/images/SHA256SUMS" '
      $1 == "SHA256:" {insha=1; next}
      insha && NF >= 3 {
        path=$3
        if (path == f) {
          print $1
          exit
        }
      }
    ' "$WORKDIR/InRelease"
  })"
  [[ -n "$expected_sha256sums" ]] || die "未能从 InRelease 中提取 SHA256SUMS 的校验值，InRelease 格式异常"
  actual_sha256sums="$(sha256sum "$WORKDIR/SHA256SUMS" | awk '{print $1}')"
  [[ "$expected_sha256sums" == "$actual_sha256sums" ]] || \
    die "SHA256SUMS 校验失败！文件可能被篡改，请换一个镜像源重试。"

  log "校验 linux 与 initrd.gz（防篡改第三步）"
  local expected_kernel expected_initrd actual_kernel actual_initrd
  expected_kernel="$(awk -v f="netboot/debian-installer/$DEBIAN_ARCH/linux" \
    '{p=$2; sub(/^\.\//, "", p); if (p==f) {print $1; exit}}' "$WORKDIR/SHA256SUMS")"
  expected_initrd="$(awk -v f="netboot/debian-installer/$DEBIAN_ARCH/initrd.gz" \
    '{p=$2; sub(/^\.\//, "", p); if (p==f) {print $1; exit}}' "$WORKDIR/SHA256SUMS")"
  [[ -n "$expected_kernel" ]] || die "未能从 SHA256SUMS 中找到 linux 的校验值"
  [[ -n "$expected_initrd" ]] || die "未能从 SHA256SUMS 中找到 initrd.gz 的校验值"
  actual_kernel="$(sha256sum "$WORKDIR/linux" | awk '{print $1}')"
  actual_initrd="$(sha256sum "$WORKDIR/initrd.orig.gz" | awk '{print $1}')"
  [[ "$expected_kernel" == "$actual_kernel" ]] || \
    die "linux 内核校验失败！下载的文件可能被篡改，请重新运行脚本。"
  [[ "$expected_initrd" == "$actual_initrd" ]] || \
    die "initrd.gz 校验失败！下载的文件可能被篡改，请重新运行脚本。"

  log "全部文件校验通过 ✓"
  run mkdir -p "$NETBOOT_DIR"
  run install -m 0644 "$WORKDIR/linux" "$NETBOOT_DIR/linux"
  run install -m 0644 "$WORKDIR/initrd.orig.gz" "$NETBOOT_DIR/initrd.orig.gz"
  run install -m 0600 "$WORKDIR/SHA256SUMS" "$NETBOOT_DIR/SHA256SUMS.official"
  cat > "$NETBOOT_DIR/VERIFY.log" <<LOG
verified_codename=$DEBIAN_CODENAME
verified_arch=$DEBIAN_ARCH
sha256sum_file=$actual_sha256sums
linux_sha256=$actual_kernel
initrd_orig_sha256=$actual_initrd
verified_at_utc=$(date -u +%FT%TZ)
LOG
  chmod 0600 "$NETBOOT_DIR/VERIFY.log"
}

# ---------- 构建 SSH 配置脚本（注入 initrd） ----------
build_ssh_setup_script() {
  local permit_root password_auth kbd_interactive
  case "$SSH_AUTH_MODE" in
    password|both)
      permit_root="yes"
      password_auth="yes"
      kbd_interactive="yes"
      ;;
    key-only)
      permit_root="prohibit-password"
      password_auth="no"
      kbd_interactive="no"
      ;;
    *)
      die "SSH_AUTH_MODE 仅支持 password / key-only / both"
      ;;
  esac

  cat <<EOS
#!/bin/sh
set -eu
cfg="/etc/ssh/sshd_config"
[ -f "\$cfg" ] || exit 0
backup="\${cfg}.bak-from-netboot-reinstall"
[ -f "\$backup" ] || cp -a "\$cfg" "\$backup"

set_cfg() {
  key="\$1"
  value="\$2"
  if grep -Eq "^[#[:space:]]*\${key}[[:space:]]+" "\$cfg"; then
    sed -ri "s@^[#[:space:]]*\${key}[[:space:]].*@\${key} \${value}@g" "\$cfg"
  else
    printf '%s %s\n' "\$key" "\$value" >> "\$cfg"
  fi
}

set_cfg Port ${SSH_PORT}
set_cfg PermitRootLogin ${permit_root}
set_cfg PasswordAuthentication ${password_auth}
set_cfg KbdInteractiveAuthentication ${kbd_interactive}
set_cfg PubkeyAuthentication yes
set_cfg UsePAM yes

EOS

  if [[ -n "$PUBKEY_TEXT" ]]; then
    printf 'mkdir -p /root/.ssh\n'
    printf 'chmod 700 /root/.ssh\n'
    printf 'cat > /root/.ssh/authorized_keys <<'"'"'EOF_AUTH_KEYS'"'"'\n'
    printf '%s\n' "$PUBKEY_TEXT"
    printf 'EOF_AUTH_KEYS\n'
    printf 'chmod 600 /root/.ssh/authorized_keys\n'
  fi
}

# ---------- 构建 preseed 配置 ----------
build_preseed() {
  step "生成预置文件（preseed.cfg）"
  local root_hash ssh_setup ssh_setup_b64
  root_hash="$(hash_password_sha512 "$ROOT_PASSWORD")"
  ssh_setup="$(build_ssh_setup_script)"
  ssh_setup_b64="$(printf '%s' "$ssh_setup" | base64 | tr -d '\n')"

  : > "$WORKDIR/preseed.cfg"

  {
    echo "### 仅预置网络、root 账号与 SSH；分区/软件源/任务选择等仍在安装器中手动完成"
    echo "d-i passwd/root-login boolean true"
    echo "d-i passwd/make-user boolean false"
    echo "d-i passwd/root-password-crypted password $root_hash"
    echo "d-i pkgsel/include string openssh-server"
    echo "d-i netcfg/choose_interface select auto"
    echo "d-i netcfg/get_hostname string ${INSTALL_HOSTNAME:-debian}"
    echo "d-i netcfg/get_domain string ${INSTALL_DOMAIN:-localdomain}"

    if [[ "$NETWORK_MODE" == "dhcp" ]]; then
      echo "d-i netcfg/disable_autoconfig boolean false"
    else
      echo "d-i netcfg/disable_autoconfig boolean true"
      echo "d-i netcfg/get_ipaddress string $INSTALL_IP"
      echo "d-i netcfg/get_netmask string $INSTALL_NETMASK"
      echo "d-i netcfg/get_gateway string $INSTALL_GATEWAY"
      echo "d-i netcfg/get_nameservers string $INSTALL_DNS"
      echo "d-i netcfg/confirm_static boolean true"
    fi

    printf '%s\n' "d-i preseed/late_command string mkdir -p /target/root; /bin/sh -c \"printf '%s' '$ssh_setup_b64' | base64 -d > /target/root/installer-ssh-setup.sh\"; chmod 700 /target/root/installer-ssh-setup.sh; in-target /bin/sh /root/installer-ssh-setup.sh; rm -f /target/root/installer-ssh-setup.sh"
  } >> "$WORKDIR/preseed.cfg"

  chmod 0600 "$WORKDIR/preseed.cfg"
  log "预置文件已生成"
}

# ---------- 将 preseed 注入 initrd ----------
inject_preseed_into_initrd() {
  step "将预置文件注入 initrd"
  local unpack_dir
  unpack_dir="$WORKDIR/initrd-unpack"
  run mkdir -p "$unpack_dir"

  (
    cd "$unpack_dir"
    gzip -dc "$NETBOOT_DIR/initrd.orig.gz" | cpio -idm --quiet
    install -m 0600 "$WORKDIR/preseed.cfg" "$unpack_dir/preseed.cfg"
    find . -print0 | cpio --null --quiet -H newc -o | gzip -9 > "$NETBOOT_DIR/initrd.gz"
  )

  chmod 0644 "$NETBOOT_DIR/initrd.gz"
  log "initrd.gz 已生成（含预置配置）"
}

# ---------- 检测 GRUB 所需模块 ----------
detect_grub_modules() {
  local path="$NETBOOT_DIR"
  GRUB_FS_UUID="$(findmnt -n -o UUID -T "$path" 2>/dev/null || true)"
  if [[ -z "$GRUB_FS_UUID" ]]; then
    local src
    src="$(findmnt -n -o SOURCE -T "$path" 2>/dev/null || true)"
    if [[ -n "$src" ]]; then
      GRUB_FS_UUID="$(blkid -s UUID -o value "$src" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$GRUB_FS_UUID" ]] || die "无法识别 $NETBOOT_DIR 所在文件系统的 UUID"

  GRUB_PARTMAP="$(grub-probe -t partmap "$path" 2>/dev/null || true)"
  GRUB_FS_MOD="$(grub-probe -t fs "$path" 2>/dev/null || true)"
  GRUB_ABS="$(grub-probe -t abstraction "$path" 2>/dev/null || true)"
}

# ---------- 写入 GRUB 菜单项 ----------
write_grub_entry() {
  step "写入 GRUB 启动菜单"
  local grub_lines=""
  if [[ -n "$GRUB_ABS" && "$GRUB_ABS" != "diskfilter" ]]; then
    local a
    for a in $GRUB_ABS; do
      grub_lines+="    insmod ${a}"$'\n'
    done
  fi
  if [[ -n "$GRUB_PARTMAP" ]]; then
    grub_lines+="    insmod part_${GRUB_PARTMAP}"$'\n'
  fi
  if [[ -n "$GRUB_FS_MOD" ]]; then
    grub_lines+="    insmod ${GRUB_FS_MOD}"$'\n'
  fi

  cat > "$GRUB_SCRIPT" <<EOF2
#!/bin/sh
exec tail -n +3 \$0
menuentry '${MENU_TITLE}' {
${grub_lines}    search --no-floppy --fs-uuid --set=root ${GRUB_FS_UUID}
    linux /netboot/linux priority=low
    initrd /netboot/initrd.gz
}
EOF2
  chmod 0755 "$GRUB_SCRIPT"
  log "GRUB 菜单项已写入: $GRUB_SCRIPT"
}

# ---------- 更新 GRUB 配置 ----------
update_grub_cfg() {
  log "更新 GRUB 配置…"
  if command -v update-grub >/dev/null 2>&1; then
    run update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    local out=/boot/grub/grub.cfg
    run grub-mkconfig -o "$out"
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    local out=/boot/grub2/grub.cfg
    [[ -d /boot/efi/EFI ]] && out=/boot/efi/EFI/$(ls /boot/efi/EFI | head -n1)/grub.cfg || true
    run grub2-mkconfig -o "$out"
  else
    die "未找到 update-grub / grub-mkconfig / grub2-mkconfig"
  fi
  log "GRUB 配置更新完成"
}

# ---------- 尝试设置下次启动项 ----------
schedule_next_boot_if_possible() {
  if [[ "$AUTO_REBOOT" != "yes" ]]; then
    return 0
  fi

  if command -v grub-reboot >/dev/null 2>&1; then
    grub-reboot "$MENU_TITLE" 2>/dev/null || \
      warn "grub-reboot 执行失败，请通过 VNC 手动在 GRUB 菜单中选择安装项"
  else
    warn "系统没有 grub-reboot，请通过 VNC 手动在 GRUB 菜单中选择安装项"
  fi
}

# ---------- 最终汇总与 VNC 操作说明 ----------
print_summary() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║                    脚本执行完成                             ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  printf '  %-22s %s\n' "Debian 版本:"       "$DEBIAN_VERSION ($DEBIAN_CODENAME)"
  printf '  %-22s %s\n' "架构:"              "$DEBIAN_ARCH"
  printf '  %-22s %s\n' "netboot 目录:"      "$NETBOOT_DIR"
  printf '  %-22s %s\n' "安装器内核:"        "$NETBOOT_DIR/linux"
  printf '  %-22s %s\n' "安装器 initrd:"     "$NETBOOT_DIR/initrd.gz"
  printf '  %-22s %s\n' "GRUB 菜单项:"       "$MENU_TITLE"

  echo ""
  echo "  ┌─ 安装后 SSH 配置 ──────────────────────────────────────┐"
  printf '  │  %-20s %s\n' "SSH 端口:" "$SSH_PORT"
  printf '  │  %-20s %s\n' "SSH 登录方式:" "$SSH_AUTH_MODE"
  printf '  │  %-20s %s\n' "root 登录:" "已允许"
  echo  "  └────────────────────────────────────────────────────────┘"

  echo ""
  echo "  ┌─ 文件安全校验 ─────────────────────────────────────────┐"
  echo  "  │  GPG 签名验证: ✓ 通过（使用 Debian 官方 keyring）     │"
  echo  "  │  SHA256 校验:  ✓ 通过（linux + initrd.gz）            │"
  printf '  │  校验日志: %s\n' "$NETBOOT_DIR/VERIFY.log"
  echo  "  └────────────────────────────────────────────────────────┘"

  echo ""
  echo "  ★★★ 下一步操作指引 ★★★"
  echo ""
  echo "  1. 在服务器控制面板打开 VNC 连接"
  echo "  2. 执行重启命令（手动运行）："
  echo ""
  echo "       reboot"
  echo ""
  echo "  3. 重启后在 GRUB 菜单中选择："
  echo ""
  printf '       %s\n' "$MENU_TITLE"
  echo ""
  echo "  4. 进入 Debian 安装器后通过 VNC 手动操作："
  echo "     - 确认网络配置（已预置，通常直接 Continue）"
  echo "     - 选择磁盘分区方式（⚠ 此操作将清空磁盘！）"
  echo "     - 选择软件和任务"
  echo "     - root 密码已预置，安装器会自动设置"
  echo "     - 安装完成后系统自动重启，SSH 端口为: $SSH_PORT"
  echo ""

  if [[ "$AUTO_REBOOT" == "yes" ]]; then
    warn "AUTO_REBOOT=yes：3 秒后自动重启，请确保 VNC 已打开！"
  else
    info "确认 VNC 已连接后，执行 'reboot' 开始安装流程。"
  fi
  echo ""
}

# ---------- 主流程 ----------
main() {
  banner
  require_root
  install_dependencies

  WORKDIR="$(mktemp -d /tmp/debian-netboot-reinstall.XXXXXX)"

  # 版本选择
  resolve_debian_release

  # 网络检测（始终执行，不管选哪种模式）
  detect_network
  show_detected_network
  choose_network

  # SSH 端口与认证方式
  wizard_ssh

  # 校验 SSH 端口合法性
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT 必须是数字"
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT 必须在 1-65535 之间"

  # root 密码
  if [[ -z "$ROOT_PASSWORD" ]]; then
    step "设置安装后 root 密码"
    [[ -t 0 ]] || die "ROOT_PASSWORD 未设置且不是交互终端，请通过环境变量传入 ROOT_PASSWORD"
    read_secret_twice
  fi

  # 公钥收集
  collect_pubkey

  # 确认
  confirm_proceed

  # 下载、校验、注入、写 GRUB
  verify_installer_files
  build_preseed
  inject_preseed_into_initrd
  detect_grub_modules
  write_grub_entry
  update_grub_cfg
  schedule_next_boot_if_possible
  print_summary

  if [[ "$AUTO_REBOOT" == "yes" ]]; then
    sleep 3
    reboot
  fi
}

main "$@"
