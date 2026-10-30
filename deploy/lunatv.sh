#!/usr/bin/env bash
#
# LunaTV 一键部署与维护脚本（Ubuntu / Debian，amd64 / arm64）
#
# 部署结构：
#   - Docker Compose 运行 LunaTV + Kvrocks；LunaTV 只监听本机 127.0.0.1，不直接对外
#   - 宿主机 nginx 负责 HTTPS（默认 2096 端口，可走 Cloudflare 代理），
#     证书使用已有文件，例如 3x-ui / acme.sh 放在 /root/cert/<域名>/ 下的证书
#   - /etc/cron.d/lunatv 每周 reload 一次 nginx，加载续期后的证书
#   - 宿主机防火墙（ufw 或 iptables）拦截时放行 HTTPS 端口，规则带 lunatv 注释
#   - 只新增或删除自己的文件和规则，不改动已有的 nginx 配置、证书和 acme.sh 设置
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/iv7777/LunaTV/HEAD/deploy/lunatv.sh -o lunatv.sh
#   sudo bash lunatv.sh install
# 安装时会顺带安装 lunatv 命令，之后直接运行 lunatv status、lunatv update 等；
# lunatv help 查看全部命令。

set -Eeuo pipefail

SCRIPT_VERSION='1.0.0'
SCRIPT_URL='https://raw.githubusercontent.com/iv7777/LunaTV/HEAD/deploy/lunatv.sh'
DEFAULT_IMAGE='ghcr.io/iv7777/lunatv:latest'
KVROCKS_IMAGE='apache/kvrocks'
COMPOSE_PROJECT='lunatv'
DEFAULT_PROXY_PORT='2096'
DEFAULT_APP_PORT='3000'
# Cloudflare 代理支持的 HTTPS 端口
CF_HTTPS_PORTS='443 2053 2083 2087 2096 8443'

# 以下路径可用环境变量覆盖（主要用于测试）
LUNATV_DIR="${LUNATV_DIR:-/opt/lunatv}"
NGINX_CONF="${LUNATV_NGINX_CONF:-/etc/nginx/conf.d/lunatv.conf}"
CRON_FILE="${LUNATV_CRON_FILE:-/etc/cron.d/lunatv}"
BIN_PATH="${LUNATV_BIN:-/usr/local/bin/lunatv}"
IPTABLES_DIR="${LUNATV_IPTABLES_DIR:-/etc/iptables}"
ENV_FILE="$LUNATV_DIR/.env"
COMPOSE_FILE="$LUNATV_DIR/docker-compose.yml"
STATE_FILE="$LUNATV_DIR/deploy.conf"

# 命令行选项
ASSUME_YES=0
PURGE=0
SHOW_PASSWORD=0
OPT_DOMAIN=''
OPT_PROXY_PORT=''
OPT_APP_PORT=''
OPT_CERT=''
OPT_KEY=''
OPT_USERNAME=''
OPT_PASSWORD=''
OPT_IMAGE=''
POSITIONAL=()

# 部署设置（来自选项、上次安装记录或默认值）
DOMAIN=''
PROXY_PORT=''
APP_PORT=''
CERT_FILE=''
KEY_FILE=''
IMAGE=''
ADMIN_USER=''
ADMIN_PASS=''
PASSWORD_GENERATED=0

# 上次安装记录（deploy.conf）
ST_DOMAIN=''
ST_PROXY_PORT=''
ST_APP_PORT=''
ST_CERT_FILE=''
ST_KEY_FILE=''
ST_IMAGE=''
ST_INSTALLED_AT=''

APT_UPDATED=0
NGINX_VERSION=''
HTTPS_STATUS=''
PROBLEMS=0

# ---------- 输出 ----------

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_RESET=''
fi

log() { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s ✓%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
  printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}
section() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# status 用：记录检查结果并统计问题数
check_ok() { ok "$*"; }
check_fail() {
  printf '%s ✗%s  %s\n' "$C_RED" "$C_RESET" "$*"
  PROBLEMS=$((PROBLEMS + 1))
}
check_warn() { printf '%s !%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }

on_error() {
  local code=$1 line=$2 cmd=$3
  printf '%s[错误]%s 第 %s 行的命令失败（退出码 %s）：%s\n' \
    "$C_RED" "$C_RESET" "$line" "$code" "$cmd" >&2
  exit "$code"
}

# ---------- 交互 ----------

# 有可用的终端且没有加 -y 时才提问
is_interactive() {
  [[ $ASSUME_YES -eq 0 ]] && { : </dev/tty; } 2>/dev/null
}

# ask <变量名> <提示> [默认值]：非交互时直接使用默认值
ask() {
  local __var=$1 __prompt=$2 __default=${3:-} __reply=''
  if is_interactive; then
    if [[ -n $__default ]]; then
      printf '%s [%s]: ' "$__prompt" "$__default" >/dev/tty
    else
      printf '%s: ' "$__prompt" >/dev/tty
    fi
    IFS= read -r __reply </dev/tty || true
  fi
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

ask_secret() {
  local __var=$1 __prompt=$2 __reply=''
  if is_interactive; then
    printf '%s: ' "$__prompt" >/dev/tty
    IFS= read -rs __reply </dev/tty || true
    printf '\n' >/dev/tty
  fi
  printf -v "$__var" '%s' "$__reply"
}

confirm() {
  local reply=''
  [[ $ASSUME_YES -eq 1 ]] && return 0
  is_interactive || die "需要确认，但当前不是交互终端；确认无误请加 -y"
  printf '%s [y/N]: ' "$1" >/dev/tty
  IFS= read -r reply </dev/tty || true
  [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------- 校验 ----------

valid_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

# 绝对路径，且不含会破坏 nginx 配置的字符
valid_path() {
  case $1 in /*) ;; *) return 1 ;; esac
  case $1 in *[[:space:]\;\'\"\\\$\`\{\}\#]*) return 1 ;; esac
}

valid_username() {
  [[ $1 =~ ^[A-Za-z0-9_.@-]{1,32}$ ]]
}

# 写进 .env 的密码：8~128 位，不含空白和 $ ' " \ ` #
valid_password() {
  ((${#1} >= 8 && ${#1} <= 128)) || return 1
  case $1 in *[[:space:]\'\"\\\$\`\#]*) return 1 ;; esac
}

valid_image() {
  [[ $1 =~ ^[a-z0-9][a-z0-9./_:@-]*$ ]]
}

# version_ge <a> <b>：a >= b 时返回 0
version_ge() {
  local lowest
  lowest=$(printf '%s\n%s\n' "$2" "$1" | sort -V)
  [[ ${lowest%%$'\n'*} == "$2" ]]
}

generate_password() {
  local pass=''
  while ((${#pass} < 20)); do
    pass+=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9')
  done
  printf '%s' "${pass:0:20}"
}

# ---------- 安装记录与配置文件 ----------

load_state() {
  [[ -f $STATE_FILE ]] || return 1
  local key value
  while IFS='=' read -r key value; do
    case $key in
      DOMAIN) ST_DOMAIN=$value ;;
      PROXY_PORT) ST_PROXY_PORT=$value ;;
      APP_PORT) ST_APP_PORT=$value ;;
      CERT_FILE) ST_CERT_FILE=$value ;;
      KEY_FILE) ST_KEY_FILE=$value ;;
      IMAGE) ST_IMAGE=$value ;;
      INSTALLED_AT) ST_INSTALLED_AT=$value ;;
    esac
  done <"$STATE_FILE"
}

# 维护命令使用上次安装记录中的设置
use_state() {
  load_state || die "找不到安装记录 $STATE_FILE，请先运行 install"
  DOMAIN=$ST_DOMAIN
  PROXY_PORT=${ST_PROXY_PORT:-$DEFAULT_PROXY_PORT}
  APP_PORT=${ST_APP_PORT:-$DEFAULT_APP_PORT}
  CERT_FILE=$ST_CERT_FILE
  KEY_FILE=$ST_KEY_FILE
  IMAGE=${ST_IMAGE:-$DEFAULT_IMAGE}
}

read_env_value() {
  [[ -f $ENV_FILE ]] || return 0
  local value
  value=$(sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1)
  value=${value%\"}
  value=${value#\"}
  value=${value%\'}
  value=${value#\'}
  printf '%s' "$value"
}

# install_file <目标> <权限>：从标准输入写入目标文件；旧文件内容不同时先备份为 .bak
install_file() {
  local dest=$1 mode=$2 tmp
  tmp=$(mktemp "$dest.XXXXXX")
  cat >"$tmp"
  chmod "$mode" "$tmp"
  if [[ -f $dest ]] && ! cmp -s "$tmp" "$dest"; then
    cp -p "$dest" "$dest.bak"
  fi
  mv -f "$tmp" "$dest"
}

render_compose() {
  cat <<EOF
# 由 LunaTV 部署脚本生成，重新运行 install 会覆盖此文件
services:
  lunatv:
    image: $IMAGE
    container_name: lunatv
    restart: unless-stopped
    # 只监听本机，由宿主机 nginx 提供 HTTPS
    ports:
      - '127.0.0.1:$APP_PORT:3000'
    env_file: .env
    environment:
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://lunatv-kvrocks:6666
    depends_on:
      - lunatv-kvrocks

  lunatv-kvrocks:
    image: $KVROCKS_IMAGE
    container_name: lunatv-kvrocks
    restart: unless-stopped
    volumes:
      - kvrocks-data:/var/lib/kvrocks

volumes:
  kvrocks-data:
EOF
}

# 内核支持 IPv6 且没有被禁用时，nginx 才能监听 [::]
has_ipv6() {
  [[ -f /proc/net/if_inet6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) != 1 ]]
}

# nginx 1.25.1 起用 http2 on;，更早的版本写在 listen 里
render_nginx_conf() {
  local listen_opts='ssl' http2_directive=1
  if ! version_ge "$NGINX_VERSION" 1.25.1; then
    listen_opts='ssl http2'
    http2_directive=0
  fi
  echo '# 由 LunaTV 部署脚本生成，重新运行 install 会覆盖此文件；卸载时会被删除'
  echo 'server {'
  echo "    listen $PROXY_PORT $listen_opts;"
  if has_ipv6; then
    echo "    listen [::]:$PROXY_PORT $listen_opts;"
  fi
  if ((http2_directive)); then
    echo '    http2 on;'
  fi
  cat <<EOF
    server_name $DOMAIN;

    ssl_certificate     $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    access_log /var/log/nginx/lunatv.access.log;
    error_log  /var/log/nginx/lunatv.error.log;

    # 数据导入需要上传备份文件，nginx 默认只允许 1MB
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 搜索结果是流式返回（SSE），不能缓冲
        proxy_buffering off;
        proxy_read_timeout 300s;
    }
}
EOF
}

render_cron() {
  cat <<'EOF'
# 由 LunaTV 部署脚本生成：每周一 04:00 reload nginx，加载续期后的证书
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * 1 root systemctl reload nginx >/dev/null 2>&1
EOF
}

render_state() {
  cat <<EOF
# 由 LunaTV 部署脚本生成，供 status / info / update 等命令读取
DOMAIN=$DOMAIN
PROXY_PORT=$PROXY_PORT
APP_PORT=$APP_PORT
CERT_FILE=$CERT_FILE
KEY_FILE=$KEY_FILE
IMAGE=$IMAGE
INSTALLED_AT=$(date '+%F %T %z')
SCRIPT_VERSION=$SCRIPT_VERSION
EOF
}

# USERNAME / PASSWORD 写在最前面，保留用户在 .env 里加的其他变量
render_env() {
  echo '# LunaTV 环境变量：USERNAME / PASSWORD 是站长账号，其他可用变量见 README「环境变量」'
  echo "USERNAME=$ADMIN_USER"
  echo "PASSWORD=$ADMIN_PASS"
  if [[ -f $ENV_FILE ]]; then
    grep -vE '^(USERNAME|PASSWORD)=|^# LunaTV 环境变量' "$ENV_FILE" || true
  fi
}

# ---------- 系统检查与依赖 ----------

require_root() {
  [[ $EUID -eq 0 ]] || die "请用 root 运行（例如 sudo bash $0 ${COMMAND:-}）"
}

check_platform() {
  [[ -r /etc/os-release ]] || die "无法识别系统（缺少 /etc/os-release）"
  local id version arch
  # shellcheck source=/dev/null
  id=$(. /etc/os-release && echo "${ID:-}")
  # shellcheck source=/dev/null
  version=$(. /etc/os-release && echo "${VERSION_ID:-}")
  arch=$(uname -m)
  case $id in
    ubuntu | debian) ;;
    *) die "只支持 Ubuntu / Debian，当前系统：${id:-未知}" ;;
  esac
  case $arch in
    x86_64 | amd64 | aarch64 | arm64) ;;
    *) die "只支持 amd64 / arm64，当前架构：$arch" ;;
  esac
  command -v systemctl >/dev/null || die "需要 systemd（找不到 systemctl）"
  ok "系统 $id $version，架构 $arch"
}

apt_try_install() {
  if ((APT_UPDATED == 0)); then
    log "更新软件包索引…"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
    APT_UPDATED=1
  fi
  log "安装 $*…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
}

apt_install() {
  apt_try_install "$@" || die "安装 $* 失败，请检查网络或软件源"
}

ensure_tools() {
  local missing=()
  command -v curl >/dev/null || missing+=(curl)
  command -v openssl >/dev/null || missing+=(openssl)
  command -v ss >/dev/null || missing+=(iproute2)
  dpkg -s ca-certificates >/dev/null 2>&1 || missing+=(ca-certificates)
  dpkg -s cron >/dev/null 2>&1 || missing+=(cron)
  if ((${#missing[@]} > 0)); then
    apt_install "${missing[@]}"
  fi
  systemctl enable --now cron >/dev/null 2>&1 || warn "无法启动 cron，证书 reload 定时任务可能不会执行"
}

check_disk() {
  local avail
  avail=$(df -Pm /var/lib | awk 'NR == 2 { print $4 }')
  if [[ $avail =~ ^[0-9]+$ ]] && ((avail < 2048)); then
    warn "/var/lib 只剩 ${avail}MB 可用空间，镜像约需 1GB，建议至少留 2GB"
  fi
}

ensure_docker() {
  if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
    die "检测到 snap 版 Docker，会和本脚本使用的 Docker 冲突。确认不需要它的容器和数据后运行 snap remove docker，再重试"
  fi
  if ! command -v docker >/dev/null; then
    log "安装 Docker（官方脚本 get.docker.com）…"
    local installer
    installer=$(mktemp)
    if ! curl -fsSL https://get.docker.com -o "$installer"; then
      rm -f "$installer"
      die "下载 Docker 安装脚本失败，请检查网络"
    fi
    if ! sh "$installer"; then
      rm -f "$installer"
      die "Docker 安装失败，请查看上面的输出"
    fi
    rm -f "$installer"
  fi
  systemctl enable --now docker >/dev/null 2>&1 ||
    die "无法启动 Docker 服务，运行 systemctl status docker 查看原因"
  docker info >/dev/null 2>&1 || die "Docker 没有正常运行，运行 systemctl status docker 查看原因"
  if ! docker compose version >/dev/null 2>&1; then
    apt_try_install docker-compose-plugin || apt_try_install docker-compose-v2 ||
      die "无法安装 Docker Compose 插件"
    docker compose version >/dev/null 2>&1 || die "Docker Compose 插件不可用"
  fi
  ok "$(docker --version)，$(docker compose version --short 2>/dev/null | sed 's/^/Compose /')"
}

ensure_nginx() {
  if ! command -v nginx >/dev/null; then
    apt_install nginx
    # 发行版自带的默认站点会占用 80 端口，影响 acme.sh 的 standalone 续期
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
      rm -f /etc/nginx/sites-enabled/default
      ok "已移除 nginx 自带的默认站点（释放 80 端口）"
    fi
  fi
  local out
  if ! out=$(nginx -t 2>&1); then
    die "nginx 现有配置有错误，请先修复："$'\n'"$out"
  fi
  if ! systemctl is-active --quiet nginx; then
    systemctl enable --now nginx >/dev/null 2>&1 ||
      die "无法启动 nginx，运行 systemctl status nginx 查看原因"
  fi
  NGINX_VERSION=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')
  [[ -n $NGINX_VERSION ]] || die "无法识别 nginx 版本"
  ok "nginx $NGINX_VERSION"
}

# ---------- 端口、容器与证书检查 ----------

# 输出监听指定 TCP 端口的进程（没有则为空）
port_listeners() {
  ss -Htlnp "( sport = :$1 )" 2>/dev/null || true
}

# 输出容器所属的 compose 项目名（容器不存在则为空）
container_project() {
  command -v docker >/dev/null || return 0
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null || true
}

container_exists() {
  command -v docker >/dev/null && docker inspect "$1" >/dev/null 2>&1
}

check_ports() {
  local out
  out=$(port_listeners "$PROXY_PORT")
  if [[ -n $out ]]; then
    if [[ -f $NGINX_CONF && $out == *'"nginx"'* ]]; then
      ok "端口 $PROXY_PORT 正由之前的 LunaTV nginx 配置使用，将更新"
    else
      die "端口 $PROXY_PORT 已被占用："$'\n'"$out"$'\n'"请用 --port 换一个（走 Cloudflare 代理时可选：$CF_HTTPS_PORTS）"
    fi
  else
    ok "端口 $PROXY_PORT 可用"
  fi

  out=$(port_listeners "$APP_PORT")
  if [[ -n $out ]]; then
    if [[ $out == *'"docker-proxy"'* && $(container_project lunatv) == "$COMPOSE_PROJECT" ]]; then
      ok "本机端口 $APP_PORT 正由现有的 LunaTV 容器使用，将更新"
    else
      die "本机端口 $APP_PORT 已被占用："$'\n'"$out"$'\n'"请用 --app-port 换一个"
    fi
  else
    ok "本机端口 $APP_PORT 可用"
  fi

  if [[ " $CF_HTTPS_PORTS " != *" $PROXY_PORT "* ]]; then
    warn "端口 $PROXY_PORT 不在 Cloudflare 支持的 HTTPS 端口内（$CF_HTTPS_PORTS），域名走 Cloudflare 代理时将无法访问"
  fi
}

check_container_names() {
  local name project
  for name in lunatv lunatv-kvrocks; do
    container_exists "$name" || continue
    project=$(container_project "$name")
    if [[ $project != "$COMPOSE_PROJECT" ]]; then
      die "已存在名为 $name 的容器，但不是本脚本创建的（compose 项目：${project:-无}）。请先删除或改名后重试"
    fi
  done
}

cert_enddate() { openssl x509 -in "$1" -noout -enddate | cut -d= -f2; }

cert_days_left() {
  local end
  end=$(date -d "$(cert_enddate "$1")" +%s)
  echo $(((end - $(date +%s)) / 86400))
}

cert_names() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | sed 's/^ *//'
}

check_cert() {
  if [[ ! -f $CERT_FILE || ! -f $KEY_FILE ]]; then
    local hint=''
    if [[ -d /root/cert ]]; then
      hint=$'\n'"/root/cert 下现有：$(find /root/cert -mindepth 1 -maxdepth 1 -printf '%f ')"
    fi
    [[ -f $CERT_FILE ]] || die "找不到证书文件 $CERT_FILE（用 --cert 指定）$hint"
    die "找不到私钥文件 $KEY_FILE（用 --key 指定）$hint"
  fi
  openssl x509 -in "$CERT_FILE" -noout 2>/dev/null || die "$CERT_FILE 不是有效的 PEM 证书"
  openssl pkey -in "$KEY_FILE" -noout 2>/dev/null || die "$KEY_FILE 不是有效的 PEM 私钥"

  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$CERT_FILE" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum)
  key_pub=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER | sha256sum)
  [[ $cert_pub == "$key_pub" ]] || die "证书 $CERT_FILE 和私钥 $KEY_FILE 不是一对"

  local host_check
  host_check=$(openssl x509 -in "$CERT_FILE" -noout -checkhost "$DOMAIN" 2>/dev/null || true)
  [[ $host_check == *"does match"* ]] ||
    die "证书不包含域名 $DOMAIN（证书包含：$(cert_names "$CERT_FILE")）"

  openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null ||
    die "证书已于 $(cert_enddate "$CERT_FILE") 过期"
  if ! openssl x509 -in "$CERT_FILE" -noout -checkend $((7 * 86400)) >/dev/null; then
    warn "证书 7 天内到期（$(cert_enddate "$CERT_FILE")），请确认续期正常"
  fi

  local issuer
  issuer=$(openssl x509 -in "$CERT_FILE" -noout -issuer)
  if [[ $issuer == *[Cc]loud[Ff]lare* && $issuer == *Origin* ]]; then
    log "这是 Cloudflare 源站证书，只有 Cloudflare 信任它：域名必须保持代理（橙色云朵）"
  fi
  ok "证书有效，包含 $DOMAIN，$(cert_days_left "$CERT_FILE") 天后到期"
}

check_dns() {
  if ! getent ahosts "$DOMAIN" >/dev/null 2>&1; then
    warn "域名 $DOMAIN 目前解析不到 IP，请确认 DNS 记录已添加"
  fi
}

# ---------- 运行 ----------

dc() {
  docker compose -p "$COMPOSE_PROJECT" --project-directory "$LUNATV_DIR" -f "$COMPOSE_FILE" "$@"
}

require_installed() {
  [[ -f $COMPOSE_FILE ]] || die "还没有安装（找不到 $COMPOSE_FILE），请先运行 install"
  command -v docker >/dev/null || die "找不到 docker 命令"
}

app_version() {
  local json version
  # 访问本机，不能走环境变量里配置的代理
  json=$(curl -fsS --noproxy '*' --max-time 5 "http://127.0.0.1:$APP_PORT/api/server-config" 2>/dev/null) || return 1
  version=$(sed -n 's/.*"Version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$json")
  printf '%s' "${version:-未知}"
}

wait_for_app() {
  log "等待 LunaTV 启动…"
  local i
  for ((i = 0; i < 60; i++)); do
    if app_version >/dev/null; then
      ok "LunaTV 已启动，版本 v$(app_version)（本机 127.0.0.1:$APP_PORT）"
      return 0
    fi
    sleep 2
  done
  return 1
}

start_stack() {
  log "拉取镜像…"
  dc pull || die "拉取镜像失败：请检查网络，并确认 GHCR 上的 lunatv 镜像已设为 Public"
  log "启动容器…"
  dc up -d --remove-orphans || die "启动容器失败，运行 lunatv logs 查看原因"
  if ! wait_for_app; then
    dc logs --tail 60 lunatv >&2 || true
    die "LunaTV 在 120 秒内没有正常响应，上面是最近的日志"
  fi
}

install_nginx_conf() {
  local saved='' out dump
  [[ -d $(dirname "$NGINX_CONF") ]] || die "找不到 $(dirname "$NGINX_CONF") 目录，无法写入 nginx 配置"
  if [[ -f $NGINX_CONF ]]; then
    saved=$(mktemp)
    cp -p "$NGINX_CONF" "$saved"
  fi
  render_nginx_conf | install_file "$NGINX_CONF" 644

  if ! out=$(nginx -t 2>&1); then
    restore_nginx_conf "$saved"
    die "nginx 配置检查失败，已恢复原样："$'\n'"$out"
  fi
  dump=$(nginx -T 2>/dev/null) || true
  if [[ $dump != *"# configuration file $NGINX_CONF:"* ]]; then
    restore_nginx_conf "$saved"
    die "nginx 没有加载 $NGINX_CONF：请确认 nginx.conf 的 http {} 里有 include $(dirname "$NGINX_CONF")/*.conf;"
  fi
  [[ -z $saved ]] || rm -f "$saved"
  systemctl reload nginx || die "nginx reload 失败，运行 systemctl status nginx 查看原因"
  ok "nginx 已加载 $NGINX_CONF"
}

restore_nginx_conf() {
  if [[ -n $1 ]]; then
    mv -f "$1" "$NGINX_CONF"
  else
    rm -f "$NGINX_CONF"
  fi
}

# 通过本机 nginx 访问 HTTPS（不经过 Cloudflare），结果写入 HTTPS_STATUS：ok / untrusted / failed
https_check() {
  local url="https://$DOMAIN:$PROXY_PORT/api/server-config" code
  local args=(-s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 10 --resolve "$DOMAIN:$PROXY_PORT:127.0.0.1")
  code=$(curl "${args[@]}" "$url" || true)
  if [[ $code == 200 ]]; then
    HTTPS_STATUS=ok
    return 0
  fi
  code=$(curl -k "${args[@]}" "$url" || true)
  if [[ $code == 200 ]]; then
    HTTPS_STATUS=untrusted
    return 0
  fi
  HTTPS_STATUS="failed（HTTP $code）"
  return 1
}

report_https() {
  local ok_fn=$1 warn_fn=$2 fail_fn=$3
  https_check || true
  case $HTTPS_STATUS in
    ok) "$ok_fn" "HTTPS 正常：https://$DOMAIN:$PROXY_PORT" ;;
    untrusted) "$warn_fn" "HTTPS 可用，但证书不受公共 CA 信任（Cloudflare 源站证书属于这种情况，域名保持代理即可）" ;;
    *) "$fail_fn" "通过 nginx 访问 https://$DOMAIN:$PROXY_PORT 失败：$HTTPS_STATUS，查看 /var/log/nginx/lunatv.error.log" ;;
  esac
}

# ---------- 宿主机防火墙 ----------
# nginx 直接在宿主机上监听，所以宿主机防火墙也要放行：ufw，或 Oracle Cloud 等镜像自带的 iptables 规则。
# 本脚本添加的规则都带 lunatv 注释，卸载时按注释删除，不影响其他规则。

FW_COMMENT='lunatv'

ufw_active() {
  local out
  command -v ufw >/dev/null || return 1
  out=$(ufw status 2>/dev/null) || return 1
  [[ $out == *'Status: active'* ]]
}

ufw_allows_port() {
  local out
  out=$(ufw status 2>/dev/null) || return 1
  grep -qE "^$PROXY_PORT(/tcp)?[[:space:]]+ALLOW" <<<"$out"
}

ufw_remove_ours() {
  local out nums n
  command -v ufw >/dev/null || return 0
  out=$(ufw status numbered 2>/dev/null) || return 0
  # 从后往前删，避免删除后编号变化
  nums=$(sed -n "s/^\[ *\([0-9][0-9]*\)\].*# ${FW_COMMENT}[[:space:]]*\$/\1/p" <<<"$out" | sort -rn)
  while IFS= read -r n; do
    [[ -n $n ]] || continue
    ufw --force delete "$n" >/dev/null || warn "删除 ufw 规则 #$n 失败"
  done <<<"$nums"
}

iptables_rules_file() {
  case $1 in
    iptables) echo "$IPTABLES_DIR/rules.v4" ;;
    ip6tables) echo "$IPTABLES_DIR/rules.v6" ;;
  esac
}

# INPUT 链会拦截新连接时（有 REJECT / DROP 规则，或默认策略是 DROP）返回 0
iptables_blocks() {
  local rules
  command -v "$1" >/dev/null || return 1
  rules=$("$1" -S INPUT 2>/dev/null) || return 1
  [[ $rules == *'-P INPUT DROP'* || $rules == *'-j REJECT'* || $rules == *'-j DROP'* ]]
}

iptables_allows_port() {
  local rules
  rules=$("$1" -S INPUT 2>/dev/null) || return 1
  grep -qE -- "--dport $PROXY_PORT( .*)? -j ACCEPT" <<<"$rules"
}

iptables_remove_ours() {
  local cmd=$1 rules line file
  local -a args
  if command -v "$cmd" >/dev/null && rules=$("$cmd" -S INPUT 2>/dev/null); then
    while IFS= read -r line; do
      [[ $line == "-A INPUT "*"--comment $FW_COMMENT "* ]] || continue
      read -ra args <<<"${line/#-A/-D}"
      "$cmd" "${args[@]}" || warn "删除 $cmd 规则失败：$line"
    done <<<"$rules"
  fi
  file=$(iptables_rules_file "$cmd")
  if [[ -f $file ]] && grep -q -- "--comment $FW_COMMENT " "$file"; then
    sed -i "/--comment $FW_COMMENT /d" "$file"
  fi
}

# 把放行规则插在第一条 REJECT / DROP 之前，并写进持久化文件（Oracle Cloud 镜像用 /etc/iptables/rules.v4）
iptables_open_port() {
  local cmd=$1 listing pos file
  local -a rule=(-p tcp -m tcp --dport "$PROXY_PORT" -m comment --comment "$FW_COMMENT" -j ACCEPT)
  listing=$("$cmd" -L INPUT -n --line-numbers)
  pos=$(awk '$2 == "REJECT" || $2 == "DROP" { print $1; exit }' <<<"$listing")
  if [[ -n $pos ]]; then
    "$cmd" -I INPUT "$pos" "${rule[@]}" || die "$cmd 放行 TCP $PROXY_PORT 失败"
  else
    "$cmd" -A INPUT "${rule[@]}" || die "$cmd 放行 TCP $PROXY_PORT 失败"
  fi
  ok "已在 $cmd 放行 TCP $PROXY_PORT"

  file=$(iptables_rules_file "$cmd")
  if [[ -f $file ]]; then
    awk -v rule="-A INPUT ${rule[*]}" '
      /^\*filter/ { in_filter = 1 }
      !done && in_filter && ($0 ~ /^-A INPUT .*-j (REJECT|DROP)/ || $0 == "COMMIT") { print rule; done = 1 }
      { print }
      /^COMMIT/ { in_filter = 0 }
    ' "$file" | install_file "$file" "$(stat -c %a "$file")"
    ok "已写入 $file，重启后依然有效"
  else
    warn "没有 $file，这条 $cmd 规则重启后会失效；重启后再运行一次 lunatv install 即可"
  fi
}

open_firewall() {
  local cmd changed=0
  if ufw_active; then
    ufw_remove_ours
    if ufw_allows_port; then
      ok "ufw 已放行 TCP $PROXY_PORT"
    else
      ufw allow "$PROXY_PORT/tcp" comment "$FW_COMMENT" >/dev/null || die "ufw 放行 TCP $PROXY_PORT 失败"
      ok "已在 ufw 放行 TCP $PROXY_PORT"
    fi
    return 0
  fi
  for cmd in iptables ip6tables; do
    iptables_remove_ours "$cmd"
    if [[ $cmd == ip6tables ]] && ! has_ipv6; then continue; fi
    iptables_blocks "$cmd" || continue
    if iptables_allows_port "$cmd"; then
      ok "$cmd 已放行 TCP $PROXY_PORT"
    else
      iptables_open_port "$cmd"
    fi
    changed=1
  done
  if ((changed == 0)); then
    ok "宿主机防火墙没有拦截 TCP $PROXY_PORT，无需改动"
  fi
}

close_firewall() {
  ufw_remove_ours
  iptables_remove_ours iptables
  iptables_remove_ours ip6tables
}

firewall_check() {
  local cmd
  if ufw_active; then
    if ufw_allows_port; then
      check_ok "ufw 已放行 TCP $PROXY_PORT"
    else
      check_fail "ufw 没有放行 TCP $PROXY_PORT，重新运行 lunatv install 可修复"
    fi
    return 0
  fi
  for cmd in iptables ip6tables; do
    if [[ $cmd == ip6tables ]] && ! has_ipv6; then continue; fi
    iptables_blocks "$cmd" || continue
    if iptables_allows_port "$cmd"; then
      check_ok "$cmd 已放行 TCP $PROXY_PORT"
    else
      check_fail "$cmd 会拦截 TCP $PROXY_PORT，重新运行 lunatv install 可修复"
    fi
  done
  check_warn "云服务商防火墙（如 Oracle Cloud 的 Security List）也需要放行 TCP $PROXY_PORT，脚本无法检查"
}

install_cron() {
  if [[ ! -d $(dirname "$CRON_FILE") ]]; then
    warn "没有 $(dirname "$CRON_FILE")，跳过证书 reload 定时任务"
    return 0
  fi
  render_cron | install_file "$CRON_FILE" 644
  ok "已添加定时任务 $CRON_FILE（每周 reload nginx 加载续期后的证书）"

  local tab
  tab=$(crontab -l 2>/dev/null || true)
  if [[ $tab == *"docker restart lunatv-caddy"* ]]; then
    warn "root 的 crontab 里还有 docker restart lunatv-caddy，现在不用 Caddy 了，请用 crontab -e 删掉这一行"
  fi
  if [[ $tab == *"systemctl reload nginx"* ]]; then
    log "root 的 crontab 里也有 reload nginx 的任务，和 $CRON_FILE 重复（无害），可以用 crontab -e 删掉"
  fi
}

install_self() {
  local src=${BASH_SOURCE[0]}
  if [[ ! -f $src ]]; then
    warn "脚本不是从文件运行的，没有安装 lunatv 命令。可以运行：curl -fsSL $SCRIPT_URL -o $BIN_PATH && chmod +x $BIN_PATH"
    return 0
  fi
  if [[ ! $src -ef $BIN_PATH ]]; then
    install -m 755 "$src" "$BIN_PATH" || die "无法安装 lunatv 命令到 $BIN_PATH"
  fi
  ok "已安装 lunatv 命令（$BIN_PATH）"
}

# ---------- 命令 ----------

resolve_install_settings() {
  load_state || true

  if [[ -n $OPT_DOMAIN ]]; then
    DOMAIN=$OPT_DOMAIN
  else
    ask DOMAIN '访问 LunaTV 用的域名（证书需要包含它）' "$ST_DOMAIN"
  fi
  [[ -n $DOMAIN ]] || die "缺少域名：请用 --domain 指定"
  valid_domain "$DOMAIN" || die "域名格式不对：$DOMAIN"

  if [[ -n $OPT_PROXY_PORT ]]; then
    PROXY_PORT=$OPT_PROXY_PORT
  else
    ask PROXY_PORT 'HTTPS 端口（走 Cloudflare 代理时只能用 2053/2083/2087/2096/8443/443）' \
      "${ST_PROXY_PORT:-$DEFAULT_PROXY_PORT}"
  fi
  valid_port "$PROXY_PORT" || die "端口不对：$PROXY_PORT"

  local default_cert="/root/cert/$DOMAIN/fullchain.pem" default_key="/root/cert/$DOMAIN/privkey.pem"
  if [[ $DOMAIN == "$ST_DOMAIN" && -n $ST_CERT_FILE ]]; then
    default_cert=$ST_CERT_FILE
    default_key=$ST_KEY_FILE
  fi
  if [[ -n $OPT_CERT ]]; then CERT_FILE=$OPT_CERT; else ask CERT_FILE '证书文件（fullchain）' "$default_cert"; fi
  if [[ -n $OPT_KEY ]]; then KEY_FILE=$OPT_KEY; else ask KEY_FILE '私钥文件' "$default_key"; fi
  valid_path "$CERT_FILE" || die "证书路径必须是绝对路径，且不能含空格或特殊字符：$CERT_FILE"
  valid_path "$KEY_FILE" || die "私钥路径必须是绝对路径，且不能含空格或特殊字符：$KEY_FILE"

  APP_PORT=${OPT_APP_PORT:-${ST_APP_PORT:-$DEFAULT_APP_PORT}}
  valid_port "$APP_PORT" || die "本机端口不对：$APP_PORT"
  IMAGE=${OPT_IMAGE:-${ST_IMAGE:-$DEFAULT_IMAGE}}
  valid_image "$IMAGE" || die "镜像名不对：$IMAGE"

  local current_user current_pass
  current_user=$(read_env_value USERNAME)
  current_pass=$(read_env_value PASSWORD)
  if [[ -n $OPT_USERNAME ]]; then
    ADMIN_USER=$OPT_USERNAME
  else
    ask ADMIN_USER '站长账号' "${current_user:-admin}"
  fi
  valid_username "$ADMIN_USER" || die "站长账号只能包含字母、数字和 _ . @ -，最长 32 位：$ADMIN_USER"

  if [[ -n $OPT_PASSWORD ]]; then
    ADMIN_PASS=$OPT_PASSWORD
    valid_password "$ADMIN_PASS" || die "站长密码需要 8~128 位，且不能包含空白和 \$ ' \" \\ \` #"
  elif [[ -n $current_pass ]]; then
    ADMIN_PASS=$current_pass
    log "沿用 $ENV_FILE 里现有的站长密码（要修改请加 --password）"
  else
    ask_secret ADMIN_PASS '站长密码（留空则自动生成）'
    if [[ -z $ADMIN_PASS ]]; then
      ADMIN_PASS=$(generate_password)
      PASSWORD_GENERATED=1
    fi
    valid_password "$ADMIN_PASS" || die "站长密码需要 8~128 位，且不能包含空白和 \$ ' \" \\ \` #"
  fi
}

print_install_plan() {
  section '将按以下设置安装：'
  printf '  访问地址   https://%s:%s\n' "$DOMAIN" "$PROXY_PORT"
  printf '  证书       %s\n' "$CERT_FILE"
  printf '  私钥       %s\n' "$KEY_FILE"
  printf '  站长账号   %s\n' "$ADMIN_USER"
  printf '  镜像       %s\n' "$IMAGE"
  printf '  安装目录   %s（本机端口 127.0.0.1:%s）\n' "$LUNATV_DIR" "$APP_PORT"
  printf '  nginx 配置 %s\n' "$NGINX_CONF"
  echo
}

cmd_install() {
  require_root
  section '检查系统'
  check_platform
  ensure_tools
  check_disk

  section '安装设置'
  resolve_install_settings
  print_install_plan
  confirm '确认开始安装？' || die '已取消'

  section '检查证书与端口'
  check_cert
  check_dns
  check_ports

  section '准备 Docker 与 nginx'
  ensure_docker
  check_container_names
  ensure_nginx

  section '写入配置'
  mkdir -p "$LUNATV_DIR"
  chmod 700 "$LUNATV_DIR"
  render_env | install_file "$ENV_FILE" 600
  render_compose | install_file "$COMPOSE_FILE" 644
  render_state | install_file "$STATE_FILE" 600
  ok "已写入 $ENV_FILE、$COMPOSE_FILE"

  section '启动 LunaTV'
  start_stack

  section '配置 nginx'
  install_nginx_conf
  report_https ok warn warn
  install_cron

  section '宿主机防火墙'
  open_firewall
  install_self

  section '安装完成'
  printf '  访问地址   %shttps://%s:%s%s\n' "$C_BOLD" "$DOMAIN" "$PROXY_PORT" "$C_RESET"
  printf '  站长账号   %s\n' "$ADMIN_USER"
  if ((PASSWORD_GENERATED)); then
    printf '  站长密码   %s%s%s（自动生成，请保存好；之后可用 lunatv info --show-password 查看）\n' \
      "$C_BOLD" "$ADMIN_PASS" "$C_RESET"
  fi
  cat <<EOF

下一步：
  1. 在云服务商防火墙放行 TCP $PROXY_PORT（Oracle Cloud：子网的 Security List → Ingress 规则；宿主机防火墙脚本已处理）
  2. 域名走 Cloudflare 代理时，SSL/TLS 模式用 Full (strict)
  3. 从旧服务器迁移：管理面板 → 数据迁移 → 导入备份

日常维护：lunatv status | info | update | logs | restart | uninstall（lunatv help 查看说明）
EOF
}

cmd_update() {
  require_root
  require_installed
  use_state
  local before after
  before=$(app_version || echo '未运行')
  start_stack
  docker image prune -f >/dev/null 2>&1 || true
  after=$(app_version || echo '未知')
  ok "更新完成：v$before → v$after"
}

cmd_status() {
  require_root
  require_installed
  use_state

  section '容器'
  dc ps || check_fail '无法获取容器状态'

  section 'LunaTV'
  local version
  if version=$(app_version); then
    check_ok "运行正常，版本 v$version（本机 127.0.0.1:$APP_PORT）"
  else
    check_fail "本机 127.0.0.1:$APP_PORT 没有响应，运行 lunatv logs 查看原因"
  fi

  section 'nginx'
  if systemctl is-active --quiet nginx; then check_ok 'nginx 运行中'; else check_fail 'nginx 没有运行'; fi
  if [[ -f $NGINX_CONF ]]; then check_ok "配置文件 $NGINX_CONF"; else check_fail "缺少配置文件 $NGINX_CONF，重新运行 install 可恢复"; fi
  if [[ -n $(port_listeners "$PROXY_PORT") ]]; then
    check_ok "正在监听端口 $PROXY_PORT"
  else
    check_fail "没有进程监听端口 $PROXY_PORT"
  fi
  report_https check_ok check_warn check_fail

  section '证书'
  if [[ -f $CERT_FILE ]]; then
    local days
    days=$(cert_days_left "$CERT_FILE")
    if ((days < 0)); then
      check_fail "证书已过期（$(cert_enddate "$CERT_FILE")）"
    elif ((days < 14)); then
      check_warn "证书 $days 天后到期，请确认 acme 续期正常"
    else
      check_ok "证书 $days 天后到期（$(cert_enddate "$CERT_FILE")）"
    fi
  else
    check_fail "找不到证书 $CERT_FILE"
  fi

  section '定时任务'
  if [[ -f $CRON_FILE ]]; then check_ok "$CRON_FILE（每周 reload nginx）"; else check_warn "缺少 $CRON_FILE，续期后的证书不会自动加载"; fi

  section '防火墙'
  firewall_check

  echo
  if ((PROBLEMS > 0)); then
    die "发现 $PROBLEMS 个问题"
  fi
  ok '一切正常'
}

cmd_info() {
  require_root
  require_installed
  use_state
  local user pass version volume created
  user=$(read_env_value USERNAME)
  pass=$(read_env_value PASSWORD)
  version=$(app_version || echo '未运行')
  volume=$(docker volume inspect -f '{{.Mountpoint}}' "${COMPOSE_PROJECT}_kvrocks-data" 2>/dev/null || echo '未创建')
  created=$(docker image inspect -f '{{.Created}}' "$IMAGE" 2>/dev/null | cut -c1-19 || true)

  section 'LunaTV 部署信息'
  printf '  访问地址     %s\n' "https://$DOMAIN:$PROXY_PORT"
  printf '  站长账号     %s\n' "${user:-未设置}"
  if ((SHOW_PASSWORD)); then
    printf '  站长密码     %s\n' "${pass:-未设置}"
  else
    printf '  站长密码     ********（加 --show-password 显示）\n'
  fi
  printf '  运行版本     v%s\n' "$version"
  printf '  镜像         %s%s\n' "$IMAGE" "${created:+（构建于 ${created/T/ }）}"
  printf '  安装目录     %s\n' "$LUNATV_DIR"
  printf '  环境变量     %s\n' "$ENV_FILE"
  printf '  数据卷       %s_kvrocks-data（%s）\n' "$COMPOSE_PROJECT" "$volume"
  printf '  nginx 配置   %s\n' "$NGINX_CONF"
  printf '  nginx 日志   /var/log/nginx/lunatv.access.log、lunatv.error.log\n'
  if [[ -f $CERT_FILE ]]; then
    printf '  证书         %s（%s 天后到期）\n' "$CERT_FILE" "$(cert_days_left "$CERT_FILE")"
  else
    printf '  证书         %s（文件不存在）\n' "$CERT_FILE"
  fi
  printf '  私钥         %s\n' "$KEY_FILE"
  printf '  定时任务     %s\n' "$CRON_FILE"
  printf '  安装时间     %s\n' "${ST_INSTALLED_AT:-未知}"
  cat <<EOF

提示：
  - 云服务商防火墙需要放行 TCP $PROXY_PORT
  - 域名走 Cloudflare 代理时，SSL/TLS 模式用 Full (strict)
  - 备份数据：管理面板 → 数据迁移 → 导出
EOF
}

cmd_logs() {
  require_root
  require_installed
  local service=${POSITIONAL[0]:-}
  case $service in
    '') dc logs -f --tail 100 ;;
    lunatv | app) dc logs -f --tail 100 lunatv ;;
    kvrocks | db) dc logs -f --tail 100 lunatv-kvrocks ;;
    *) die "未知服务：$service（可选 lunatv、kvrocks）" ;;
  esac
}

cmd_start() {
  require_root
  require_installed
  use_state
  dc up -d || die '启动失败，运行 lunatv logs 查看原因'
  wait_for_app || die 'LunaTV 没有正常响应，运行 lunatv logs 查看原因'
}

cmd_stop() {
  require_root
  require_installed
  dc stop || die '停止失败'
  ok '已停止（数据保留，lunatv start 可重新启动）'
}

cmd_restart() {
  require_root
  require_installed
  use_state
  dc restart || die '重启失败，运行 lunatv logs 查看原因'
  wait_for_app || die 'LunaTV 没有正常响应，运行 lunatv logs 查看原因'
}

cmd_uninstall() {
  require_root
  section '卸载 LunaTV'
  echo "  将删除：LunaTV 与 Kvrocks 容器、$NGINX_CONF、$CRON_FILE、本脚本添加的防火墙规则"
  if ((PURGE)); then
    echo "  并永久删除：数据卷（全部用户、播放记录、收藏）、$LUNATV_DIR、镜像和 lunatv 命令"
  else
    echo "  将保留：数据卷与 $LUNATV_DIR（以后重新 install 即可恢复）；要彻底删除请加 --purge"
  fi
  echo '  不会改动：Docker、nginx 本身、证书、3x-ui、acme.sh'
  echo
  confirm '确定卸载？' || die '已取消'
  if ((PURGE)) && is_interactive; then
    local reply
    ask reply '数据删除后无法恢复，输入 DELETE 确认'
    [[ $reply == DELETE ]] || die '已取消'
  fi

  if [[ -f $COMPOSE_FILE ]] && command -v docker >/dev/null; then
    if ((PURGE)); then
      dc down -v --remove-orphans --rmi all || warn '删除容器、数据卷或镜像时出错'
    else
      dc down --remove-orphans || warn '删除容器时出错'
    fi
    ok '已删除容器'
  fi
  if ((PURGE)) && command -v docker >/dev/null; then
    docker volume rm "${COMPOSE_PROJECT}_kvrocks-data" >/dev/null 2>&1 || true
  fi

  if [[ -f $NGINX_CONF ]]; then
    rm -f "$NGINX_CONF" "$NGINX_CONF.bak"
    if command -v nginx >/dev/null && systemctl is-active --quiet nginx; then
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx || warn 'nginx reload 失败'
      else
        warn 'nginx 配置检查未通过（与 LunaTV 无关），没有 reload，请运行 nginx -t 查看'
      fi
    fi
    ok "已删除 $NGINX_CONF"
  fi
  if [[ -f $CRON_FILE ]]; then
    rm -f "$CRON_FILE"
    ok "已删除 $CRON_FILE"
  fi
  close_firewall
  ok '已删除本脚本添加的防火墙规则（如有）'

  if ((PURGE)); then
    if [[ -n $LUNATV_DIR && $LUNATV_DIR != / && (-f $STATE_FILE || -f $COMPOSE_FILE) ]]; then
      rm -rf "$LUNATV_DIR"
      ok "已删除 $LUNATV_DIR"
    elif [[ -d $LUNATV_DIR ]]; then
      warn "$LUNATV_DIR 里没有安装记录，为安全起见没有删除，请手动确认"
    fi
    rm -f "$BIN_PATH"
  fi
  ok '卸载完成'
}

cmd_self_update() {
  require_root
  local tmp
  tmp=$(mktemp)
  if ! curl -fsSL "$SCRIPT_URL" -o "$tmp"; then
    rm -f "$tmp"
    die "下载失败：$SCRIPT_URL"
  fi
  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    die '下载的脚本有语法错误，已放弃更新'
  fi
  install -m 755 "$tmp" "$BIN_PATH" || die "无法写入 $BIN_PATH"
  rm -f "$tmp"
  ok "lunatv 命令已更新到 $(bash "$BIN_PATH" version)"
}

usage() {
  cat <<EOF
LunaTV 部署与维护脚本 v$SCRIPT_VERSION

用法：lunatv <命令> [选项]
      （首次安装：sudo bash lunatv.sh install）

命令：
  install       安装或重新配置（可重复运行，会沿用上次的设置和站长密码）
  update        拉取最新镜像并重启
  status        检查容器、应用、nginx、HTTPS、证书、定时任务和防火墙
  info          显示访问地址、账号、文件位置等信息
  logs [服务]   跟踪日志，服务可选 lunatv、kvrocks（默认全部）
  start | stop | restart
                启动 / 停止 / 重启容器
  uninstall     卸载（默认保留数据，--purge 彻底删除）
  self-update   更新 lunatv 命令本身
  version       显示脚本版本

install 选项（不提供时会提问，加 -y 则使用默认值）：
  --domain <域名>      访问用的域名，证书必须包含它
  --port <端口>        对外 HTTPS 端口，默认 $DEFAULT_PROXY_PORT
  --cert <文件>        证书（fullchain），默认 /root/cert/<域名>/fullchain.pem
  --key <文件>         私钥，默认 /root/cert/<域名>/privkey.pem
  --username <账号>    站长账号，默认 admin
  --password <密码>    站长密码，默认沿用现有密码或自动生成
  --app-port <端口>    LunaTV 在本机监听的端口，默认 $DEFAULT_APP_PORT
  --image <镜像>       默认 $DEFAULT_IMAGE

其他选项：
  -y, --yes            不提问、不确认（用于自动化）
  --purge              uninstall 时同时删除数据、安装目录和镜像
  --show-password      info 时显示站长密码

示例：
  sudo bash lunatv.sh install --domain tv.example.com
  lunatv status
  lunatv update
  lunatv uninstall --purge
EOF
}

# ---------- 入口 ----------

set_option() {
  case $1 in
    --domain) OPT_DOMAIN=$2 ;;
    --port) OPT_PROXY_PORT=$2 ;;
    --app-port) OPT_APP_PORT=$2 ;;
    --cert) OPT_CERT=$2 ;;
    --key) OPT_KEY=$2 ;;
    --username) OPT_USERNAME=$2 ;;
    --password) OPT_PASSWORD=$2 ;;
    --image) OPT_IMAGE=$2 ;;
  esac
}

parse_options() {
  while (($# > 0)); do
    case $1 in
      --domain | --port | --app-port | --cert | --key | --username | --password | --image)
        if (($# < 2)) || [[ -z $2 ]]; then
          die "选项 $1 需要一个值"
        fi
        set_option "$1" "$2"
        shift 2
        ;;
      --domain=* | --port=* | --app-port=* | --cert=* | --key=* | --username=* | --password=* | --image=*)
        set_option "${1%%=*}" "${1#*=}"
        shift
        ;;
      -y | --yes) ASSUME_YES=1 && shift ;;
      --purge) PURGE=1 && shift ;;
      --show-password) SHOW_PASSWORD=1 && shift ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*) die "未知选项：$1（运行 lunatv help 查看用法）" ;;
      *) POSITIONAL+=("$1") && shift ;;
    esac
  done
}

main() {
  trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
  trap 'echo >&2; die "已中断"' INT
  COMMAND=${1:-help}
  if (($# > 0)); then shift; fi
  parse_options "$@"

  case $COMMAND in
    install) cmd_install ;;
    update) cmd_update ;;
    status) cmd_status ;;
    info) cmd_info ;;
    logs) cmd_logs ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    uninstall) cmd_uninstall ;;
    self-update) cmd_self_update ;;
    version) echo "$SCRIPT_VERSION" ;;
    help | -h | --help) usage ;;
    *) die "未知命令：$COMMAND（运行 lunatv help 查看用法）" ;;
  esac
}

COMMAND=''
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
