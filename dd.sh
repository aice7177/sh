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
NETWORK_MODE="${NETWORK_MODE:-auto-copy}"

# SSH 认证模式：password / key-only / both
SSH_AUTH_MODE="${SSH_AUTH_MODE:-key-only}"
SSH_PORT="${SSH_PORT:-2222}"

# root 密码：建议不要直接写到脚本里，留空时脚本会安全提示输入
ROOT_PASSWORD="${ROOT_PASSWORD:-}"

# 公钥来源：二选一；如果都为空且 SSH_AUTH_MODE 需要公钥，脚本会尝试读取 /root/.ssh/authorized_keys
PUBKEY_FILE="${PUBKEY_FILE:-}"
PUBKEY_TEXT="${PUBKEY_TEXT:-}"

# yes = 尝试设置下次启动只进入安装器，并立即重启；no = 只准备环境，不自动重启
AUTO_REBOOT="${AUTO_REBOOT:-no}"

# ======================================================

log() {
  printf '[+] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

run() {
  "$@"
}

trim() {
  awk '{$1=$1;print}' <<<"$*"
}

resolve_debian_release() {
  local release_input="${DEBIAN_RELEASE:-${DEBIAN_CODENAME:-}}"

  if [[ -z "$release_input" && -t 0 ]]; then
    echo "请选择要安装的 Debian 版本："
    echo "  1) Debian 12 (bookworm)"
    echo "  2) Debian 13 (trixie，当前 stable)"
    read -r -p "请输入 12 或 13 [13]: " release_input
    release_input="${release_input:-13}"
  fi

  release_input="$(printf '%s' "$release_input" | tr '[:upper:]' '[:lower:]')"

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
      DEBIAN_VERSION="13"
      DEBIAN_CODENAME="trixie"
      ;;
    *)
      die "DEBIAN_RELEASE 仅支持 12 / 13 / bookworm / trixie / stable"
      ;;
  esac

  if [[ -z "$MENU_TITLE" ]]; then
    MENU_TITLE="Netboot Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME}) Installer ${DEBIAN_ARCH}"
  fi
}

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
import crypt, secrets, sys
pw = sys.argv[1]
salt = "$6$" + secrets.token_urlsafe(12)
print(crypt.crypt(pw, salt))
PY
    return 0
  fi
  die "无法生成 SHA-512 密码哈希，请安装 openssl / whois(mkpasswd) / python3"
}

download() {
  local url="${1:?}" out="${2:?}"
  if command -v curl >/dev/null 2>&1; then
    run curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    run wget -4 -O "$out" "$url"
  else
    die "缺少 curl 或 wget"
  fi
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行"
}

read_secret_twice() {
  local p1 p2
  while true; do
    read -r -s -p "请输入安装后 root 密码: " p1; echo
    read -r -s -p "请再次输入安装后 root 密码: " p2; echo
    [[ -n "$p1" ]] || { warn "密码不能为空"; continue; }
    [[ "$p1" == "$p2" ]] || { warn "两次输入不一致，请重试"; continue; }
    ROOT_PASSWORD="$p1"
    break
  done
}

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
    return 0
  fi

  if [[ -f /root/.ssh/authorized_keys ]]; then
    PUBKEY_TEXT="$(< /root/.ssh/authorized_keys)"
    log "已自动读取 /root/.ssh/authorized_keys 作为安装后 root 公钥"
    return 0
  fi

  if [[ -t 0 ]]; then
    echo "未找到公钥。你可以粘贴一整行 SSH 公钥（ssh-ed25519 / ssh-rsa 开头）。"
    read -r -p "若不需要公钥，请按 Ctrl+C 退出后改用 SSH_AUTH_MODE=password：" PUBKEY_TEXT
    [[ -n "$PUBKEY_TEXT" ]] || die "未提供公钥"
    return 0
  fi

  die "当前模式需要公钥，但未提供 PUBKEY_FILE / PUBKEY_TEXT，且 /root/.ssh/authorized_keys 不存在"
}

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

  log "当前网络检测结果："
  printf '    网卡: %s\n' "${DETECT_IFACE:-<未识别>}"
  printf '    IPv4: %s\n' "${DETECT_IP:-<未识别>}"
  printf '    掩码: %s\n' "${DETECT_NETMASK:-<未识别>}"
  printf '    网关: %s\n' "${DETECT_GATEWAY:-<未识别>}"
  printf '    DNS : %s\n' "${DETECT_DNS:-<未识别>}"
  printf '    主机名: %s\n' "${DETECT_HOSTNAME:-debian}"
  printf '    域名  : %s\n' "${DETECT_DOMAIN:-localdomain}"
}

choose_network() {
  case "$NETWORK_MODE" in
    auto-copy)
      [[ -n "${DETECT_IP:-}" && -n "${DETECT_NETMASK:-}" && -n "${DETECT_GATEWAY:-}" ]] || \
        die "NETWORK_MODE=auto-copy 失败：未能完整识别当前 IPv4/掩码/网关，请改用 NETWORK_MODE=dhcp 或 manual"
      INSTALL_IP="$DETECT_IP"
      INSTALL_NETMASK="$DETECT_NETMASK"
      INSTALL_GATEWAY="$DETECT_GATEWAY"
      INSTALL_DNS="$(trim "${DETECT_DNS:-$DETECT_GATEWAY}")"
      INSTALL_HOSTNAME="${DETECT_HOSTNAME:-debian}"
      INSTALL_DOMAIN="${DETECT_DOMAIN:-localdomain}"
      ;;
    dhcp)
      INSTALL_IP=""
      INSTALL_NETMASK=""
      INSTALL_GATEWAY=""
      INSTALL_DNS=""
      INSTALL_HOSTNAME="${DETECT_HOSTNAME:-debian}"
      INSTALL_DOMAIN="${DETECT_DOMAIN:-localdomain}"
      ;;
    manual)
      if [[ ! -t 0 ]]; then
        die "NETWORK_MODE=manual 需要交互式终端"
      fi
      read -r -p "安装器使用的 IPv4 地址: " INSTALL_IP
      read -r -p "子网掩码 (例如 255.255.255.0): " INSTALL_NETMASK
      read -r -p "默认网关: " INSTALL_GATEWAY
      read -r -p "DNS（多个用空格分隔）: " INSTALL_DNS
      read -r -p "主机名 [${DETECT_HOSTNAME:-debian}]: " INSTALL_HOSTNAME
      read -r -p "域名 [${DETECT_DOMAIN:-localdomain}]: " INSTALL_DOMAIN
      INSTALL_HOSTNAME="${INSTALL_HOSTNAME:-${DETECT_HOSTNAME:-debian}}"
      INSTALL_DOMAIN="${INSTALL_DOMAIN:-${DETECT_DOMAIN:-localdomain}}"
      [[ -n "$INSTALL_IP" && -n "$INSTALL_NETMASK" && -n "$INSTALL_GATEWAY" ]] || die "手动网络参数不能为空"
      ;;
    *)
      die "NETWORK_MODE 仅支持 auto-copy / dhcp / manual"
      ;;
  esac
}

find_debian_keyring() {
  local candidates=(
    /usr/share/keyrings/debian-archive-keyring.gpg
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
  local keyring
  keyring="$(find_debian_keyring || true)"
  [[ -n "$keyring" ]] || die "没有找到 Debian archive keyring。请先安装 debian-archive-keyring 后再运行。"

  local inrelease_url sha_url kernel_url initrd_url
  inrelease_url="$MIRROR_BASE/dists/$DEBIAN_CODENAME/InRelease"
  sha_url="$MIRROR_BASE/dists/$DEBIAN_CODENAME/main/installer-$DEBIAN_ARCH/current/images/SHA256SUMS"
  kernel_url="$MIRROR_BASE/dists/$DEBIAN_CODENAME/main/installer-$DEBIAN_ARCH/current/images/netboot/debian-installer/$DEBIAN_ARCH/linux"
  initrd_url="$MIRROR_BASE/dists/$DEBIAN_CODENAME/main/installer-$DEBIAN_ARCH/current/images/netboot/debian-installer/$DEBIAN_ARCH/initrd.gz"

  log "下载 Debian 官方签名元数据与 netboot 文件"
  download "$inrelease_url" "$WORKDIR/InRelease"
  download "$sha_url" "$WORKDIR/SHA256SUMS"
  download "$kernel_url" "$WORKDIR/linux"
  download "$initrd_url" "$WORKDIR/initrd.orig.gz"

  log "校验 InRelease 的 GPG 签名"
  gpgv --keyring "$keyring" "$WORKDIR/InRelease" >/dev/null

  log "校验 SHA256SUMS 是否受 InRelease 保护"
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
  [[ -n "$expected_sha256sums" ]] || die "未能从 InRelease 中提取 SHA256SUMS 的校验值"
  actual_sha256sums="$(sha256sum "$WORKDIR/SHA256SUMS" | awk '{print $1}')"
  [[ "$expected_sha256sums" == "$actual_sha256sums" ]] || die "SHA256SUMS 校验失败，文件可能被篡改"

  log "校验 linux 与 initrd.orig.gz"
  local expected_kernel expected_initrd actual_kernel actual_initrd
  expected_kernel="$(awk -v f="netboot/debian-installer/$DEBIAN_ARCH/linux" '{p=$2; sub(/^\.\//, "", p); if (p==f) {print $1; exit}}' "$WORKDIR/SHA256SUMS")"
  expected_initrd="$(awk -v f="netboot/debian-installer/$DEBIAN_ARCH/initrd.gz" '{p=$2; sub(/^\.\//, "", p); if (p==f) {print $1; exit}}' "$WORKDIR/SHA256SUMS")"
  [[ -n "$expected_kernel" ]] || die "未能从 SHA256SUMS 中找到 linux 的校验值"
  [[ -n "$expected_initrd" ]] || die "未能从 SHA256SUMS 中找到 initrd.gz 的校验值"
  actual_kernel="$(sha256sum "$WORKDIR/linux" | awk '{print $1}')"
  actual_initrd="$(sha256sum "$WORKDIR/initrd.orig.gz" | awk '{print $1}')"
  [[ "$expected_kernel" == "$actual_kernel" ]] || die "linux 校验失败，文件可能被篡改"
  [[ "$expected_initrd" == "$actual_initrd" ]] || die "initrd.gz 校验失败，文件可能被篡改"

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

build_ssh_setup_script() {
  local permit_root password_auth kbd_interactive
  case "$SSH_AUTH_MODE" in
    password)
      permit_root="yes"
      password_auth="yes"
      kbd_interactive="yes"
      ;;
    both)
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

  local pubkey_block=""
  if [[ -n "$PUBKEY_TEXT" ]]; then
    pubkey_block=$(cat <<'KEYBLOCK'
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'EOF_AUTH_KEYS'
__PUBKEY_TEXT__
EOF_AUTH_KEYS
chmod 600 /root/.ssh/authorized_keys
KEYBLOCK
)
    pubkey_block="${pubkey_block//__PUBKEY_TEXT__/$PUBKEY_TEXT}"
  fi

  cat <<'EOS'
#!/bin/sh
set -eu
cfg="/etc/ssh/sshd_config"
[ -f "$cfg" ] || exit 0
backup="${cfg}.bak-from-netboot-reinstall"
[ -f "$backup" ] || cp -a "$cfg" "$backup"

set_cfg() {
  key="$1"
  value="$2"
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$cfg"; then
    sed -ri "s@^[#[:space:]]*${key}[[:space:]].*@${key} ${value}@g" "$cfg"
  else
    printf '%s %s\n' "$key" "$value" >> "$cfg"
  fi
}

set_cfg Port __SSH_PORT__
set_cfg PermitRootLogin __PERMIT_ROOT__
set_cfg PasswordAuthentication __PASSWORD_AUTH__
set_cfg KbdInteractiveAuthentication __KBD_INTERACTIVE__
set_cfg PubkeyAuthentication yes
set_cfg UsePAM yes

__PUBKEY_BLOCK__
EOS
}

build_preseed() {
  local root_hash ssh_setup ssh_setup_b64
  root_hash="$(hash_password_sha512 "$ROOT_PASSWORD")"

  ssh_setup="$(build_ssh_setup_script)"
  ssh_setup="${ssh_setup//__SSH_PORT__/$SSH_PORT}"
  case "$SSH_AUTH_MODE" in
    password)
      ssh_setup="${ssh_setup//__PERMIT_ROOT__/yes}"
      ssh_setup="${ssh_setup//__PASSWORD_AUTH__/yes}"
      ssh_setup="${ssh_setup//__KBD_INTERACTIVE__/yes}"
      ;;
    both)
      ssh_setup="${ssh_setup//__PERMIT_ROOT__/yes}"
      ssh_setup="${ssh_setup//__PASSWORD_AUTH__/yes}"
      ssh_setup="${ssh_setup//__KBD_INTERACTIVE__/yes}"
      ;;
    key-only)
      ssh_setup="${ssh_setup//__PERMIT_ROOT__/prohibit-password}"
      ssh_setup="${ssh_setup//__PASSWORD_AUTH__/no}"
      ssh_setup="${ssh_setup//__KBD_INTERACTIVE__/no}"
      ;;
  esac
  if [[ -n "$PUBKEY_TEXT" ]]; then
    local block
    block=$(cat <<'KEYBLOCK'
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'EOF_AUTH_KEYS'
__PUBKEY_TEXT__
EOF_AUTH_KEYS
chmod 600 /root/.ssh/authorized_keys
KEYBLOCK
)
    block="${block//__PUBKEY_TEXT__/$PUBKEY_TEXT}"
    ssh_setup="${ssh_setup//__PUBKEY_BLOCK__/$block}"
  else
    ssh_setup="${ssh_setup//__PUBKEY_BLOCK__/}"
  fi

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
}

inject_preseed_into_initrd() {
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
}

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

write_grub_entry() {
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

  local kernel_args
  kernel_args="priority=low"

  cat > "$GRUB_SCRIPT" <<EOF2
#!/bin/sh
exec tail -n +3 \$0
menuentry '${MENU_TITLE}' {
${grub_lines}    search --no-floppy --fs-uuid --set=root ${GRUB_FS_UUID}
    linux /netboot/linux ${kernel_args}
    initrd /netboot/initrd.gz
}
EOF2
  chmod 0755 "$GRUB_SCRIPT"
}

update_grub_cfg() {
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
}

schedule_next_boot_if_possible() {
  if [[ "$AUTO_REBOOT" != "yes" ]]; then
    return 0
  fi

  if command -v grub-reboot >/dev/null 2>&1; then
    grub-reboot "$MENU_TITLE" || warn "grub-reboot 执行失败，请通过 VNC 手动选择 GRUB 菜单中的安装项"
  else
    warn "系统没有 grub-reboot，无法保证下次只进安装器；请通过 VNC 手动选择 GRUB 菜单中的安装项"
  fi
}

print_summary() {
  echo
  echo "================ 已完成 ================="
  echo "Debian 版本      : $DEBIAN_VERSION ($DEBIAN_CODENAME)"
  echo "架构             : $DEBIAN_ARCH"
  echo "网络模式         : $NETWORK_MODE"
  if [[ "$NETWORK_MODE" == "dhcp" ]]; then
    echo "安装器网络       : DHCP"
  else
    echo "安装器 IPv4      : $INSTALL_IP"
    echo "安装器掩码       : $INSTALL_NETMASK"
    echo "安装器网关       : $INSTALL_GATEWAY"
    echo "安装器 DNS       : $INSTALL_DNS"
  fi
  echo "安装后 SSH 端口  : $SSH_PORT"
  echo "安装后 SSH 模式  : $SSH_AUTH_MODE"
  echo "GRUB 菜单名      : $MENU_TITLE"
  echo "netboot 目录      : $NETBOOT_DIR"
  echo "原始 initrd      : $NETBOOT_DIR/initrd.orig.gz"
  echo "带预置 initrd    : $NETBOOT_DIR/initrd.gz"
  echo "官方校验文件     : $NETBOOT_DIR/SHA256SUMS.official"
  echo "校验日志         : $NETBOOT_DIR/VERIFY.log"
  echo "预置文件（临时） : $WORKDIR/preseed.cfg"
  echo "========================================"
  echo
  echo "后续说明："
  echo "1) 通过 VNC/控制台 重启服务器。"
  echo "2) 在 GRUB 中选择：$MENU_TITLE"
  echo "3) 进入 Debian 安装器后，分区/格式化/软件源等继续手动完成。"
  echo "4) 安装完成后，系统将只保留 root 账号；SSH 端口与 root 登录策略已按脚本预置。"
  echo
  if [[ "$AUTO_REBOOT" == "yes" ]]; then
    echo "AUTO_REBOOT=yes：脚本接下来会尝试立即重启。请提前打开 VNC。"
  else
    echo "当前未自动重启；确认无误后请手动 reboot。"
  fi
}

main() {
  require_root
  need_cmd awk
  need_cmd sed
  need_cmd grep
  need_cmd ip
  need_cmd findmnt
  need_cmd blkid
  need_cmd sha256sum
  need_cmd gpgv
  need_cmd grub-probe
  need_cmd cpio
  need_cmd gzip
  need_cmd base64

  WORKDIR="$(mktemp -d /tmp/debian-netboot-reinstall.XXXXXX)"

  resolve_debian_release
  detect_network
  choose_network

  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT 必须是数字"
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT 必须在 1-65535 之间"

  if [[ -z "$ROOT_PASSWORD" ]]; then
    [[ -t 0 ]] || die "ROOT_PASSWORD 为空且当前不是交互终端，请通过环境变量传入 ROOT_PASSWORD"
    read_secret_twice
  fi

  collect_pubkey
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
