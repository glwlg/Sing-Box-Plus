#!/usr/bin/env bash
# ============================================================
#  Sing-Box-Plus 管理脚本（可选协议：直连 + WARP）
#  Version: v4.6.1
#  author：Alvin9999
#  Repo: https://github.com/Alvin9999-newpac/Sing-Box-Plus
# ============================================================

set -Eeuo pipefail

# ===== [BEGIN] SBP 引导模块 v2.2.0+（包管理器优先 + 二进制回退） =====
# 模式与哨兵
: "${SBP_SOFT:=0}"                               # 1=宽松模式（失败尽量继续），默认 0=严格
: "${SBP_SKIP_DEPS:=0}"                          # 1=启动跳过依赖检查（只在菜单 1) 再装）
: "${SBP_FORCE_DEPS:=0}"                         # 1=强制重新安装依赖
: "${SBP_BIN_ONLY:=0}"                           # 1=强制走二进制模式，不用包管理器
: "${SBP_ROOT:=/var/lib/sing-box-plus}"
: "${SBP_BIN_DIR:=${SBP_ROOT}/bin}"
: "${SBP_DEPS_SENTINEL:=/var/lib/sing-box-plus/.deps_ok}"

mkdir -p "$SBP_BIN_DIR" 2>/dev/null || true
export PATH="$SBP_BIN_DIR:$PATH"

# 工具：下载器 + 轻量重试
dl() { # 用法：dl <URL> <OUT_PATH>
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --connect-timeout 5 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    timeout 15 wget -qO "$out" --tries=2 "$url"
  else
    echo "[ERROR] 缺少 curl/wget：无法下载 $url"; return 1
  fi
}
with_retry() { local n=${1:-3}; shift; local i=1; until "$@"; do [ $i -ge "$n" ] && return 1; sleep $((i*2)); i=$((i+1)); done; }

# 工具：架构探测 + jq 静态兜底
detect_goarch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    i386|i686)    echo 386   ;;
    *)            echo amd64 ;;
  esac
}
ensure_jq_static() {
  command -v jq >/dev/null 2>&1 && return 0
  local arch out="$SBP_BIN_DIR/jq" url alt
  arch="$(detect_goarch)"
  url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}"
  alt="https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
  dl "$url" "$out" || { [ "$arch" = amd64 ] && dl "$alt" "$out" || true; }
  chmod +x "$out" 2>/dev/null || true
  command -v jq >/dev/null 2>&1
}

# 工具：核心命令自检
sbp_core_ok() {
  local need=(curl jq tar unzip openssl)
  local b; for b in "${need[@]}"; do command -v "$b" >/dev/null 2>&1 || return 1; done
  return 0
}

# —— 包管理器路径 —— #
sbp_detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then PM=apt
  elif command -v dnf      >/dev/null 2>&1; then PM=dnf
  elif command -v yum      >/dev/null 2>&1; then PM=yum
  elif command -v pacman   >/dev/null 2>&1; then PM=pacman
  elif command -v zypper   >/dev/null 2>&1; then PM=zypper
  else PM=unknown; fi
  [ "$PM" = unknown ] && return 1 || return 0
}

# apt 允许发行信息变化（stable→oldstable / Version 变化）
apt_allow_release_change() {
  cat >/etc/apt/apt.conf.d/99allow-releaseinfo-change <<'CONF'
Acquire::AllowReleaseInfoChange::Suite "true";
Acquire::AllowReleaseInfoChange::Version "true";
CONF
}

# 刷新软件仓（含各系兜底）
sbp_pm_refresh() {
  case "$PM" in
    apt)
      apt_allow_release_change
      [[ -f /etc/apt/sources.list ]] && sed -i 's#^deb http://#deb https://#' /etc/apt/sources.list 2>/dev/null || true
      # 修正 bullseye 的 security 行：bullseye/updates → debian-security bullseye-security
      [[ -f /etc/apt/sources.list ]] && sed -i -E 's#^(deb\s+https?://security\.debian\.org)(/debian-security)?\s+bullseye/updates(.*)$#\1/debian-security bullseye-security\3#' /etc/apt/sources.list || true

      local AOPT=""
      curl -6 -fsS --connect-timeout 2 https://deb.debian.org >/dev/null 2>&1 || AOPT='-o Acquire::ForceIPv4=true'

      if ! with_retry 3 apt-get update -y $AOPT; then
        # backports 404 临时注释再试
        sed -i 's#^\([[:space:]]*deb .* bullseye-backports.*\)#\# \1#' /etc/apt/sources.list 2>/dev/null || true
        with_retry 2 apt-get update -y $AOPT -o Acquire::Check-Valid-Until=false || [ "$SBP_SOFT" = 1 ]
      fi
      ;;
    dnf)
      dnf clean metadata || true
      with_retry 3 dnf makecache || [ "$SBP_SOFT" = 1 ]
      ;;
    yum)
      yum clean all || true
      with_retry 3 yum makecache fast || true
      yum install -y epel-release || true   # EL7/老环境便于装 jq 等
      ;;
    pacman)
      pacman-key --init >/dev/null 2>&1 || true
      pacman-key --populate archlinux >/dev/null 2>&1 || true
      with_retry 3 pacman -Syy --noconfirm || [ "$SBP_SOFT" = 1 ]
      ;;
    zypper)
      zypper -n ref || zypper -n ref --force || true
      ;;
  esac
}

# 逐包安装（单个失败不拖累整体）
sbp_pm_install() {
  case "$PM" in
    apt)
      local p; apt-get update -y >/dev/null 2>&1 || true
      for p in "$@"; do apt-get install -y --no-install-recommends "$p" || true; done
      ;;
    dnf)
      local p; for p in "$@"; do dnf install -y "$p" || true; done
      ;;
    yum)
      yum install -y epel-release || true
      local p; for p in "$@"; do yum install -y "$p" || true; done
      ;;
    pacman)
      pacman -Sy --noconfirm || [ "$SBP_SOFT" = 1 ]
      local p; for p in "$@"; do pacman -S --noconfirm --needed "$p" || true; done
      ;;
    zypper)
      zypper -n ref || true
      local p; for p in "$@"; do zypper --non-interactive install "$p" || true; done
      ;;
  esac
}

# 用包管理器装一轮依赖
sbp_install_prereqs_pm() {
  sbp_detect_pm || return 1
  sbp_pm_refresh

  case "$PM" in
    apt)    CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz-utils uuid-runtime iproute2 iptables ufw) ;;
    dnf|yum)CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute iptables iptables-nft firewalld) ;;
    pacman) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables) ;;
    zypper) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables firewalld) ;;
    *) return 1 ;;
  esac

  sbp_pm_install "${CORE[@]}" "${EXTRA[@]}"

  # jq 兜底：安装失败时下载静态 jq
  if ! command -v jq >/dev/null 2>&1; then
    echo "[INFO] 通过包管理器安装 jq 失败，尝试下载静态 jq ..."
    ensure_jq_static || { echo "[ERROR] 无法获取 jq"; return 1; }
  fi

  # 严格模式：核心仍缺则失败
  if ! sbp_core_ok; then
    [ "$SBP_SOFT" = 1 ] || return 1
    echo "[WARN] 核心依赖未就绪（宽松模式继续）"
  fi
  return 0
}

# —— 二进制模式：直接获取 sing-box 可执行文件 —— #
install_singbox_binary() {
  local arch goarch pkg tmp json url fn
  goarch="$(detect_goarch)"
  tmp="$(mktemp -d)" || return 1

  ensure_jq_static || { echo "[ERROR] 无法获取 jq，二进制模式失败"; rm -rf "$tmp"; return 1; }
json="$(with_retry 3 curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.13.7)" || { rm -rf "$tmp"; return 1; }
  url="$(printf '%s' "$json" | jq -r --arg a "$goarch" '
    .assets[] | select(.name|test("linux-" + $a + "\\.(tar\\.(xz|gz)|zip)$")) | .browser_download_url
  ' | head -n1)"

  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "[ERROR] 未找到匹配架构($goarch)的 sing-box 资产"; rm -rf "$tmp"; return 1
  fi

  pkg="$tmp/pkg"
  with_retry 3 dl "$url" "$pkg" || { rm -rf "$tmp"; return 1; }

  case "$url" in
    *.tar.xz)  if command -v xz >/dev/null 2>&1; then tar -xJf "$pkg" -C "$tmp"; else echo "[ERROR] 缺少 xz；请安装 xz/xz-utils 或换 .tar.gz/.zip"; rm -rf "$tmp"; return 1; fi ;;
    *.tar.gz)  tar -xzf "$pkg" -C "$tmp" ;;
    *.zip)     unzip -q "$pkg" -d "$tmp" || { echo "[ERROR] 缺少 unzip"; rm -rf "$tmp"; return 1; } ;;
    *)         echo "[ERROR] 未知包格式：$url"; rm -rf "$tmp"; return 1 ;;
  esac

  fn="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  [ -n "$fn" ] || { echo "[ERROR] 包内未找到 sing-box"; rm -rf "$tmp"; return 1; }

  install -m 0755 "$fn" "$SBP_BIN_DIR/sing-box" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "[OK] 已安装 sing-box 到 $SBP_BIN_DIR/sing-box"
}

# 证书兜底（有 openssl 就生成；没有就先跳过，由业务决定是否强制）
ensure_tls_cert() {
  local dir="$SBP_ROOT"
  mkdir -p "$dir"
  if command -v openssl >/dev/null 2>&1; then
    [[ -f "$dir/private.key" ]] || openssl ecparam -genkey -name prime256v1 -out "$dir/private.key" >/dev/null 2>&1
    [[ -f "$dir/cert.pem"    ]] || openssl req -new -x509 -days 36500 -key "$dir/private.key" -out "$dir/cert.pem" -subj "/CN=www.tesla.com" >/dev/null 2>&1
  fi
}

# 标记哨兵
sbp_mark_deps_ok() {
  if sbp_core_ok; then
    mkdir -p "$(dirname "$SBP_DEPS_SENTINEL")" && : > "$SBP_DEPS_SENTINEL" || true
  fi
}

# 入口：装依赖 / 二进制回退
sbp_bootstrap() {
  [ "$EUID" -eq 0 ] || { echo "请以 root 运行（或 sudo）"; exit 1; }

  if [ "$SBP_SKIP_DEPS" = 1 ]; then
    echo "[INFO] 已跳过启动时依赖检查（SBP_SKIP_DEPS=1）"
    return 0
  fi

  # 已就绪则跳过
  if [ "$SBP_FORCE_DEPS" != 1 ] && sbp_core_ok && [ -f "$SBP_DEPS_SENTINEL" ] && [ "$SBP_BIN_ONLY" != 1 ]; then
    echo "依赖已安装"
    return 0
  fi

  # 强制二进制模式
  if [ "$SBP_BIN_ONLY" = 1 ]; then
    echo "[INFO] 二进制模式（SBP_BIN_ONLY=1）"
    install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
    ensure_tls_cert
    return 0
  fi

  # 包管理器优先
  if sbp_install_prereqs_pm; then
    sbp_mark_deps_ok
    return 0
  fi

  # 回退到二进制模式
  echo "[WARN] 包管理器依赖安装失败，切换到二进制模式"
  install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
  ensure_tls_cert
}
# ===== [END] SBP 引导模块 v2.2.0+ =====


# ===== 提前设默认，避免 set -u 早期引用未定义变量导致脚本直接退出 =====
SYSTEMD_SERVICE=${SYSTEMD_SERVICE:-sing-box.service}
BIN_PATH=${BIN_PATH:-/usr/local/bin/sing-box}
SB_DIR=${SB_DIR:-/opt/sing-box}
CONF_JSON=${CONF_JSON:-$SB_DIR/config.json}
DATA_DIR=${DATA_DIR:-$SB_DIR/data}
CERT_DIR=${CERT_DIR:-$SB_DIR/cert}
WGCF_DIR=${WGCF_DIR:-$SB_DIR/wgcf}
WEB_ROOT=${WEB_ROOT:-/var/www/sing-box-plus}
FIREWALL_RULES_FILE=${FIREWALL_RULES_FILE:-$SB_DIR/firewall.rules}

# 功能开关（保持稳定默认）
ENABLE_WARP=${ENABLE_WARP:-true}
ENABLE_VLESS_REALITY=${ENABLE_VLESS_REALITY:-true}
ENABLE_VLESS_GRPCR=${ENABLE_VLESS_GRPCR:-true}
ENABLE_TROJAN_REALITY=${ENABLE_TROJAN_REALITY:-true}
ENABLE_HYSTERIA2=${ENABLE_HYSTERIA2:-true}
ENABLE_VMESS_WS=${ENABLE_VMESS_WS:-true}
ENABLE_HY2_OBFS=${ENABLE_HY2_OBFS:-true}
ENABLE_SS2022=${ENABLE_SS2022:-true}
ENABLE_SS=${ENABLE_SS:-true}
ENABLE_TUIC=${ENABLE_TUIC:-true}
ENABLE_ANYTLS=${ENABLE_ANYTLS:-true}

# 常量
SCRIPT_NAME="Sing-Box-Plus 管理脚本"
SCRIPT_VERSION="v4.7.2"
REALITY_SERVER=${REALITY_SERVER:-www.tesla.com}
REALITY_SERVER_PORT=${REALITY_SERVER_PORT:-443}
GRPC_SERVICE=${GRPC_SERVICE:-grpc}
VMESS_WS_PATH=${VMESS_WS_PATH:-/vm}
REGION_TAG=${REGION_TAG:-🇯🇵日本}
WEB_DOMAIN=${WEB_DOMAIN:-}
CERT_EMAIL=${CERT_EMAIL:-}
SUB_TOKEN=${SUB_TOKEN:-}

# 兼容 sing-box 1.12.x 的旧 wireguard 出站
export ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=${ENABLE_DEPRECATED_WIREGUARD_OUTBOUND:-true}

# ===== 颜色 =====
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_RED="\033[31m";  C_GREEN="\033[32m"; C_YELLOW="\033[33m"
C_BLUE="\033[34m"; C_CYAN="\033[36m"; C_MAGENTA="\033[35m"
hr(){ printf "${C_DIM}=============================================================${C_RESET}\n"; }

# ===== 基础工具 =====
info(){ echo -e "[${C_CYAN}信息${C_RESET}] $*"; }
ok(){   echo -e "[${C_GREEN}成功${C_RESET}] $*"; }
warn(){ echo -e "[${C_YELLOW}警告${C_RESET}] $*"; }
err(){  echo -e "[${C_RED}错误${C_RESET}] $*" >&2; }
die(){  echo -e "[${C_RED}错误${C_RESET}] $*" >&2; exit 1; }

# --- 架构映射：uname -m -> 发行资产名 ---
arch_map() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l)       echo "armv7" ;;   # 上游无 armv6，回退 armv7
    i386|i686)    echo "386"  ;;
    *)            echo "amd64" ;;
  esac
}

# --- 依赖安装：兼容 apt / yum / dnf / apk / pacman / zypper ---
ensure_deps() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
  ((${#miss[@]}==0)) && return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${miss[@]}" || apt-get install -y --no-install-recommends "${miss[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${miss[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${miss[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${miss[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${miss[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "${miss[@]}"
  else
    err "无法自动安装依赖：${miss[*]}，请手动安装后重试"
    return 1
  fi
}

b64enc(){ base64 -w 0 2>/dev/null || base64; }
urlenc(){ # 纯 bash urlencode（不依赖 python）
  local s="$1" out="" c
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      ' ') out+="%20" ;;
      *) printf -v out "%s%%%02X" "$out" "'$c" ;;
    esac
  done
  printf "%s" "$out"
}

trim_spaces(){
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

flag_enabled(){
  case "${1:-}" in
    true|TRUE|1|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

set_all_protocols(){
  local v="${1:-true}"
  ENABLE_VLESS_REALITY="$v"
  ENABLE_VLESS_GRPCR="$v"
  ENABLE_TROJAN_REALITY="$v"
  ENABLE_HYSTERIA2="$v"
  ENABLE_VMESS_WS="$v"
  ENABLE_HY2_OBFS="$v"
  ENABLE_SS2022="$v"
  ENABLE_SS="$v"
  ENABLE_TUIC="$v"
  ENABLE_ANYTLS="$v"
}

ensure_any_protocol_enabled(){
  local enabled=0 v
  for v in ENABLE_VLESS_REALITY ENABLE_VLESS_GRPCR ENABLE_TROJAN_REALITY ENABLE_HYSTERIA2 ENABLE_VMESS_WS ENABLE_HY2_OBFS ENABLE_SS2022 ENABLE_SS ENABLE_TUIC ENABLE_ANYTLS; do
    flag_enabled "${!v:-false}" && enabled=1
  done
  if [[ "$enabled" != "1" ]]; then
    warn "未启用任何协议，已自动启用 VLESS Reality"
    ENABLE_VLESS_REALITY=true
  fi
}

rand_token64(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32 | tr -d '\n'
  else
    hexdump -v -n 32 -e '1/1 "%02x"' /dev/urandom
  fi
}

ensure_sub_token(){
  [[ -n "${SUB_TOKEN:-}" ]] || SUB_TOKEN="$(rand_token64)"
}

normalize_domain(){
  local d="$1"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  d="${d%.}"
  printf '%s' "$d"
}

safe_source_env(){ # 安全 source，忽略不存在文件
  local f="$1"; [[ -f "$f" ]] || return 1
  set +u; # 避免未定义变量报错
  # shellcheck disable=SC1090
  source "$f"
  set -u
}

get_ip4(){ # 多源获取公网 IPv4
  local ip
  ip=$(curl -4 -fsSL ipv4.icanhazip.com 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -4 -fsSL ip.sb 2>/dev/null || true)
  echo "${ip:-127.0.0.1}"
}

get_ip6(){ # 多源获取公网 IPv6（无 IPv6 则返回空）
  local ip
  ip=$(curl -6 -fsSL ipv6.icanhazip.com 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -6 -fsSL ifconfig.me 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -6 -fsSL ip.sb 2>/dev/null || true)
  echo "${ip:-}"
}

# 兼容旧调用：默认返回 IPv4
get_ip(){ get_ip4; }

# URI/分享链接里：IPv6 需要用 [addr] 包起来
fmt_host_for_uri(){
  local ip="$1"
  [[ "$ip" == *:* ]] && printf '[%s]' "$ip" || printf '%s' "$ip"
}

is_uuid(){ [[ "$1" =~ ^[0-9a-fA-F-]{36}$ ]]; }

ensure_dirs(){ mkdir -p "$SB_DIR" "$DATA_DIR" "$CERT_DIR" "$WGCF_DIR"; }

# ===== 端口（20 个互不重复） =====
PORTS=()
gen_port() {
  while :; do
    p=$(( ( RANDOM % 55536 ) + 10000 ))
    [[ $p -le 65535 ]] || continue
    [[ " ${PORTS[*]-} " != *" $p "* ]] && { PORTS+=("$p"); echo "$p"; return; }
  done
}
rand_ports_reset(){ PORTS=(); }

PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

save_ports(){
  mkdir -p "$SB_DIR"
  cat > "$SB_DIR/ports.env" <<EOF
PORT_VLESSR=$PORT_VLESSR
PORT_VLESS_GRPCR=$PORT_VLESS_GRPCR
PORT_TROJANR=$PORT_TROJANR
PORT_HY2=$PORT_HY2
PORT_VMESS_WS=$PORT_VMESS_WS
PORT_HY2_OBFS=$PORT_HY2_OBFS
PORT_SS2022=$PORT_SS2022
PORT_SS=$PORT_SS
PORT_TUIC=$PORT_TUIC
PORT_ANYTLS=$PORT_ANYTLS
PORT_VLESSR_W=$PORT_VLESSR_W
PORT_VLESS_GRPCR_W=$PORT_VLESS_GRPCR_W
PORT_TROJANR_W=$PORT_TROJANR_W
PORT_HY2_W=$PORT_HY2_W
PORT_VMESS_WS_W=$PORT_VMESS_WS_W
PORT_HY2_OBFS_W=$PORT_HY2_OBFS_W
PORT_SS2022_W=$PORT_SS2022_W
PORT_SS_W=$PORT_SS_W
PORT_TUIC_W=$PORT_TUIC_W
PORT_ANYTLS_W=$PORT_ANYTLS_W
EOF
}
load_ports(){ safe_source_env "$SB_DIR/ports.env" || return 1; }

save_all_ports(){
  rand_ports_reset
  for v in PORT_VLESSR PORT_VLESS_GRPCR PORT_TROJANR PORT_HY2 PORT_VMESS_WS PORT_HY2_OBFS PORT_SS2022 PORT_SS PORT_TUIC PORT_ANYTLS \
           PORT_VLESSR_W PORT_VLESS_GRPCR_W PORT_TROJANR_W PORT_HY2_W PORT_VMESS_WS_W PORT_HY2_OBFS_W PORT_SS2022_W PORT_SS_W PORT_TUIC_W PORT_ANYTLS_W; do
    [[ -n "${!v:-}" ]] && PORTS+=("${!v}")
  done
  [[ -z "${PORT_VLESSR:-}" ]] && PORT_VLESSR=$(gen_port)
  [[ -z "${PORT_VLESS_GRPCR:-}" ]] && PORT_VLESS_GRPCR=$(gen_port)
  [[ -z "${PORT_TROJANR:-}" ]] && PORT_TROJANR=$(gen_port)
  [[ -z "${PORT_HY2:-}" ]] && PORT_HY2=$(gen_port)
  [[ -z "${PORT_VMESS_WS:-}" ]] && PORT_VMESS_WS=$(gen_port)
  [[ -z "${PORT_HY2_OBFS:-}" ]] && PORT_HY2_OBFS=$(gen_port)
  [[ -z "${PORT_SS2022:-}" ]] && PORT_SS2022=$(gen_port)
  [[ -z "${PORT_SS:-}" ]] && PORT_SS=$(gen_port)
  [[ -z "${PORT_TUIC:-}" ]] && PORT_TUIC=$(gen_port)
  [[ -z "${PORT_ANYTLS:-}" ]] && PORT_ANYTLS=$(gen_port)
  [[ -z "${PORT_VLESSR_W:-}" ]] && PORT_VLESSR_W=$(gen_port)
  [[ -z "${PORT_VLESS_GRPCR_W:-}" ]] && PORT_VLESS_GRPCR_W=$(gen_port)
  [[ -z "${PORT_TROJANR_W:-}" ]] && PORT_TROJANR_W=$(gen_port)
  [[ -z "${PORT_HY2_W:-}" ]] && PORT_HY2_W=$(gen_port)
  [[ -z "${PORT_VMESS_WS_W:-}" ]] && PORT_VMESS_WS_W=$(gen_port)
  [[ -z "${PORT_HY2_OBFS_W:-}" ]] && PORT_HY2_OBFS_W=$(gen_port) || true
  [[ -z "${PORT_SS2022_W:-}" ]] && PORT_SS2022_W=$(gen_port)
  [[ -z "${PORT_SS_W:-}" ]] && PORT_SS_W=$(gen_port)
  [[ -z "${PORT_TUIC_W:-}" ]] && PORT_TUIC_W=$(gen_port)
  [[ -z "${PORT_ANYTLS_W:-}" ]] && PORT_ANYTLS_W=$(gen_port)
  save_ports
}

# ===== env / creds / warp =====
save_env_line(){ printf '%s=%q\n' "$1" "${!1:-}"; }
save_env(){
  mkdir -p "$SB_DIR"
  {
    save_env_line BIN_PATH
    save_env_line ENABLE_VLESS_REALITY
    save_env_line ENABLE_VLESS_GRPCR
    save_env_line ENABLE_TROJAN_REALITY
    save_env_line ENABLE_HYSTERIA2
    save_env_line ENABLE_VMESS_WS
    save_env_line ENABLE_HY2_OBFS
    save_env_line ENABLE_SS2022
    save_env_line ENABLE_SS
    save_env_line ENABLE_TUIC
    save_env_line ENABLE_ANYTLS
    save_env_line ENABLE_WARP
    save_env_line REALITY_SERVER
    save_env_line REALITY_SERVER_PORT
    save_env_line GRPC_SERVICE
    save_env_line VMESS_WS_PATH
    save_env_line REGION_TAG
    save_env_line WEB_DOMAIN
    save_env_line CERT_EMAIL
    save_env_line SUB_TOKEN
  } > "$SB_DIR/env.conf"
}
load_env(){ safe_source_env "$SB_DIR/env.conf" || true; }

save_creds(){
  mkdir -p "$SB_DIR"
  cat > "$SB_DIR/creds.env" <<EOF
UUID=$UUID
HY2_PWD=$HY2_PWD
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_SID=$REALITY_SID
HY2_PWD2=$HY2_PWD2
HY2_OBFS_PWD=$HY2_OBFS_PWD
SS2022_KEY=$SS2022_KEY
SS_PWD=$SS_PWD
TUIC_UUID=$TUIC_UUID
TUIC_PWD=$TUIC_PWD
ANYTLS_PWD=$ANYTLS_PWD
EOF
}
load_creds(){ safe_source_env "$SB_DIR/creds.env" || return 1; }

save_warp(){
  mkdir -p "$SB_DIR"
  cat > "$SB_DIR/warp.env" <<EOF
WARP_PRIVATE_KEY=$WARP_PRIVATE_KEY
WARP_PEER_PUBLIC_KEY=$WARP_PEER_PUBLIC_KEY
WARP_ENDPOINT_HOST=$WARP_ENDPOINT_HOST
WARP_ENDPOINT_PORT=$WARP_ENDPOINT_PORT
WARP_ADDRESS_V4=$WARP_ADDRESS_V4
WARP_ADDRESS_V6=$WARP_ADDRESS_V6
WARP_RESERVED_1=$WARP_RESERVED_1
WARP_RESERVED_2=$WARP_RESERVED_2
WARP_RESERVED_3=$WARP_RESERVED_3
EOF
}
load_warp(){ safe_source_env "$SB_DIR/warp.env" || return 1; }

# 生成 8 字节十六进制（16 个 hex 字符）
rand_hex8(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8 | tr -d "\n"
  else
    # 兜底：没有 openssl 时用 hexdump
    hexdump -v -n 8 -e '1/1 "%02x"' /dev/urandom
  fi
}
rand_b64_32(){ openssl rand -base64 32 | tr -d "\n"; }

gen_uuid(){
  local u=""
  if [[ -x "$BIN_PATH" ]]; then u=$("$BIN_PATH" generate uuid 2>/dev/null | head -n1); fi
  if [[ -z "$u" ]] && command -v uuidgen >/dev/null 2>&1; then u=$(uuidgen | head -n1); fi
  if [[ -z "$u" ]]; then u=$(cat /proc/sys/kernel/random/uuid | head -n1); fi
  printf '%s' "$u" | tr -d '\r\n'
}
gen_reality(){ "$BIN_PATH" generate reality-keypair; }

cert_fingerprint_sha256(){
  local cert="$1"
  openssl x509 -in "$cert" -fingerprint -sha256 -noout 2>/dev/null \
    | sed -E 's/^[^=]*=//;s/://g' | tr 'A-F' 'a-f' || true
}

mk_cert(){
  local tls_name="${WEB_DOMAIN:-$REALITY_SERVER}"
  local le_crt="" le_key="" crt="$CERT_DIR/fullchain.pem" key="$CERT_DIR/key.pem" marker="$CERT_DIR/.domain"
  TLS_SERVER_NAME="$tls_name"

  if [[ -n "${WEB_DOMAIN:-}" ]]; then
    le_crt="/etc/letsencrypt/live/${WEB_DOMAIN}/fullchain.pem"
    le_key="/etc/letsencrypt/live/${WEB_DOMAIN}/privkey.pem"
    if [[ -s "$le_crt" && -s "$le_key" ]]; then
      CRT_PATH="$le_crt"
      KEY_PATH="$le_key"
      CRT_SHA256="$(cert_fingerprint_sha256 "$CRT_PATH")"
      return 0
    fi
  fi

  mkdir -p "$CERT_DIR"
  if [[ ! -s "$crt" || ! -s "$key" || ! -s "$marker" || "$(cat "$marker" 2>/dev/null)" != "$tls_name" ]]; then
    rm -f "$crt" "$key"
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
      -keyout "$key" -out "$crt" -subj "/CN=$tls_name" \
      -addext "subjectAltName=DNS:$tls_name" >/dev/null 2>&1; then
      warn "生成自签证书失败，请检查 openssl 环境"
    fi
    printf '%s' "$tls_name" > "$marker"
  fi

  CRT_PATH="$crt"
  KEY_PATH="$key"
  CRT_SHA256="$(cert_fingerprint_sha256 "$CRT_PATH")"
}

ensure_creds(){
  [[ -z "${UUID:-}" ]] && UUID=$(gen_uuid)
  is_uuid "$UUID" || UUID=$(gen_uuid)
  [[ -z "${HY2_PWD:-}" ]] && HY2_PWD=$(rand_b64_32)
  if [[ -z "${REALITY_PRIV:-}" || -z "${REALITY_PUB:-}" || -z "${REALITY_SID:-}" ]]; then
    readarray -t RKP < <(gen_reality)
    REALITY_PRIV=$(printf "%s\n" "${RKP[@]}" | awk '/PrivateKey/{print $2}')
    REALITY_PUB=$(printf "%s\n" "${RKP[@]}" | awk '/PublicKey/{print $2}')
    REALITY_SID=$(rand_hex8)
  fi
  [[ -z "${HY2_PWD2:-}" ]] && HY2_PWD2=$(rand_b64_32)
  [[ -z "${HY2_OBFS_PWD:-}" ]] && HY2_OBFS_PWD=$(openssl rand -base64 16 | tr -d "\n")
  [[ -z "${SS2022_KEY:-}" ]] && SS2022_KEY=$(rand_b64_32)
  [[ -z "${SS_PWD:-}" ]] && SS_PWD=$(openssl rand -base64 24 | tr -d "=\n" | tr "+/" "-_")
  TUIC_UUID="$UUID"; TUIC_PWD="$UUID"
  [[ -z "${ANYTLS_PWD:-}" ]] && ANYTLS_PWD=$(rand_b64_32)
  save_creds
}

# ===== WARP（wgcf） =====
WGCF_BIN=/usr/local/bin/wgcf
install_wgcf_disabled(){
  [[ -x "$WGCF_BIN" ]] && return 0
  local GOA url tmp
  case "$(arch_map)" in
    amd64) GOA=amd64;; arm64) GOA=arm64;; armv7) GOA=armv7;; 386) GOA=386;; *) GOA=amd64;;
  esac
  url=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
        | jq -r ".assets[] | select(.name|test(\"linux_${GOA}$\")) | .browser_download_url" | head -n1)
  [[ -n "$url" ]] || { warn "获取 wgcf 下载地址失败"; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/wgcf"
  install -m0755 "$tmp/wgcf" "$WGCF_BIN"
  rm -rf "$tmp"
}

# —— Base64 清理 + 补齐：去掉引号/空白，长度 %4==2 补“==”，%4==3 补“=” ——
pad_b64(){
  local s="${1:-}"
  # 去引号/空格/回车
  s="$(printf '%s' "$s" | tr -d '\r\n\" ')"
  # 去掉已有尾随 =，按需重加
  s="${s%%=*}"
  local rem=$(( ${#s} % 4 ))
  if   (( rem == 2 )); then s="${s}=="
  elif (( rem == 3 )); then s="${s}="
  fi
  printf '%s' "$s"
}


# ===== WARP（官方 warp-cli，proxy 模式）一键安装/修复 =====
# 说明：
# - 本脚本强制使用官方 cloudflare-warp (warp-cli) 提供本地 SOCKS5 (默认 127.0.0.1:40000)
# - sing-box 的 tag=warp 出站固定走该 SOCKS5
WARP_SOCKS_HOST="${WARP_SOCKS_HOST:-127.0.0.1}"
WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-40000}"

install_warpcli(){
  command -v warp-cli >/dev/null 2>&1 && return 0

  if command -v apt-get >/dev/null 2>&1; then
    info "安装 cloudflare-warp (Debian/Ubuntu)..."
    apt-get update -y
    apt-get install -y curl gpg lsb-release ca-certificates >/dev/null 2>&1 || true
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main"       > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -y
    apt-get install -y cloudflare-warp
  elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    info "安装 cloudflare-warp (CentOS/RHEL)..."
    curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y cloudflare-warp
    else
      yum install -y cloudflare-warp
    fi
  else
    err "未识别的包管理器，无法自动安装 cloudflare-warp"
    return 1
  fi

  command -v warp-cli >/dev/null 2>&1
}

ensure_warpcli_proxy(){
  [[ "${ENABLE_WARP:-true}" == "true" ]] || return 0

  install_warpcli || return 1

  systemctl enable --now warp-svc >/dev/null 2>&1 || true

  # 已注册则跳过；未注册则自动同意条款
  if ! warp-cli registration show >/dev/null 2>&1; then
    info "正在初始化 Cloudflare WARP"

    # warp-cli 强制检测 TTY，非 TTY 拒绝输入，需模拟真实终端注入 y
    # 优先级：python3 pty（最可靠）→ expect → 安装 python3 兜底
    _warp_reg_ok=0

    if command -v python3 >/dev/null 2>&1; then
      python3 - <<'PYEOF' 2>/dev/null && _warp_reg_ok=1 || true
import pty, os, time, select, sys

def run():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("warp-cli", ["warp-cli", "registration", "new"])
    else:
        answered = False
        for _ in range(30):
            r, _, _ = select.select([fd], [], [], 1)
            if r:
                try:
                    data = os.read(fd, 4096).decode(errors="ignore")
                except OSError:
                    break
                if not answered and ("y/N" in data or "y/n" in data):
                    time.sleep(0.2)
                    os.write(fd, b"y\n")
                    answered = True
                if "Success" in data:
                    sys.exit(0)
            try:
                ret = os.waitpid(pid, os.WNOHANG)
                if ret[0] != 0:
                    break
            except ChildProcessError:
                break
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass
        sys.exit(1)

run()
PYEOF

    elif command -v expect >/dev/null 2>&1; then
      expect -c '
        spawn warp-cli registration new
        expect -re {[yY]/[nN]}
        send "y\r"
        expect eof
      ' >/dev/null 2>&1 && _warp_reg_ok=1 || true

    else
      # 尝试安装 python3（兜底）
      warn "未找到 python3/expect，尝试安装 python3..."
      if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y python3 >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 >/dev/null 2>&1 || true
      elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 >/dev/null 2>&1 || true
      elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm python >/dev/null 2>&1 || true
      elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install python3 >/dev/null 2>&1 || true
      fi

      if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PYEOF' 2>/dev/null && _warp_reg_ok=1 || true
import pty, os, time, select, sys

def run():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("warp-cli", ["warp-cli", "registration", "new"])
    else:
        answered = False
        for _ in range(30):
            r, _, _ = select.select([fd], [], [], 1)
            if r:
                try:
                    data = os.read(fd, 4096).decode(errors="ignore")
                except OSError:
                    break
                if not answered and ("y/N" in data or "y/n" in data):
                    time.sleep(0.2)
                    os.write(fd, b"y\n")
                    answered = True
                if "Success" in data:
                    sys.exit(0)
            try:
                ret = os.waitpid(pid, os.WNOHANG)
                if ret[0] != 0:
                    break
            except ChildProcessError:
                break
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass
        sys.exit(1)

run()
PYEOF
      else
        err "无法自动完成 WARP 注册（缺少 python3/expect），请手动运行：warp-cli registration new"
        return 1
      fi
    fi

    sleep 2
    if ! warp-cli registration show >/dev/null 2>&1; then
      err "WARP 注册失败，请手动运行：warp-cli registration new"; return 1
    fi
  fi

  # proxy 模式：不改系统默认路由
  warp-cli mode proxy >/dev/null 2>&1 || true

  # 连接
  warp-cli connect >/dev/null 2>&1 || return 1

  # 等待 socks 端口监听
  for i in {1..12}; do
    if ss -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b" || netstat -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b"; then
      break
    fi
    sleep 1
  done

  if !( ss -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b" || netstat -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b" ); then
    err "WARP SOCKS5 端口 ${WARP_SOCKS_PORT} 未监听（warp-svc/warp-cli 可能未正常工作）"
    systemctl status warp-svc --no-pager | head -80 || true
    journalctl -u warp-svc -n 120 --no-pager || true
    return 1
  fi

  # 真正测试 warp=on
  if ! curl -fsSL --proxy "socks5://${WARP_SOCKS_HOST}:${WARP_SOCKS_PORT}" https://cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    err "WARP 代理测试失败：未检测到 warp=on"
    warp-cli status || true
    return 1
  fi

  ok "WARP proxy 已就绪：socks5://${WARP_SOCKS_HOST}:${WARP_SOCKS_PORT}"
  return 0
}

# ===== WARP（wgcf）配置生成/修复（已废弃/不再默认使用，保留旧代码以兼容历史） =====

ensure_wgcf_profile(){
  [[ "${ENABLE_WARP:-true}" == "true" ]] || return 0

  # 先尝试读取旧 env，并做一次规范化补齐
  if load_warp 2>/dev/null; then
    WARP_PRIVATE_KEY="$(pad_b64 "${WARP_PRIVATE_KEY:-}")"
    WARP_PEER_PUBLIC_KEY="$(pad_b64 "${WARP_PEER_PUBLIC_KEY:-}")"
    # 允许之前没写 reserved，给默认 0
    : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"
    save_warp
    # 如果关键字段都在，就直接用旧的（已经补齐），无需重建
    if [[ -n "$WARP_PRIVATE_KEY" && -n "$WARP_PEER_PUBLIC_KEY" && -n "${WARP_ENDPOINT_HOST:-}" && -n "${WARP_ENDPOINT_PORT:-}" ]]; then
      return 0
    fi
  fi

  # 走到这里说明旧 env 不完整；开始用 wgcf 重建
  install_wgcf_disabled || { warn "wgcf 安装失败，禁用 WARP 节点"; ENABLE_WARP=false; save_env; return 0; }

  local wd="$SB_DIR/wgcf"; mkdir -p "$wd"
  if [[ ! -f "$wd/wgcf-account.toml" ]]; then
    "$WGCF_BIN" register --accept-tos --config "$wd/wgcf-account.toml" >/dev/null
  fi
  "$WGCF_BIN" generate --config "$wd/wgcf-account.toml" --profile "$wd/wgcf-profile.conf" >/dev/null

  local prof="$wd/wgcf-profile.conf"
  # 提取并规范化
  WARP_PRIVATE_KEY="$(pad_b64 "$(awk -F'= *' '/^PrivateKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"
  WARP_PEER_PUBLIC_KEY="$(pad_b64 "$(awk -F'= *' '/^PublicKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"

  # Endpoint 可能是域名或 [IPv6]:port
  local ep host port
  ep="$(awk -F'= *' '/^Endpoint/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  if [[ "$ep" =~ ^\[(.+)\]:(.+)$ ]]; then host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"; else host="${ep%:*}"; port="${ep##*:}"; fi
  WARP_ENDPOINT_HOST="$host"
  WARP_ENDPOINT_PORT="$port"

  # 内网地址与 reserved
  local ad rs
  ad="$(awk -F'= *' '/^Address/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_ADDRESS_V4="${ad%%,*}"
  WARP_ADDRESS_V6="${ad##*,}"
  rs="$(awk -F'= *' '/^Reserved/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_RESERVED_1="${rs%%,*}"; rs="${rs#*,}"
  WARP_RESERVED_2="${rs%%,*}"; WARP_RESERVED_3="${rs##*,}"
  : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"

  save_warp
}

# ===== 依赖与安装 =====
install_deps(){
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y ca-certificates curl wget jq tar iproute2 openssl coreutils uuid-runtime >/dev/null 2>&1 || true
}

install_web_deps(){
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y nginx certbot >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx certbot >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release >/dev/null 2>&1 || true
    yum install -y nginx certbot >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache nginx certbot >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed nginx certbot >/dev/null 2>&1 || true
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install nginx certbot >/dev/null 2>&1 || true
  fi
}

nginx_includes_sites_enabled(){
  grep -RqsE 'include[[:space:]]+[^;]*sites-enabled' /etc/nginx/nginx.conf /etc/nginx/conf.d 2>/dev/null
}

nginx_conf_path(){
  if [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]] && nginx_includes_sites_enabled; then
    printf '%s' /etc/nginx/sites-available/sing-box-plus.conf
  else
    mkdir -p /etc/nginx/conf.d
    printf '%s' /etc/nginx/conf.d/sing-box-plus.conf
  fi
}

enable_nginx_conf(){
  local conf="$1"
  if [[ "$conf" == /etc/nginx/sites-available/* && -d /etc/nginx/sites-enabled ]]; then
    ln -sf "$conf" /etc/nginx/sites-enabled/sing-box-plus.conf
  fi
}

disable_conflicting_sbp_domain_configs(){
  [[ -n "${WEB_DOMAIN:-}" ]] || return 0
  local d f bak ts current found=0
  current="$(nginx_conf_path)"
  ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo manual)"
  for d in /etc/nginx/conf.d /etc/nginx/sites-enabled; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" && ( -f "$f" || -L "$f" ) ]] || continue
      [[ "$f" == *.disabled-by-sing-box-plus.* ]] && continue
      [[ "$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")" == "$(readlink -f "$current" 2>/dev/null || printf '%s' "$current")" ]] && continue
      grep -qE '^[[:space:]]*server_name[[:space:]]' "$f" 2>/dev/null || continue
      grep -qF "$WEB_DOMAIN" "$f" 2>/dev/null || continue
      grep -qE 'checkPort|listen[[:space:]][^;]*443|ssl_certificate(_key)?[[:space:]]+/opt/sing-box/certs?/' "$f" 2>/dev/null || continue
      bak="${f}.disabled-by-sing-box-plus.${ts}"
      if mv "$f" "$bak" 2>/dev/null; then
        warn "已隔离同域名旧 nginx 配置：$f -> $bak"
        found=1
      fi
    done < <(grep -RIl "server_name" "$d" 2>/dev/null || true)
  done
  [[ "$found" == "1" ]]
}

disable_stale_sbp_nginx_configs(){
  local d f bak ts found=0
  ts="$(date +%Y%m%d%H%M%S 2>/dev/null || echo manual)"
  for d in /etc/nginx/conf.d /etc/nginx/sites-enabled; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" && ( -f "$f" || -L "$f" ) ]] || continue
      [[ "$f" == *.disabled-by-sing-box-plus.* ]] && continue
      bak="${f}.disabled-by-sing-box-plus.${ts}"
      if mv "$f" "$bak" 2>/dev/null; then
        warn "已隔离旧 nginx 配置：$f -> $bak"
        found=1
      fi
    done < <(grep -RIlE 'ssl_certificate(_key)?[[:space:]]+/opt/sing-box/certs?/' "$d" 2>/dev/null || true)
  done
  [[ "$found" == "1" ]]
}

write_demo_site(){
  local site_url="${WEB_DOMAIN:-example.com}"
  mkdir -p "$WEB_ROOT/assets" "$WEB_ROOT/about" "$WEB_ROOT/status" "$WEB_ROOT/contact" "$WEB_ROOT/sub" "$WEB_ROOT/.well-known/acme-challenge"

  cat > "$WEB_ROOT/assets/site.css" <<'CSS'
:root {
  color-scheme: light;
  --bg: #f6f8fb;
  --surface: #ffffff;
  --ink: #172033;
  --muted: #5d6b7d;
  --line: #d9e1eb;
  --accent: #176b5d;
  --accent-2: #2f5f9f;
  --warn: #b7791f;
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; background: var(--bg); color: var(--ink); }
a { color: inherit; text-decoration: none; }
.shell { width: min(1120px, calc(100% - 40px)); margin: 0 auto; }
.site-header { display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 24px 0; border-bottom: 1px solid var(--line); }
.brand { display: flex; align-items: center; gap: 10px; font-weight: 800; letter-spacing: .04em; }
.mark { width: 30px; height: 30px; border-radius: 7px; background: linear-gradient(135deg, var(--accent), var(--accent-2)); display: inline-block; }
.nav { display: flex; gap: 22px; color: var(--muted); font-size: 14px; }
.hero { display: grid; grid-template-columns: minmax(0, 1.05fr) minmax(320px, .95fr); gap: 48px; align-items: center; padding: 70px 0 34px; }
.eyebrow { color: var(--accent); font-weight: 800; font-size: 13px; text-transform: uppercase; letter-spacing: .08em; }
h1 { margin: 14px 0 0; font-size: clamp(42px, 6vw, 76px); line-height: .96; letter-spacing: 0; }
.lead { margin: 24px 0 0; color: var(--muted); font-size: 18px; line-height: 1.7; max-width: 650px; }
.actions { margin-top: 30px; display: flex; gap: 12px; flex-wrap: wrap; }
.button { display: inline-flex; align-items: center; justify-content: center; min-height: 44px; border-radius: 8px; padding: 0 18px; font-weight: 750; background: #152034; color: #fff; }
.button.secondary { background: #e6edf3; color: #1d2735; }
.panel, .card { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; box-shadow: 0 18px 60px rgba(23, 32, 51, .08); }
.panel { padding: 24px; }
.panel-title { margin: 0 0 8px; font-size: 15px; color: var(--muted); }
.status-row { display: grid; grid-template-columns: 1fr auto; gap: 12px; padding: 17px 0; border-bottom: 1px solid #edf1f6; }
.status-row:last-child { border-bottom: 0; }
.label { color: var(--muted); }
.value { font-weight: 800; color: var(--ink); }
.ok { color: var(--accent); }
.section { padding: 54px 0; }
.section-head { display: flex; justify-content: space-between; align-items: end; gap: 24px; margin-bottom: 18px; }
.section h2 { margin: 0; font-size: clamp(26px, 4vw, 40px); line-height: 1.05; }
.section p { color: var(--muted); line-height: 1.65; }
.grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 18px; }
.card { padding: 22px; box-shadow: none; }
.card h3 { margin: 0 0 10px; font-size: 18px; }
.card p { margin: 0; }
.split { display: grid; grid-template-columns: minmax(0, .9fr) minmax(0, 1.1fr); gap: 28px; align-items: start; }
.list { display: grid; gap: 12px; margin: 0; padding: 0; list-style: none; }
.list li { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 16px 18px; }
.table { width: 100%; border-collapse: collapse; background: var(--surface); border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.table th, .table td { padding: 14px 16px; border-bottom: 1px solid #edf1f6; text-align: left; }
.table th { color: var(--muted); font-size: 13px; font-weight: 750; }
.table tr:last-child td { border-bottom: 0; }
.footer { margin-top: 42px; padding: 28px 0 38px; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; display: flex; justify-content: space-between; gap: 16px; }
@media (max-width: 820px) {
  .site-header, .hero, .split, .section-head, .footer { display: block; }
  .nav { margin-top: 14px; flex-wrap: wrap; }
  .hero { padding-top: 46px; }
  .panel { margin-top: 28px; }
  .grid { grid-template-columns: 1fr; }
}
CSS

  cat > "$WEB_ROOT/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="14" fill="#176b5d"/>
  <path d="M17 41 31 14h16L33 41z" fill="#ffffff"/>
  <path d="M21 50h26" stroke="#ffffff" stroke-width="6" stroke-linecap="round"/>
</svg>
SVG

  cat > "$WEB_ROOT/site.webmanifest" <<'JSON'
{"name":"Nova Grid","short_name":"Nova Grid","start_url":"/","display":"standalone","background_color":"#f6f8fb","theme_color":"#176b5d","icons":[{"src":"/favicon.svg","sizes":"any","type":"image/svg+xml"}]}
JSON

  cat > "$WEB_ROOT/robots.txt" <<EOF
User-agent: *
Allow: /
Disallow: /sub/
Disallow: /proxy/

Sitemap: https://${site_url}/sitemap.xml
EOF

  cat > "$WEB_ROOT/sitemap.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${site_url}/</loc></url>
  <url><loc>https://${site_url}/about/</loc></url>
  <url><loc>https://${site_url}/status/</loc></url>
  <url><loc>https://${site_url}/contact/</loc></url>
</urlset>
EOF

  cat > "$WEB_ROOT/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Nova Grid</title>
  <meta name="description" content="Operations workspace for distributed energy teams.">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="manifest" href="/site.webmanifest">
  <link rel="stylesheet" href="/assets/site.css">
</head>
<body>
  <div class="shell">
    <header class="site-header">
      <a class="brand" href="/"><span class="mark"></span><span>NOVA GRID</span></a>
      <nav class="nav"><a href="/about/">Platform</a><a href="/status/">Status</a><a href="/contact/">Contact</a></nav>
    </header>
    <main class="hero">
      <section>
        <div class="eyebrow">Operations workspace</div>
        <h1>Live operations for distributed energy teams.</h1>
        <p class="lead">Track sites, capacity, dispatch windows, and service health from a quiet command center built for daily operations.</p>
        <div class="actions">
          <a class="button" href="/status/">View Status</a>
          <a class="button secondary" href="/about/">Explore Platform</a>
        </div>
      </section>
      <aside class="panel">
        <p class="panel-title">Network overview</p>
        <div class="status-row"><span class="label">Managed Sites</span><span class="value">128</span></div>
        <div class="status-row"><span class="label">Available Capacity</span><span class="value">94.6%</span></div>
        <div class="status-row"><span class="label">Dispatch Readiness</span><span class="value ok">Ready</span></div>
        <div class="status-row"><span class="label">Service Window</span><span class="value">02:00 UTC</span></div>
      </aside>
    </main>
    <section class="section">
      <div class="section-head">
        <h2>Built for repeatable control-room routines.</h2>
        <p>Clear daily views keep operators focused on availability, readiness, and follow-up work.</p>
      </div>
      <div class="grid">
        <article class="card"><h3>Site Health</h3><p>Monitor availability, incident states, and operator actions across active regions.</p></article>
        <article class="card"><h3>Capacity Planning</h3><p>Compare forecast demand with reserve margins before dispatch windows open.</p></article>
        <article class="card"><h3>Operations Log</h3><p>Review changes, alerts, and service notes from a single operational timeline.</p></article>
      </div>
    </section>
    <footer class="footer"><span>Nova Grid Operations</span><span>Regional systems desk</span></footer>
  </div>
</body>
</html>
HTML

  cat > "$WEB_ROOT/about/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Platform | Nova Grid</title>
  <meta name="description" content="Regional operations tools for distributed energy portfolios.">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/assets/site.css">
</head>
<body>
  <div class="shell">
    <header class="site-header">
      <a class="brand" href="/"><span class="mark"></span><span>NOVA GRID</span></a>
      <nav class="nav"><a href="/about/">Platform</a><a href="/status/">Status</a><a href="/contact/">Contact</a></nav>
    </header>
    <main class="section split">
      <section>
        <div class="eyebrow">Platform</div>
        <h1>Regional visibility without busywork.</h1>
        <p class="lead">Nova Grid brings asset status, dispatch notes, and maintenance follow-ups into one consistent operating view.</p>
      </section>
      <ul class="list">
        <li><strong>Daily readiness</strong><br>Confirm availability and exceptions before handover windows.</li>
        <li><strong>Event tracking</strong><br>Keep incident updates aligned with site, region, and owner context.</li>
        <li><strong>Capacity review</strong><br>Compare planned dispatch with current reserve and maintenance states.</li>
      </ul>
    </main>
    <footer class="footer"><span>Nova Grid Operations</span><span><a href="/contact/">Contact</a></span></footer>
  </div>
</body>
</html>
HTML

  cat > "$WEB_ROOT/status/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Status | Nova Grid</title>
  <meta name="description" content="Current service status for Nova Grid operations.">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/assets/site.css">
</head>
<body>
  <div class="shell">
    <header class="site-header">
      <a class="brand" href="/"><span class="mark"></span><span>NOVA GRID</span></a>
      <nav class="nav"><a href="/about/">Platform</a><a href="/status/">Status</a><a href="/contact/">Contact</a></nav>
    </header>
    <main class="section">
      <div class="section-head">
        <div>
          <div class="eyebrow">Status</div>
          <h1>All core systems operational.</h1>
        </div>
        <p>Last reviewed during the current operating window.</p>
      </div>
      <table class="table">
        <thead><tr><th>Service</th><th>Region</th><th>State</th></tr></thead>
        <tbody>
          <tr><td>Operations Portal</td><td>Asia Pacific</td><td class="ok">Operational</td></tr>
          <tr><td>Telemetry Ingest</td><td>Asia Pacific</td><td class="ok">Operational</td></tr>
          <tr><td>Dispatch Reports</td><td>Global</td><td class="ok">Operational</td></tr>
          <tr><td>Notification Queue</td><td>Global</td><td class="ok">Operational</td></tr>
        </tbody>
      </table>
    </main>
    <footer class="footer"><span>Nova Grid Operations</span><span><a href="/">Home</a></span></footer>
  </div>
</body>
</html>
HTML

  cat > "$WEB_ROOT/contact/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Contact | Nova Grid</title>
  <meta name="description" content="Contact details for Nova Grid operations.">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/assets/site.css">
</head>
<body>
  <div class="shell">
    <header class="site-header">
      <a class="brand" href="/"><span class="mark"></span><span>NOVA GRID</span></a>
      <nav class="nav"><a href="/about/">Platform</a><a href="/status/">Status</a><a href="/contact/">Contact</a></nav>
    </header>
    <main class="section split">
      <section>
        <div class="eyebrow">Contact</div>
        <h1>Operations support for active portfolios.</h1>
        <p class="lead">For service requests, planned maintenance, and portfolio updates, contact the regional operations desk.</p>
      </section>
      <div class="panel">
        <div class="status-row"><span class="label">Desk</span><span class="value">APAC Operations</span></div>
        <div class="status-row"><span class="label">Hours</span><span class="value">24 / 7</span></div>
        <div class="status-row"><span class="label">Response</span><span class="value">Priority based</span></div>
        <div class="status-row"><span class="label">Reference</span><span class="value">NOVA-OPS</span></div>
      </div>
    </main>
    <footer class="footer"><span>Nova Grid Operations</span><span><a href="/status/">Service status</a></span></footer>
  </div>
</body>
</html>
HTML

  cat > "$WEB_ROOT/404.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Page Not Found | Nova Grid</title>
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/assets/site.css">
</head>
<body>
  <div class="shell">
    <header class="site-header">
      <a class="brand" href="/"><span class="mark"></span><span>NOVA GRID</span></a>
      <nav class="nav"><a href="/about/">Platform</a><a href="/status/">Status</a><a href="/contact/">Contact</a></nav>
    </header>
    <main class="section">
      <div class="eyebrow">404</div>
      <h1>Page not found.</h1>
      <p class="lead">The requested page is not available. Return to the operations overview or check service status.</p>
      <div class="actions"><a class="button" href="/">Home</a><a class="button secondary" href="/status/">Status</a></div>
    </main>
  </div>
</body>
</html>
HTML
}

write_nginx_config(){
  [[ -n "${WEB_DOMAIN:-}" ]] || return 0
  ensure_sub_token
  local conf le_crt le_key
  conf="$(nginx_conf_path)"
  le_crt="/etc/letsencrypt/live/${WEB_DOMAIN}/fullchain.pem"
  le_key="/etc/letsencrypt/live/${WEB_DOMAIN}/privkey.pem"
  mkdir -p /etc/nginx/sing-box-plus.locations

  if [[ -s "$le_crt" && -s "$le_key" ]]; then
    cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${WEB_DOMAIN};
    root ${WEB_ROOT};
    error_page 404 /404.html;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${WEB_DOMAIN};
    root ${WEB_ROOT};
    index index.html;
    error_page 404 /404.html;

    ssl_certificate ${le_crt};
    ssl_certificate_key ${le_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    include /etc/nginx/sing-box-plus.locations/*.conf;

    location = /sub/${SUB_TOKEN} {
        access_log off;
        limit_except GET { deny all; }
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        try_files /sub/${SUB_TOKEN} =404;
    }

    location ^~ /sub/ {
        access_log off;
        return 404;
    }

    location ^~ /assets/ {
        expires 1h;
        add_header Cache-Control "public, max-age=3600" always;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  else
    cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${WEB_DOMAIN};
    root ${WEB_ROOT};
    index index.html;
    error_page 404 /404.html;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
    }

    location = /sub/${SUB_TOKEN} {
        access_log off;
        limit_except GET { deny all; }
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        try_files /sub/${SUB_TOKEN} =404;
    }

    location ^~ /sub/ {
        access_log off;
        return 404;
    }

    location ^~ /assets/ {
        expires 1h;
        add_header Cache-Control "public, max-age=3600" always;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  fi

  enable_nginx_conf "$conf"
  disable_conflicting_sbp_domain_configs || true
}

reload_nginx(){
  local out
  command -v nginx >/dev/null 2>&1 || { warn "nginx 未安装，已跳过 Web 站点配置"; return 1; }
  if ! out="$(nginx -t 2>&1)"; then
    warn "nginx 配置检查失败："
    printf '%s\n' "$out" >&2
    if disable_stale_sbp_nginx_configs; then
      if ! out="$(nginx -t 2>&1)"; then
        warn "隔离旧配置后 nginx 仍未通过检查："
        printf '%s\n' "$out" >&2
        return 1
      fi
    else
      return 1
    fi
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now nginx >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
  else
    service nginx reload >/dev/null 2>&1 || service nginx restart >/dev/null 2>&1 || true
  fi
}

disable_stale_cf_origin_443_rules(){
  local chain family handle
  if command -v iptables >/dev/null 2>&1; then
    for chain in CF_ORIGIN_VJ CF_ORIGIN_443; do
      if iptables -C INPUT -p tcp --dport 443 -j "$chain" 2>/dev/null; then
        while iptables -D INPUT -p tcp --dport 443 -j "$chain" 2>/dev/null; do :; done
        warn "已移除旧 Cloudflare-only 443 防火墙规则：${chain}"
      fi
    done
  fi

  if command -v nft >/dev/null 2>&1; then
    for family in ip ip6; do
      for chain in CF_ORIGIN_VJ CF_ORIGIN_443; do
        while :; do
          handle="$(nft -a list chain "$family" filter INPUT 2>/dev/null \
            | awk -v c="$chain" '$0 ~ /dport[[:space:]]+443/ && $0 ~ ("jump[[:space:]]+" c) {for (i=1; i<=NF; i++) if ($i == "handle") print $(i+1)}' \
            | head -n1)"
          [[ -n "$handle" ]] || break
          nft delete rule "$family" filter INPUT handle "$handle" 2>/dev/null || break
          warn "已移除旧 nftables Cloudflare-only 443 规则：${family}/${chain}"
        done
        nft delete chain "$family" filter "$chain" 2>/dev/null || true
      done
    done
  fi
}

open_web_firewall(){
  local r p
  disable_stale_cf_origin_443_rules
  for r in 80/tcp 443/tcp; do
    p="${r%/*}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q -E "active|活跃"; then
      ufw allow "$r" >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="$r" >/dev/null 2>&1 || true
    else
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      fi
    fi
  done
  command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 || true
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
}

request_certificate(){
  [[ -n "${WEB_DOMAIN:-}" ]] || return 0
  command -v certbot >/dev/null 2>&1 || { warn "certbot 未安装，订阅站点暂时使用 HTTP"; return 0; }
  local args=(certonly --webroot -w "$WEB_ROOT" -d "$WEB_DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
  if [[ -n "${CERT_EMAIL:-}" ]]; then
    args+=(--email "$CERT_EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  certbot "${args[@]}" >/dev/null 2>&1 || {
    warn "证书申请失败，请确认域名 A/AAAA 记录已指向本机且 80 端口可访问"
    return 0
  }
  ok "证书已申请/续期：${WEB_DOMAIN}"
}

install_certbot_deploy_hook(){
  command -v certbot >/dev/null 2>&1 || return 0
  local hook_dir="/etc/letsencrypt/renewal-hooks/deploy" hook
  hook="$hook_dir/90-sing-box-plus-reload.sh"
  mkdir -p "$hook_dir"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
set +e
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
systemctl restart ${SYSTEMD_SERVICE} >/dev/null 2>&1 || true
EOF
  chmod 0755 "$hook"
}

setup_web(){
  [[ -n "${WEB_DOMAIN:-}" ]] || return 0
  WEB_DOMAIN="$(normalize_domain "$WEB_DOMAIN")"
  ensure_sub_token
  info "配置 Web 伪装站点与订阅入口：${WEB_DOMAIN}"
  install_web_deps
  write_demo_site
  write_nginx_config
  open_web_firewall
  reload_nginx || true
  request_certificate
  install_certbot_deploy_hook
  open_web_firewall
  write_nginx_config
  reload_nginx || true
  save_env
}

# ===== 安装 / 更新 sing-box（GitHub Releases）=====
install_singbox() {

  # 已安装则直接返回
  if command -v "$BIN_PATH" >/dev/null 2>&1; then
    info "检测到 sing-box: $("$BIN_PATH" version | head -n1)"
    return 0
  fi

  # 依赖
  ensure_deps curl jq tar || return 1
  command -v xz >/dev/null 2>&1 || ensure_deps xz-utils >/dev/null 2>&1 || true
  command -v unzip >/dev/null 2>&1 || ensure_deps unzip   >/dev/null 2>&1 || true

  local repo="SagerNet/sing-box"
  local tag="${SINGBOX_TAG:-v1.13.7}"   # 允许用环境变量固定版本，如 v1.13.7
  local arch; arch="$(arch_map)"
  local api url tmp pkg re rel_url

  info "下载 sing-box (${arch}) ..."

  # 取 release JSON
  if [[ "$tag" = "latest" ]]; then
    rel_url="https://api.github.com/repos/${repo}/releases/latest"
  else
    rel_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  fi

  # 资产名匹配：兼容 tar.gz / tar.xz / zip
  # 典型名称：sing-box-1.12.7-linux-amd64.tar.gz
  re="^sing-box-.*-linux-${arch}\\.(tar\\.(gz|xz)|zip)$"

  # 先在目标 release 里找；找不到再从所有 releases 里兜底
  url="$(curl -fsSL "$rel_url" | jq -r --arg re "$re" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)"
  if [[ -z "$url" ]]; then
    url="$(curl -fsSL "https://api.github.com/repos/${repo}/releases" \
           | jq -r --arg re "$re" '[ .[] | .assets[] | select(.name | test($re)) | .browser_download_url ][0]')"
  fi
  [[ -n "$url" ]] || { err "下载 sing-box 失败：未匹配到发行包（arch=${arch} tag=${tag})"; return 1; }


  tmp="$(mktemp -d)"; pkg="${tmp}/pkg"
  if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 15 -o "$pkg" "$url"; then
    rm -rf "$tmp"; err "下载 sing-box 失败"; return 1
  fi

  # 解压
  if echo "$url" | grep -qE '\.tar\.gz$|\.tgz$'; then
    tar -xzf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.tar\.xz$'; then
    tar -xJf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.zip$'; then
    unzip -q "$pkg" -d "$tmp"
  else
    rm -rf "$tmp"; err "未知包格式：$url"; return 1
  fi

  # 找到二进制并安装
  local bin
  bin="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  [[ -n "$bin" ]] || { rm -rf "$tmp"; err "解压失败：未找到 sing-box 可执行文件"; return 1; }

  install -m 0755 "$bin" "$BIN_PATH"
  rm -rf "$tmp"
  info "安装完成：$("$BIN_PATH" version | head -n1)"
}

# ===== systemd =====
write_systemd(){ cat > "/etc/systemd/system/${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Sing-Box Plus
After=network-online.target warp-svc.service
Wants=network-online.target warp-svc.service
Requires=network-online.target

[Service]
Type=simple
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
ExecStart=${BIN_PATH} run -c ${CONF_JSON} -D ${DATA_DIR}
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
}

# ===== 写 config.json（使用你提供的稳定配置逻辑） =====
write_config(){
  ensure_dirs; load_env || true; load_creds || true; load_ports || true
  [[ -n "${WEB_DOMAIN:-}" ]] && WEB_DOMAIN="$(normalize_domain "$WEB_DOMAIN")"
  ensure_any_protocol_enabled
  ensure_creds; save_all_ports; mk_cert
  flag_enabled "$ENABLE_WARP" && ensure_warpcli_proxy

  local CRT="${CRT_PATH:-$CERT_DIR/fullchain.pem}" KEY="${KEY_PATH:-$CERT_DIR/key.pem}" tmp="${CONF_JSON}.tmp.$$"
  if ! jq -n \
  --arg RS "$REALITY_SERVER" --argjson RSP "${REALITY_SERVER_PORT:-443}" --arg UID "$UUID" \
  --arg WSHOST "$WARP_SOCKS_HOST" --argjson WSPORT "$WARP_SOCKS_PORT" \
  --arg RPR "$REALITY_PRIV" --arg RPB "$REALITY_PUB" --arg SID "$REALITY_SID" \
  --arg HY2 "$HY2_PWD" --arg HY22 "$HY2_PWD2" --arg HY2O "$HY2_OBFS_PWD" \
  --arg GRPC "$GRPC_SERVICE" --arg VMWS "$VMESS_WS_PATH" --arg CRT "$CRT" --arg KEY "$KEY" \
  --arg SS2022 "$SS2022_KEY" --arg SSPWD "$SS_PWD" --arg TUICUUID "$TUIC_UUID" --arg TUICPWD "$TUIC_PWD" --arg ANYTLSPWD "$ANYTLS_PWD" \
  --argjson P1 "$PORT_VLESSR" --argjson P2 "$PORT_VLESS_GRPCR" --argjson P3 "$PORT_TROJANR" \
  --argjson P4 "$PORT_HY2" --argjson P5 "$PORT_VMESS_WS" --argjson P6 "$PORT_HY2_OBFS" \
  --argjson P7 "$PORT_SS2022" --argjson P8 "$PORT_SS" --argjson P9 "$PORT_TUIC" --argjson P10 "$PORT_ANYTLS" \
  --argjson PW1 "$PORT_VLESSR_W" --argjson PW2 "$PORT_VLESS_GRPCR_W" --argjson PW3 "$PORT_TROJANR_W" \
  --argjson PW4 "$PORT_HY2_W" --argjson PW5 "$PORT_VMESS_WS_W" --argjson PW6 "$PORT_HY2_OBFS_W" \
  --argjson PW7 "$PORT_SS2022_W" --argjson PW8 "$PORT_SS_W" --argjson PW9 "$PORT_TUIC_W" --argjson PW10 "$PORT_ANYTLS_W" \
  --arg ENABLE_WARP "$ENABLE_WARP" \
  --arg WPRIV "${WARP_PRIVATE_KEY:-}" --arg WPPUB "${WARP_PEER_PUBLIC_KEY:-}" \
  --arg WHOST "${WARP_ENDPOINT_HOST:-}" --argjson WPORT "${WARP_ENDPOINT_PORT:-0}" \
  --arg W4 "${WARP_ADDRESS_V4:-}" --arg W6 "${WARP_ADDRESS_V6:-}" \
  --argjson WR1 "${WARP_RESERVED_1:-0}" --argjson WR2 "${WARP_RESERVED_2:-0}" --argjson WR3 "${WARP_RESERVED_3:-0}" \
  --arg EVR "$ENABLE_VLESS_REALITY" --arg EVG "$ENABLE_VLESS_GRPCR" --arg ETR "$ENABLE_TROJAN_REALITY" \
  --arg EHY "$ENABLE_HYSTERIA2" --arg EVM "$ENABLE_VMESS_WS" --arg EHO "$ENABLE_HY2_OBFS" \
  --arg ES2 "$ENABLE_SS2022" --arg ESS "$ENABLE_SS" --arg ETU "$ENABLE_TUIC" --arg EAT "$ENABLE_ANYTLS" \
  '
  def inbound_vless($port): {type:"vless", listen:"::", listen_port:$port, users:[{uuid:$UID}], tls:{enabled:true, server_name:$RS, reality:{enabled:true, handshake:{server:$RS, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_vless_flow($port): {type:"vless", listen:"::", listen_port:$port, users:[{uuid:$UID, flow:"xtls-rprx-vision"}], tls:{enabled:true, server_name:$RS, reality:{enabled:true, handshake:{server:$RS, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_trojan($port): {type:"trojan", listen:"::", listen_port:$port, users:[{password:$UID}], tls:{enabled:true, server_name:$RS, reality:{enabled:true, handshake:{server:$RS, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_hy2($port): {type:"hysteria2", listen:"::", listen_port:$port, users:[{name:"hy2", password:$HY2}], tls:{enabled:true, certificate_path:$CRT, key_path:$KEY}};
  def inbound_vmess_ws($port): {type:"vmess", listen:"::", listen_port:$port, users:[{uuid:$UID}], transport:{type:"ws", path:$VMWS}};
  def inbound_hy2_obfs($port): {type:"hysteria2", listen:"::", listen_port:$port, users:[{name:"hy2", password:$HY22}], obfs:{type:"salamander", password:$HY2O}, tls:{enabled:true, certificate_path:$CRT, key_path:$KEY, alpn:["h3"]}};
  def inbound_ss2022($port): {type:"shadowsocks", listen:"::", listen_port:$port, method:"2022-blake3-aes-256-gcm", password:$SS2022};
  def inbound_ss($port): {type:"shadowsocks", listen:"::", listen_port:$port, method:"aes-256-gcm", password:$SSPWD};
  def inbound_tuic($port): {type:"tuic", listen:"::", listen_port:$port, users:[{uuid:$TUICUUID, password:$TUICPWD}], congestion_control:"bbr", tls:{enabled:true, certificate_path:$CRT, key_path:$KEY, alpn:["h3"]}};
  def inbound_anytls($port): {type:"anytls", listen:"::", listen_port:$port, users:[{name:"anytls", password:$ANYTLSPWD}], tls:{enabled:true, certificate_path:$CRT, key_path:$KEY}};

  def warp_outbound:
    {type:"socks", tag:"warp", server:$WSHOST, server_port:$WSPORT};

  def enabled($v): $v == "true" or $v == "TRUE" or $v == "1" or $v == "yes" or $v == "on";
  def direct_inbounds:
    []
    + (if enabled($EVR) then [(inbound_vless_flow($P1) + {tag:"vless-reality"})] else [] end)
    + (if enabled($EVG) then [(inbound_vless($P2) + {tag:"vless-grpcr", transport:{type:"grpc", service_name:$GRPC}})] else [] end)
    + (if enabled($ETR) then [(inbound_trojan($P3) + {tag:"trojan-reality"})] else [] end)
    + (if enabled($EHY) then [(inbound_hy2($P4) + {tag:"hy2"})] else [] end)
    + (if enabled($EVM) then [(inbound_vmess_ws($P5) + {tag:"vmess-ws"})] else [] end)
    + (if enabled($EHO) then [(inbound_hy2_obfs($P6) + {tag:"hy2-obfs"})] else [] end)
    + (if enabled($ES2) then [(inbound_ss2022($P7) + {tag:"ss2022"})] else [] end)
    + (if enabled($ESS) then [(inbound_ss($P8) + {tag:"ss"})] else [] end)
    + (if enabled($ETU) then [(inbound_tuic($P9) + {tag:"tuic-v5"})] else [] end)
    + (if enabled($EAT) then [(inbound_anytls($P10) + {tag:"anytls"})] else [] end);

  def warp_inbounds:
    []
    + (if enabled($EVR) then [(inbound_vless_flow($PW1) + {tag:"vless-reality-warp"})] else [] end)
    + (if enabled($EVG) then [(inbound_vless($PW2) + {tag:"vless-grpcr-warp", transport:{type:"grpc", service_name:$GRPC}})] else [] end)
    + (if enabled($ETR) then [(inbound_trojan($PW3) + {tag:"trojan-reality-warp"})] else [] end)
    + (if enabled($EHY) then [(inbound_hy2($PW4) + {tag:"hy2-warp"})] else [] end)
    + (if enabled($EVM) then [(inbound_vmess_ws($PW5) + {tag:"vmess-ws-warp"})] else [] end)
    + (if enabled($EHO) then [(inbound_hy2_obfs($PW6) + {tag:"hy2-obfs-warp"})] else [] end)
    + (if enabled($ES2) then [(inbound_ss2022($PW7) + {tag:"ss2022-warp"})] else [] end)
    + (if enabled($ESS) then [(inbound_ss($PW8) + {tag:"ss-warp"})] else [] end)
    + (if enabled($ETU) then [(inbound_tuic($PW9) + {tag:"tuic-v5-warp"})] else [] end)
    + (if enabled($EAT) then [(inbound_anytls($PW10) + {tag:"anytls-warp"})] else [] end);

  def warp_tags:
    []
    + (if enabled($EVR) then ["vless-reality-warp"] else [] end)
    + (if enabled($EVG) then ["vless-grpcr-warp"] else [] end)
    + (if enabled($ETR) then ["trojan-reality-warp"] else [] end)
    + (if enabled($EHY) then ["hy2-warp"] else [] end)
    + (if enabled($EVM) then ["vmess-ws-warp"] else [] end)
    + (if enabled($EHO) then ["hy2-obfs-warp"] else [] end)
    + (if enabled($ES2) then ["ss2022-warp"] else [] end)
    + (if enabled($ESS) then ["ss-warp"] else [] end)
    + (if enabled($ETU) then ["tuic-v5-warp"] else [] end)
    + (if enabled($EAT) then ["anytls-warp"] else [] end);

  {
    log:{level:"info", timestamp:true},
  dns:{ servers:[ {type:"https", tag:"dns-remote", server:"1.1.1.1", server_port:443, path:"/dns-query"}, {type:"udp", tag:"dns-local", server:"8.8.8.8"} ], strategy:"prefer_ipv4" },
  inbounds:(direct_inbounds + (if enabled($ENABLE_WARP) then warp_inbounds else [] end)),
    outbounds: (
      if enabled($ENABLE_WARP) then
        [{type:"direct", tag:"direct"}, {type:"block", tag:"block"}, warp_outbound]
      else
        [{type:"direct", tag:"direct"}, {type:"block", tag:"block"}]
      end
    ),
    route: (
      if enabled($ENABLE_WARP) then
        { default_domain_resolver:"dns-remote",
          rules:(if (warp_tags|length) > 0 then [{inbound: warp_tags, outbound:"warp"}] else [] end),
          final:"direct"
        }
      else
        { final:"direct" }
      end
    )
  }' > "$tmp"; then
    rm -f "$tmp"
    err "生成配置失败"
    return 1
  fi

  if [[ -x "$BIN_PATH" ]] && ! "$BIN_PATH" check -c "$tmp"; then
    rm -f "$tmp"
    err "配置检查失败，已保留旧配置"
    return 1
  fi

  mv -f "$tmp" "$CONF_JSON"
  save_env
}

# ===== 防火墙 =====
current_firewall_rules(){
  local rules=()
  load_env || true
  load_ports || true
  ensure_any_protocol_enabled

  if flag_enabled "$ENABLE_VLESS_REALITY"; then rules+=("${PORT_VLESSR}/tcp"); fi
  if flag_enabled "$ENABLE_VLESS_GRPCR"; then rules+=("${PORT_VLESS_GRPCR}/tcp"); fi
  if flag_enabled "$ENABLE_TROJAN_REALITY"; then rules+=("${PORT_TROJANR}/tcp"); fi
  if flag_enabled "$ENABLE_HYSTERIA2"; then rules+=("${PORT_HY2}/udp"); fi
  if flag_enabled "$ENABLE_VMESS_WS"; then rules+=("${PORT_VMESS_WS}/tcp"); fi
  if flag_enabled "$ENABLE_HY2_OBFS"; then rules+=("${PORT_HY2_OBFS}/udp"); fi
  if flag_enabled "$ENABLE_SS2022"; then rules+=("${PORT_SS2022}/tcp" "${PORT_SS2022}/udp"); fi
  if flag_enabled "$ENABLE_SS"; then rules+=("${PORT_SS}/tcp" "${PORT_SS}/udp"); fi
  if flag_enabled "$ENABLE_TUIC"; then rules+=("${PORT_TUIC}/udp"); fi
  if flag_enabled "$ENABLE_ANYTLS"; then rules+=("${PORT_ANYTLS}/tcp"); fi

  if flag_enabled "$ENABLE_WARP"; then
    if flag_enabled "$ENABLE_VLESS_REALITY"; then rules+=("${PORT_VLESSR_W}/tcp"); fi
    if flag_enabled "$ENABLE_VLESS_GRPCR"; then rules+=("${PORT_VLESS_GRPCR_W}/tcp"); fi
    if flag_enabled "$ENABLE_TROJAN_REALITY"; then rules+=("${PORT_TROJANR_W}/tcp"); fi
    if flag_enabled "$ENABLE_HYSTERIA2"; then rules+=("${PORT_HY2_W}/udp"); fi
    if flag_enabled "$ENABLE_VMESS_WS"; then rules+=("${PORT_VMESS_WS_W}/tcp"); fi
    if flag_enabled "$ENABLE_HY2_OBFS"; then rules+=("${PORT_HY2_OBFS_W}/udp"); fi
    if flag_enabled "$ENABLE_SS2022"; then rules+=("${PORT_SS2022_W}/tcp" "${PORT_SS2022_W}/udp"); fi
    if flag_enabled "$ENABLE_SS"; then rules+=("${PORT_SS_W}/tcp" "${PORT_SS_W}/udp"); fi
    if flag_enabled "$ENABLE_TUIC"; then rules+=("${PORT_TUIC_W}/udp"); fi
    if flag_enabled "$ENABLE_ANYTLS"; then rules+=("${PORT_ANYTLS_W}/tcp"); fi
  fi

  printf '%s\n' "${rules[@]}" | awk 'NF' | sort -u
}

rule_in_list(){
  local needle="$1"; shift
  local r
  for r in "$@"; do [[ "$r" == "$needle" ]] && return 0; done
  return 1
}

delete_firewall_rule(){
  local r="$1" p proto
  [[ -n "$r" ]] || return 0
  p="${r%/*}"; proto="${r#*/}"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q -E "active|活跃"; then
    ufw --force delete allow "$r" >/dev/null 2>&1 || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$r" >/dev/null 2>&1 || true
  fi

  if command -v iptables >/dev/null 2>&1; then
    while iptables -D INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1; do :; done
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -D INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1; do :; done
  fi
}

cleanup_old_firewall_rules(){
  local current=("$@") old
  [[ -f "$FIREWALL_RULES_FILE" ]] || return 0
  while IFS= read -r old; do
    [[ -z "$old" ]] && continue
    rule_in_list "$old" "${current[@]}" || delete_firewall_rule "$old"
  done < "$FIREWALL_RULES_FILE"

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
}

open_firewall(){
  local rules=()
  mapfile -t rules < <(current_firewall_rules)
  cleanup_old_firewall_rules "${rules[@]}"

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q -E "active|活跃"; then
    for r in "${rules[@]}"; do ufw allow "$r" >/dev/null 2>&1 || true; done
    ufw reload >/dev/null 2>&1 || true

  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    for r in "${rules[@]}"; do firewall-cmd --permanent --add-port="$r" >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true

  else
    local p proto
    for r in "${rules[@]}"; do
      p="${r%/*}"; proto="${r#*/}"

      # IPv4
      if [[ "$proto" == tcp ]]; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
      fi
      if [[ "$proto" == udp ]]; then
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
      fi

      # IPv6（关键补全）
      if command -v ip6tables >/dev/null 2>&1; then
        if [[ "$proto" == tcp ]]; then
          ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT
        fi
        if [[ "$proto" == udp ]]; then
          ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT
        fi
      fi
    done

    # 保存（netfilter-persistent 通常会把 v4/v6 一起保存）
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi

  mkdir -p "$SB_DIR"
  printf '%s\n' "${rules[@]}" > "$FIREWALL_RULES_FILE"
}

# ===== 分享链接 / 订阅 =====
node_label(){
  local name="$1"
  if [[ -n "${REGION_TAG:-}" ]]; then
    printf '%s-%s' "$REGION_TAG" "$name"
  else
    printf '%s' "$name"
  fi
}

subscription_url(){
  [[ -n "${WEB_DOMAIN:-}" && -n "${SUB_TOKEN:-}" ]] || return 0
  local scheme="http"
  [[ -s "/etc/letsencrypt/live/${WEB_DOMAIN}/fullchain.pem" ]] && scheme="https"
  printf '%s://%s/sub/%s' "$scheme" "$WEB_DOMAIN" "$SUB_TOKEN"
}

build_links(){
  load_env; load_creds; load_ports
  ensure_dirs
  [[ -n "${WEB_DOMAIN:-}" ]] && WEB_DOMAIN="$(normalize_domain "$WEB_DOMAIN")"
  ensure_any_protocol_enabled
  mk_cert
  local mode="${1:-4}" ip host tls_sni label vmess_json
  LINKS_DIRECT=()
  LINKS_WARP=()
  LINKS_PINNED=()
  tls_sni="${TLS_SERVER_NAME:-$REALITY_SERVER}"

  if [[ -n "${WEB_DOMAIN:-}" ]]; then
    ip="$WEB_DOMAIN"
    host="$WEB_DOMAIN"
  elif [[ "$mode" == "6" ]]; then
    ip="$(get_ip6)"
    if [[ -z "$ip" ]]; then
      warn "未检测到公网 IPv6，自动回退到 IPv4"
      ip="$(get_ip4)"
      mode="4"
    fi
    host="$(fmt_host_for_uri "$ip")"
  else
    ip="$(get_ip4)"
    host="$(fmt_host_for_uri "$ip")"
  fi

  if flag_enabled "$ENABLE_VLESS_REALITY"; then
    label="$(node_label vless-reality)"
    LINKS_DIRECT+=("vless://${UUID}@${host}:${PORT_VLESSR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${label}")
  fi
  if flag_enabled "$ENABLE_VLESS_GRPCR"; then
    label="$(node_label vless-grpc-reality)"
    LINKS_DIRECT+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR}?encryption=none&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#${label}")
  fi
  if flag_enabled "$ENABLE_TROJAN_REALITY"; then
    label="$(node_label trojan-reality)"
    LINKS_DIRECT+=("trojan://${UUID}@${host}:${PORT_TROJANR}?security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${label}")
  fi
  if flag_enabled "$ENABLE_HYSTERIA2"; then
    label="$(node_label hysteria2)"
    LINKS_DIRECT+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2}?insecure=1&allowInsecure=1&sni=${tls_sni}#${label}")
    [[ -n "${CRT_SHA256:-}" ]] && LINKS_PINNED+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2}?sni=${tls_sni}&pcs=${CRT_SHA256}#$(node_label hysteria2-pinnedPeerCertSha256)")
  fi
  if flag_enabled "$ENABLE_VMESS_WS"; then
    label="$(node_label vmess-ws)"
    vmess_json="$(jq -cn --arg ps "$label" --arg add "$ip" --arg port "$PORT_VMESS_WS" --arg id "$UUID" --arg path "$VMESS_WS_PATH" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:"ws",type:"none",host:"",path:$path,tls:""}')"
    LINKS_DIRECT+=("vmess://$(printf "%s" "$vmess_json" | b64enc)")
  fi
  if flag_enabled "$ENABLE_HY2_OBFS"; then
    label="$(node_label hysteria2-obfs)"
    LINKS_DIRECT+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS}?insecure=1&allowInsecure=1&sni=${tls_sni}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#${label}")
  fi
  if flag_enabled "$ENABLE_SS2022"; then
    label="$(node_label ss2022)"
    LINKS_DIRECT+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022}#${label}")
  fi
  if flag_enabled "$ENABLE_SS"; then
    label="$(node_label ss)"
    LINKS_DIRECT+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS}#${label}")
  fi
  if flag_enabled "$ENABLE_TUIC"; then
    label="$(node_label tuic-v5)"
    LINKS_DIRECT+=("tuic://${UUID}:$(urlenc "${TUIC_PWD}")@${host}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=${tls_sni}#${label}")
  fi
  if flag_enabled "$ENABLE_ANYTLS"; then
    label="$(node_label anytls)"
    LINKS_DIRECT+=("anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS}?insecure=1&sni=${tls_sni}#${label}")
  fi

  if flag_enabled "$ENABLE_WARP"; then
    if flag_enabled "$ENABLE_VLESS_REALITY"; then
      label="$(node_label vless-reality-warp)"
      LINKS_WARP+=("vless://${UUID}@${host}:${PORT_VLESSR_W}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${label}")
    fi
    if flag_enabled "$ENABLE_VLESS_GRPCR"; then
      label="$(node_label vless-grpc-reality-warp)"
      LINKS_WARP+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR_W}?encryption=none&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#${label}")
    fi
    if flag_enabled "$ENABLE_TROJAN_REALITY"; then
      label="$(node_label trojan-reality-warp)"
      LINKS_WARP+=("trojan://${UUID}@${host}:${PORT_TROJANR_W}?security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#${label}")
    fi
    if flag_enabled "$ENABLE_HYSTERIA2"; then
      label="$(node_label hysteria2-warp)"
      LINKS_WARP+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2_W}?insecure=1&allowInsecure=1&sni=${tls_sni}#${label}")
      [[ -n "${CRT_SHA256:-}" ]] && LINKS_PINNED+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2_W}?sni=${tls_sni}&pcs=${CRT_SHA256}#$(node_label hysteria2-warp-pinnedPeerCertSha256)")
    fi
    if flag_enabled "$ENABLE_VMESS_WS"; then
      label="$(node_label vmess-ws-warp)"
      vmess_json="$(jq -cn --arg ps "$label" --arg add "$ip" --arg port "$PORT_VMESS_WS_W" --arg id "$UUID" --arg path "$VMESS_WS_PATH" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:"ws",type:"none",host:"",path:$path,tls:""}')"
      LINKS_WARP+=("vmess://$(printf "%s" "$vmess_json" | b64enc)")
    fi
    if flag_enabled "$ENABLE_HY2_OBFS"; then
      label="$(node_label hysteria2-obfs-warp)"
      LINKS_WARP+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS_W}?insecure=1&allowInsecure=1&sni=${tls_sni}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#${label}")
    fi
    if flag_enabled "$ENABLE_SS2022"; then
      label="$(node_label ss2022-warp)"
      LINKS_WARP+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022_W}#${label}")
    fi
    if flag_enabled "$ENABLE_SS"; then
      label="$(node_label ss-warp)"
      LINKS_WARP+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS_W}#${label}")
    fi
    if flag_enabled "$ENABLE_TUIC"; then
      label="$(node_label tuic-v5-warp)"
      LINKS_WARP+=("tuic://${UUID}:$(urlenc "${TUIC_PWD}")@${host}:${PORT_TUIC_W}?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=${tls_sni}#${label}")
    fi
    if flag_enabled "$ENABLE_ANYTLS"; then
      label="$(node_label anytls-warp)"
      LINKS_WARP+=("anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS_W}?insecure=1&sni=${tls_sni}#${label}")
    fi
  fi
}

write_subscription_current(){
  [[ -n "${WEB_DOMAIN:-}" ]] || return 0
  ensure_sub_token
  mkdir -p "$WEB_ROOT/sub"
  {
    printf '%s\n' "${LINKS_DIRECT[@]}"
    printf '%s\n' "${LINKS_WARP[@]}"
  } | b64enc > "$WEB_ROOT/sub/$SUB_TOKEN"
  chmod 0644 "$WEB_ROOT/sub/$SUB_TOKEN" 2>/dev/null || true
}

write_subscription(){
  [[ -n "${WEB_DOMAIN:-}" ]] || return 0
  build_links 4
  write_subscription_current
  write_nginx_config
  reload_nginx || true
  save_env
}

print_links_grouped(){
  local mode="${1:-4}" sub_url
  build_links "$mode"
  write_subscription_current
  save_env

  echo -e "${C_BLUE}${C_BOLD}分享链接（直连 ${#LINKS_DIRECT[@]} / WARP ${#LINKS_WARP[@]}）${C_RESET}"
  hr
  echo -e "${C_CYAN}${C_BOLD}【直连节点】${C_RESET}"
  for l in "${LINKS_DIRECT[@]}"; do echo "  $l"; done
  hr
  echo -e "${C_CYAN}${C_BOLD}【WARP 节点】${C_RESET}"
  echo -e "${C_DIM}说明：带 -warp 的节点走 Cloudflare WARP 出口，流媒体解锁更友好${C_RESET}"
  for l in "${LINKS_WARP[@]}"; do echo "  $l"; done

  if [[ "${#LINKS_PINNED[@]}" -gt 0 ]]; then
    hr
    echo -e "${C_YELLOW}📌 如果客户端不再接受 allowInsecure，可改用以下 pinnedPeerCertSha256 节点：${C_RESET}"
    for l in "${LINKS_PINNED[@]}"; do echo "  $l"; done
  fi

  if [[ -n "${WEB_DOMAIN:-}" && -n "${SUB_TOKEN:-}" ]]; then
    sub_url="$(subscription_url)"
    hr
    echo -e "${C_GREEN}订阅地址：${sub_url}${C_RESET}"
  fi
  hr
}

mask_secret(){
  local v="${1:-}" n
  n="${#v}"
  if (( n <= 16 )); then
    printf '***'
  else
    printf '%s...%s' "${v:0:8}" "${v: -8}"
  fi
}

cert_days_left(){
  local cert="$1" end epoch now
  [[ -s "$cert" ]] || return 1
  end="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2-)" || return 1
  if epoch="$(date -d "$end" +%s 2>/dev/null)"; then
    now="$(date +%s)"
    printf '%s' "$(( (epoch - now) / 86400 ))"
  else
    printf '%s' "$end"
  fi
}

health_check(){
  local out http url cert days chain blocked=0 custom_count ports
  ensure_dirs || true
  load_env || true
  load_ports || true
  ensure_any_protocol_enabled

  hr
  echo -e "${C_CYAN}${C_BOLD}健康检查${C_RESET}"
  hr
  echo "域名：${WEB_DOMAIN:-未配置}"
  echo "SNI：${REALITY_SERVER}:${REALITY_SERVER_PORT}"
  echo "区域：${REGION_TAG}"
  echo "协议：$(protocol_summary)"
  ports="$(current_firewall_rules | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  echo "端口：${ports:-未生成}"

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
    ok "sing-box 服务运行中"
  else
    warn "sing-box 服务未运行"
  fi

  if [[ -x "$BIN_PATH" && -f "$CONF_JSON" ]]; then
    if out="$("$BIN_PATH" check -c "$CONF_JSON" 2>&1)"; then
      ok "sing-box 配置检查通过"
    else
      warn "sing-box 配置检查失败"
      printf '%s\n' "$out" | sed -n '1,8p'
    fi
  else
    warn "未找到 sing-box 二进制或配置文件"
  fi

  if command -v nginx >/dev/null 2>&1; then
    if out="$(nginx -t 2>&1)"; then
      ok "nginx 配置检查通过"
    else
      warn "nginx 配置检查失败"
      printf '%s\n' "$out" | sed -n '1,8p'
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
      ok "nginx 服务运行中"
    else
      warn "nginx 服务未运行"
    fi
  elif [[ -n "${WEB_DOMAIN:-}" ]]; then
    warn "已配置域名但 nginx 未安装"
  fi

  if [[ -n "${WEB_DOMAIN:-}" ]]; then
    cert="/etc/letsencrypt/live/${WEB_DOMAIN}/fullchain.pem"
    if days="$(cert_days_left "$cert" 2>/dev/null)"; then
      if [[ "$days" =~ ^-?[0-9]+$ ]] && (( days < 15 )); then
        warn "证书剩余 ${days} 天"
      else
        ok "证书剩余 ${days} 天"
      fi
    else
      warn "未找到可读证书：${cert}"
    fi

    if [[ -n "${SUB_TOKEN:-}" && -n "$(command -v curl 2>/dev/null)" ]]; then
      url="https://${WEB_DOMAIN}/sub/${SUB_TOKEN}"
      http="$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || printf '000')"
      if [[ "$http" =~ ^2 ]]; then
        ok "订阅状态 ${http}：/sub/$(mask_secret "$SUB_TOKEN")"
      else
        warn "订阅状态 ${http}：/sub/$(mask_secret "$SUB_TOKEN")"
      fi
    fi
  fi

  if [[ -d /etc/nginx/sing-box-plus.locations ]]; then
    custom_count="$(find /etc/nginx/sing-box-plus.locations -maxdepth 1 -type f -name '*.conf' 2>/dev/null | wc -l | awk '{print $1}')"
    [[ "${custom_count:-0}" != "0" ]] && info "自定义 nginx location：${custom_count} 个"
  fi

  if command -v iptables >/dev/null 2>&1; then
    for chain in CF_ORIGIN_VJ CF_ORIGIN_443; do
      if iptables -C INPUT -p tcp --dport 443 -j "$chain" 2>/dev/null; then
        warn "发现旧 Cloudflare-only 443 规则：${chain}"
        blocked=1
      fi
    done
  fi
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qE 'CF_ORIGIN_(VJ|443)|dport[[:space:]]+443.*drop'; then
    warn "nftables 中可能存在 443 限制规则，请人工确认"
    blocked=1
  fi
  [[ "$blocked" == "0" ]] && ok "未发现旧 Cloudflare-only 443 INPUT 规则"
  hr
}

# ===== BBR =====
enable_bbr(){
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    info "BBR 已启用"
  else
    echo "net.core.default_qdisc=fq" >/etc/sysctl.d/99-bbr.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null 2>&1 || true
    info "已尝试开启 BBR（如内核不支持需自行升级）"
  fi
}

# ===== 显示状态与 banner =====
sb_service_state(){
  systemctl is-active --quiet "${SYSTEMD_SERVICE:-sing-box.service}" && echo -e "${C_GREEN}运行中${C_RESET}" || echo -e "${C_RED}未运行/未安装${C_RESET}"
}
bbr_state(){
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && echo -e "${C_GREEN}已启用 BBR${C_RESET}" || echo -e "${C_RED}未启用 BBR${C_RESET}"
}

banner(){
  clear >/dev/null 2>&1 || true
  hr
  echo -e " ${C_CYAN}🚀 ${SCRIPT_NAME} ${SCRIPT_VERSION} 🚀${C_RESET}"
  echo -e "${C_CYAN} 脚本更新地址: https://github.com/Alvin9999-newpac/Sing-Box-Plus${C_RESET}"

  hr
  echo -e "系统加速状态：$(bbr_state)"
  echo -e "Sing-Box 启动状态：$(sb_service_state)"
  hr
  echo -e "  ${C_BLUE}1)${C_RESET} 安装/部署"
  echo -e "  ${C_GREEN}2)${C_RESET} 查看分享链接（IPv4）"
  echo -e "  ${C_GREEN}6)${C_RESET} 查看分享链接（IPv6）"
  echo -e "  ${C_GREEN}3)${C_RESET} 重启服务"
  echo -e "  ${C_GREEN}4)${C_RESET} 一键更换所有端口"
  echo -e "  ${C_GREEN}5)${C_RESET} 一键开启 BBR"
  echo -e "  ${C_GREEN}7)${C_RESET} 配置 SNI / 协议 / 域名订阅"
  echo -e "  ${C_GREEN}9)${C_RESET} 健康检查"
  echo -e "  ${C_RED}8)${C_RESET} 卸载"
  echo -e "  ${C_RED}0)${C_RESET} 退出"
  hr
}

protocol_summary(){
  local names=()
  flag_enabled "$ENABLE_VLESS_REALITY" && names+=("VLESS Reality")
  flag_enabled "$ENABLE_VLESS_GRPCR" && names+=("VLESS gRPC Reality")
  flag_enabled "$ENABLE_TROJAN_REALITY" && names+=("Trojan Reality")
  flag_enabled "$ENABLE_HYSTERIA2" && names+=("Hysteria2")
  flag_enabled "$ENABLE_VMESS_WS" && names+=("VMess WS")
  flag_enabled "$ENABLE_HY2_OBFS" && names+=("Hysteria2 Obfs")
  flag_enabled "$ENABLE_SS2022" && names+=("SS 2022")
  flag_enabled "$ENABLE_SS" && names+=("Shadowsocks")
  flag_enabled "$ENABLE_TUIC" && names+=("TUIC")
  flag_enabled "$ENABLE_ANYTLS" && names+=("AnyTLS")
  ((${#names[@]})) && printf '%s' "${names[*]}" || printf '无'
}

configure_protocol_selection(){
  local sel item selected=0
  echo
  echo -e "${C_CYAN}协议选择${C_RESET}（回车启用全部；输入编号可逗号分隔）"
  echo "  1) VLESS Reality"
  echo "  2) VLESS gRPC Reality"
  echo "  3) Trojan Reality"
  echo "  4) Hysteria2"
  echo "  5) VMess WS"
  echo "  6) Hysteria2 Obfs"
  echo "  7) Shadowsocks 2022"
  echo "  8) Shadowsocks"
  echo "  9) TUIC"
  echo "  10) AnyTLS"
  echo "  all) 启用全部"
  read -rp "启用协议 [all]: " sel || true
  sel="$(trim_spaces "${sel:-}")"
  if [[ -z "$sel" || "$sel" == "all" || "$sel" == "ALL" ]]; then
    set_all_protocols true
    return 0
  fi

  set_all_protocols false
  IFS=',' read -ra items <<< "$sel"
  for item in "${items[@]}"; do
    item="$(trim_spaces "$item")"
    case "$item" in
      1|vless|vless-reality) ENABLE_VLESS_REALITY=true; selected=1 ;;
      2|grpc|vless-grpc|vless-grpc-reality) ENABLE_VLESS_GRPCR=true; selected=1 ;;
      3|trojan|trojan-reality) ENABLE_TROJAN_REALITY=true; selected=1 ;;
      4|hy2|hysteria2) ENABLE_HYSTERIA2=true; selected=1 ;;
      5|vmess|vmess-ws) ENABLE_VMESS_WS=true; selected=1 ;;
      6|hy2-obfs|hysteria2-obfs) ENABLE_HY2_OBFS=true; selected=1 ;;
      7|ss2022|ss-2022) ENABLE_SS2022=true; selected=1 ;;
      8|ss|shadowsocks) ENABLE_SS=true; selected=1 ;;
      9|tuic|tuic-v5) ENABLE_TUIC=true; selected=1 ;;
      10|anytls) ENABLE_ANYTLS=true; selected=1 ;;
      *) warn "忽略未知协议选择：$item" ;;
    esac
  done
  [[ "$selected" == "1" ]] || ENABLE_VLESS_REALITY=true
}

configure_install_options(){
  if [[ "$EUID" -ne 0 ]]; then
    warn "请以 root 运行（或 sudo）后再安装/配置"
    return 1
  fi
  if ! ensure_dirs; then
    err "无法创建工作目录：$SB_DIR"
    return 1
  fi
  load_env || true
  local ans
  hr
  echo -e "${C_CYAN}${C_BOLD}安装配置${C_RESET}"

  read -rp "REALITY SNI/伪装域名 [${REALITY_SERVER}]: " ans || true
  ans="$(trim_spaces "${ans:-}")"
  [[ -n "$ans" ]] && REALITY_SERVER="$ans"

  read -rp "REALITY 目标端口 [${REALITY_SERVER_PORT}]: " ans || true
  ans="$(trim_spaces "${ans:-}")"
  [[ -n "$ans" ]] && REALITY_SERVER_PORT="$ans"

  read -rp "节点名称区域标识 [${REGION_TAG}]: " ans || true
  ans="$(trim_spaces "${ans:-}")"
  [[ -n "$ans" ]] && REGION_TAG="$ans"

  configure_protocol_selection

  read -rp "启用 WARP 节点副本? [Y/n]: " ans || true
  ans="$(trim_spaces "${ans:-}")"
  case "$ans" in
    n|N|no|NO|0) ENABLE_WARP=false ;;
    *) ENABLE_WARP=true ;;
  esac

  read -rp "Web/订阅域名（留空跳过，输入 none 关闭） [${WEB_DOMAIN:-}]: " ans || true
  ans="$(trim_spaces "${ans:-}")"
  case "$ans" in
    none|NONE|no|NO|0) WEB_DOMAIN="" ;;
    "") ;;
    *) WEB_DOMAIN="$(normalize_domain "$ans")" ;;
  esac

  if [[ -n "${WEB_DOMAIN:-}" ]]; then
    warn "请先在 DNS 中把 ${WEB_DOMAIN} 的 A/AAAA 记录指向本机公网 IP，并在云防火墙放行 80/443。"
    read -rp "确认域名已经指向本机? [y/N]: " ans || true
    ans="$(trim_spaces "${ans:-}")"
    case "$ans" in
      y|Y|yes|YES) ;;
      *) warn "未确认域名指向，已跳过 Web/订阅/证书配置"; WEB_DOMAIN="" ;;
    esac
  fi

  if [[ -n "${WEB_DOMAIN:-}" ]]; then
    read -rp "证书邮箱（可留空） [${CERT_EMAIL:-}]: " ans || true
    ans="$(trim_spaces "${ans:-}")"
    [[ -n "$ans" ]] && CERT_EMAIL="$ans"
    ensure_sub_token
  else
    SUB_TOKEN=""
  fi

  ensure_any_protocol_enabled
  save_env
  echo -e "${C_GREEN}已保存配置：SNI=${REALITY_SERVER}，协议=$(protocol_summary)${C_RESET}"
}

# ===== 业务流程 =====
restart_service(){
  systemctl restart "${SYSTEMD_SERVICE}" || die "重启失败"
  systemctl --no-pager status "${SYSTEMD_SERVICE}" | sed -n '1,6p' || true
}

rotate_ports(){
  ensure_installed_or_hint || return 0
  load_ports || true
  rand_ports_reset

  # 清空 20 项端口变量，触发重新分配不重复端口
  PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
  PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
  PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
  PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

  save_all_ports          # 重新生成并保存 20 个不重复端口
  write_config            # 用新端口重写 /opt/sing-box/config.json
  open_firewall           # ★ 新增：把“当前配置中的端口”全部放行
  systemctl restart "${SYSTEMD_SERVICE}"
  write_subscription || true

  info "已更换端口并重启。"
  read -p "回车返回..." _ || true
}


uninstall_all(){
  systemctl stop "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  if [[ -f "$FIREWALL_RULES_FILE" ]]; then
    while IFS= read -r r; do
      [[ -n "$r" ]] && delete_firewall_rule "$r"
    done < "$FIREWALL_RULES_FILE"
  fi
  rm -f "/etc/systemd/system/${SYSTEMD_SERVICE}"
  systemctl daemon-reload
  rm -rf "$SB_DIR"
  echo -e "${C_GREEN}已卸载并清理完成。${C_RESET}"
  exit 0
}

deploy_native(){
  install_deps
  install_singbox
  setup_web || true
  write_config
  info "检查配置 ..."
  "$BIN_PATH" check -c "$CONF_JSON"
  info "写入并启用 systemd 服务 ..."
  write_systemd
  systemctl restart "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  open_firewall
  write_subscription || true
  echo; echo -e "${C_BOLD}${C_GREEN}★ 部署完成${C_RESET}"; echo
  # 打印链接并直接退出
  print_links_grouped 4
  exit 0
}

ensure_installed_or_hint(){
  if [[ ! -f "$CONF_JSON" ]]; then
    warn "尚未安装，请先选择 1) 安装/部署"
    return 1
  fi
  return 0
}

# ===== 菜单 =====
menu(){
  banner
  read -rp "选择: " op || true
  case "${op:-}" in
  1)
  if ! configure_install_options; then
    read -rp "回车返回..." _ || true
    menu
    return 0
  fi
  sbp_bootstrap                                     # 依赖/二进制回退
  set +e                                            # ← 关闭严格退出，避免中途被杀掉
  echo -e "${C_BLUE}[信息] 正在检查 sing-box 安装状态...${C_RESET}"
  install_singbox            || true
  ensure_warpcli_proxy        || true
  setup_web                  || true
  write_config               || { echo "[ERR] 生成配置失败"; }
  write_systemd              || true
  open_firewall              || true
  systemctl restart "${SYSTEMD_SERVICE}" || true
  write_subscription         || true
  set -e                                            # ← 恢复严格模式
  print_links_grouped
  exit 0                                          # ← 打印后直接退出
  ;;
  2) if ensure_installed_or_hint; then print_links_grouped 4; exit 0; fi ;;

  6) if ensure_installed_or_hint; then print_links_grouped 6; exit 0; fi ;;
    3) if ensure_installed_or_hint; then restart_service; fi; read -rp "回车返回..." _ || true; menu ;;
   4) if ensure_installed_or_hint; then rotate_ports; fi; menu ;;
    5) enable_bbr; read -rp "回车返回..." _ || true; menu ;;
    9) health_check; read -rp "回车返回..." _ || true; menu ;;
    7)
      if ! configure_install_options; then
        read -rp "回车返回..." _ || true
        menu
        return 0
      fi
      if ensure_installed_or_hint; then
        setup_web || true
        write_config || { echo "[ERR] 生成配置失败"; }
        open_firewall || true
        systemctl restart "${SYSTEMD_SERVICE}" || true
        write_subscription || true
        print_links_grouped
        exit 0
      fi
      read -rp "回车返回..." _ || true
      menu
      ;;
    8) uninstall_all ;; # 直接退出
    0) exit 0 ;;
    *) menu ;;
  esac
}

# ===== 入口 =====
menu
