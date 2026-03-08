#!/usr/bin/env bash
################################################################################
# Auto-Seedbox-Apps (ASP-Apps)
# 独立安装 Vertex / FileBrowser，不安装 qBittorrent
#
# 支持:
#   - 仅安装 Vertex
#   - 仅安装 FileBrowser（含 MediaInfo + Screenshot）
#   - 同时安装 Vertex + FileBrowser
#
# 参数:
#   -u <user>      WebUI / 面板用户名
#   -p <pass>      统一密码（必须 >= 12 位）
#   -v             安装 Vertex
#   -f             安装 FileBrowser
#   -r <path>      FileBrowser 根目录（可选）
#                   - 若填写：只挂载该目录到 /srv
#                   - 若不填：按主脚本方式挂载整个 $HB 到 /srv
#   -o             自定义端口（交互式）
#   -d <url>       Vertex 备份 zip/tar.gz 下载直链（可选）
#   -k <pass>      Vertex 备份解压密码（可选）
#   --uninstall    卸载本脚本安装的 VT/FB
#   -h, --help     查看帮助
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ================= 基础配置 =================
SCRIPT_VERSION="3.0.0"
SCRIPT_NAME="Auto-Seedbox-Apps"
LOG_FILE="/tmp/asp_apps_install.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ACTION="install"

APP_USER=""
APP_PASS=""

DO_VX=false
DO_FB=false
CUSTOM_PORT=false

VX_PORT=3000
FB_PORT=8081
MI_PORT=8082
SS_PORT=8083

VX_RESTORE_URL=""
VX_ZIP_PASS=""

BASE_DIR="/opt/asp-apps"
VX_DIR="${BASE_DIR}/vertex"
FB_DIR="${BASE_DIR}/filebrowser"
TEMP_DIR="$(mktemp -d -t asp-apps-XXXXXX)"

VX_DATA_DIR="${VX_DIR}/data"
VX_CONTAINER_NAME="vertex"
FB_CONTAINER_NAME="filebrowser"

VERTEX_IMAGE="${VERTEX_IMAGE:-lswl/vertex:stable}"
FILEBROWSER_IMAGE="${FILEBROWSER_IMAGE:-filebrowser/filebrowser:latest}"

NGINX_FB_CONF="/etc/nginx/conf.d/asp-filebrowser.conf"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

HB="/root"
FB_ROOT=""
FB_SCAN_BASE=""
FB_MOUNT_SOURCE=""
FB_MODE=""

trap 'rm -rf "$TEMP_DIR"' EXIT

# ================= 输出函数 =================
log_info()  { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE" >&2; }
log_ok()    { echo -e "${CYAN}[ OK ]${NC} $*" | tee -a "$LOG_FILE" >&2; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; exit 1; }

section() {
  echo
  echo -e "${BLUE}================================================================${NC}"
  echo -e "${BOLD}$*${NC}"
  echo -e "${BLUE}================================================================${NC}"
}

banner() {
  clear || true
  echo -e "${CYAN}        ___   _____   ___  ${NC}"
  echo -e "${CYAN}       / _ | / __/ |/ _ \\ ${NC}"
  echo -e "${CYAN}      / __ |_\\ \\  / ___/ ${NC}"
  echo -e "${CYAN}     /_/ |_/___/ /_/     ${NC}"
  echo -e "${BLUE}================================================================${NC}"
  echo -e "${PURPLE}     ✦ ${SCRIPT_NAME} v${SCRIPT_VERSION} ✦${NC}"
  echo -e "${PURPLE}     ✦               作者：Supcutie              ✦${NC}"
  echo -e "${GREEN}    🚀 一键部署 Vertex + FileBrowser Apps 引擎${NC}"
  echo -e "${YELLOW}   💡 GitHub：https://github.com/yimouleng/Auto-Seedbox-PT ${NC}"
  echo -e "${BLUE}================================================================${NC}"
  echo ""
}

spinner_run() {
  local msg="$1"
  shift

  "$@" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  local delay=0.10
  local spin='|/-\'

  printf "\e[?25l"
  while kill -0 "$pid" 2>/dev/null; do
    for c in $(echo "$spin" | fold -w1); do
      printf "\r\033[K ${CYAN}[%s]${NC} %s..." "$c" "$msg"
      sleep "$delay"
      kill -0 "$pid" 2>/dev/null || break
    done
  done

  local ret=0
  wait "$pid" || ret=$?
  printf "\e[?25h"

  if [[ $ret -eq 0 ]]; then
    printf "\r\033[K ${GREEN}[√]${NC} %s 完成!\n" "$msg"
  else
    printf "\r\033[K ${RED}[X]${NC} %s 失败! 请查看日志: %s\n" "$msg" "$LOG_FILE"
  fi

  return $ret
}

usage() {
  cat <<'EOF'
用法:
  bash auto_seedbox_apps.sh -u 用户名 -p 密码 [-v] [-f] [-r 目录] [-o] [-d URL] [-k ZIP密码]
  bash auto_seedbox_apps.sh --uninstall

参数:
  -u   WebUI / 面板用户名
  -p   统一密码（必须 >= 12 位）
  -v   安装 Vertex
  -f   安装 FileBrowser
  -r   FileBrowser 根目录（可选）
  -o   自定义端口（交互式）
  -d   Vertex 备份 zip/tar.gz 下载直链（可选）
  -k   Vertex 备份解压密码（可选）
  --uninstall  卸载 Vertex / FileBrowser
  -h, --help   查看帮助

示例:
  bash auto_seedbox_apps.sh -u admin -p 'your-strong-pass' -v
  bash auto_seedbox_apps.sh -u admin -p 'your-strong-pass' -f
  bash auto_seedbox_apps.sh -u admin -p 'your-strong-pass' -f -r /data/downloads
  bash auto_seedbox_apps.sh -u admin -p 'your-strong-pass' -v -f -o
EOF
}

# ================= 通用函数 =================
ensure_cmd() {
  command -v "$1" >/dev/null 2>&1
}

confirm() {
  local prompt="${1:-确认继续吗？}"
  local answer
  read -r -p " ▶ ${prompt} [y/N]: " answer < /dev/tty || true
  case "${answer:-N}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

validate_pass() {
  local p="$1"
  [[ ${#p} -ge 12 ]] || log_err "密码长度必须 >= 12 位。"
}

check_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || log_err "请使用 root 运行此脚本。"
}

check_system() {
  [[ -f /etc/os-release ]] || log_err "无法识别系统。"
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) log_err "当前仅支持 Debian / Ubuntu。" ;;
  esac
}

wait_for_apt_lock() {
  local max_wait=300
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    log_warn "等待 apt/dpkg 锁释放..."
    sleep 2
    waited=$((waited + 2))
    [[ $waited -ge $max_wait ]] && log_err "等待 apt 锁超时。"
  done
}

install_pkg_if_missing() {
  local pkgs=()
  local p
  for p in "$@"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      pkgs+=("$p")
    fi
  done

  if [[ ${#pkgs[@]} -gt 0 ]]; then
    wait_for_apt_lock
    export DEBIAN_FRONTEND=noninteractive
    spinner_run "更新 apt 索引" apt-get update -y
    spinner_run "安装依赖 ${pkgs[*]}" apt-get install -y "${pkgs[@]}"
  fi
}

download_file() {
  local url="$1"
  local out="$2"
  spinner_run "下载 $(basename "$out")" \
    wget -q --retry-connrefused --tries=3 --timeout=30 -O "$out" "$url" \
    || log_err "下载失败: $url"
}

check_port_occupied() {
  local port="$1"
  if ensure_cmd ss; then
    ss -tuln | grep -qE "[:.]${port}[[:space:]]" && return 0
  elif ensure_cmd netstat; then
    netstat -tuln | grep -q ":${port}[[:space:]]" && return 0
  fi
  return 1
}

get_input_port() {
  local prompt="$1"
  local default_port="$2"
  local port=""
  while true; do
    read -r -p " ▶ ${prompt} [默认 ${default_port}]: " port < /dev/tty
    port="${port:-$default_port}"
    [[ "$port" =~ ^[0-9]+$ ]] || { log_warn "请输入合法端口号。"; continue; }
    (( port >= 1 && port <= 65535 )) || { log_warn "端口范围必须在 1-65535。"; continue; }
    if check_port_occupied "$port"; then
      log_warn "端口 ${port} 已被占用，请重新输入。"
      continue
    fi
    echo "$port"
    return 0
  done
}

open_port() {
  local port="$1"
  local proto="${2:-tcp}"

  if ensure_cmd ufw && systemctl is-active --quiet ufw; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
  fi

  if ensure_cmd firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --add-port="${port}/${proto}" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

get_public_ip() {
  local ip
  ip="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  echo "${ip:-YOUR_SERVER_IP}"
}

# ================= 参数解析 =================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u)
        [[ $# -ge 2 ]] || log_err "-u 缺少参数。"
        APP_USER="$2"
        shift 2
        ;;
      -p)
        [[ $# -ge 2 ]] || log_err "-p 缺少参数。"
        APP_PASS="$2"
        shift 2
        ;;
      -v)
        DO_VX=true
        shift
        ;;
      -f)
        DO_FB=true
        shift
        ;;
      -r)
        [[ $# -ge 2 ]] || log_err "-r 缺少参数。"
        FB_ROOT="$2"
        shift 2
        ;;
      -o)
        CUSTOM_PORT=true
        shift
        ;;
      -d)
        [[ $# -ge 2 ]] || log_err "-d 缺少参数。"
        VX_RESTORE_URL="$2"
        shift 2
        ;;
      -k)
        [[ $# -ge 2 ]] || log_err "-k 缺少参数。"
        VX_ZIP_PASS="$2"
        shift 2
        ;;
      --uninstall)
        ACTION="uninstall"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_err "未知参数: $1"
        ;;
    esac
  done
}

validate_args() {
  if [[ "$ACTION" == "uninstall" ]]; then
    return 0
  fi

  [[ -n "$APP_USER" ]] || log_err "必须提供 -u 用户名。"
  [[ -n "$APP_PASS" ]] || log_err "必须提供 -p 密码。"
  validate_pass "$APP_PASS"

  if [[ "$DO_VX" != true && "$DO_FB" != true ]]; then
    log_err "至少需要指定 -v 或 -f。"
  fi

  if [[ -n "$VX_ZIP_PASS" && -z "$VX_RESTORE_URL" ]]; then
    log_err "使用 -k 时必须同时提供 -d。"
  fi

  if [[ "$DO_FB" != true && -n "$FB_ROOT" ]]; then
    log_warn "检测到 -r 参数，但未指定 -f，FileBrowser 根目录设置将被忽略。"
  fi
}

# ================= 用户与目录 =================
setup_user() {
  if [[ "$APP_USER" == "root" ]]; then
    HB="/root"
    log_info "使用 root 作为应用目录归属用户。"
    return
  fi

  if id "$APP_USER" >/dev/null 2>&1; then
    log_info "检测到系统用户 ${APP_USER}，直接复用。"
  else
    log_info "创建系统用户: ${APP_USER}"
    if getent group "$APP_USER" >/dev/null 2>&1; then
      useradd -m -s /bin/bash -g "$APP_USER" "$APP_USER"
    else
      useradd -m -s /bin/bash "$APP_USER"
    fi
  fi

  HB="$(eval echo "~$APP_USER")"
  [[ -n "$HB" && -d "$HB" ]] || log_err "无法确定用户 ${APP_USER} 的 home 目录。"
}

prepare_dirs() {
  mkdir -p "$BASE_DIR"

  if [[ "$DO_VX" == true ]]; then
    mkdir -p "$VX_DATA_DIR"
    chown -R "$APP_USER:$APP_USER" "$VX_DIR" || true
  fi

  if [[ "$DO_FB" == true ]]; then
    mkdir -p "$FB_DIR"
    if [[ -n "$FB_ROOT" ]]; then
      FB_MODE="custom-root"
      mkdir -p "$FB_ROOT"
      FB_SCAN_BASE="$FB_ROOT"
      FB_MOUNT_SOURCE="$FB_ROOT"
    else
      FB_MODE="home-root"
      FB_SCAN_BASE="$HB"
      FB_MOUNT_SOURCE="$HB"
      FB_ROOT="$HB"
    fi

    mkdir -p "${FB_DIR}/config" "${FB_DIR}/database"
    chown -R "$APP_USER:$APP_USER" "$FB_DIR" || true
    chown -R "$APP_USER:$APP_USER" "$FB_MOUNT_SOURCE" || true
  fi
}

# ================= Docker / 依赖 =================
ensure_base_dependencies() {
  install_pkg_if_missing ca-certificates curl wget gnupg lsb-release jq unzip tar python3 net-tools mediainfo ffmpeg nginx
}

ensure_docker() {
  section "检查 Docker 环境"

  if ensure_cmd docker; then
    log_ok "Docker 已安装。"
  else
    log_warn "未检测到 Docker，开始安装..."

    install_pkg_if_missing apt-transport-https software-properties-common
    mkdir -p /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
      curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    . /etc/os-release
    cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable
EOF

    wait_for_apt_lock
    spinner_run "更新 apt 索引" apt-get update -y
    spinner_run "安装 Docker" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl restart docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || log_err "Docker 服务不可用，请检查系统状态。"
  log_ok "Docker 环境正常。"
}

# ================= Vertex =================
restore_vertex_backup() {
  [[ -n "$VX_RESTORE_URL" ]] || return 0

  section "恢复 Vertex 备份"

  local filename
  filename="$(basename "$VX_RESTORE_URL")"
  local archive="${TEMP_DIR}/${filename}"

  download_file "$VX_RESTORE_URL" "$archive"

  rm -rf "${VX_DATA_DIR:?}/"*
  mkdir -p "$VX_DATA_DIR"

  case "$archive" in
    *.zip)
      if [[ -n "$VX_ZIP_PASS" ]]; then
        spinner_run "解压 Vertex ZIP 备份" unzip -qo -P "$VX_ZIP_PASS" "$archive" -d "$VX_DATA_DIR"
      else
        spinner_run "解压 Vertex ZIP 备份" unzip -qo "$archive" -d "$VX_DATA_DIR"
      fi
      ;;
    *.tar.gz|*.tgz)
      spinner_run "解压 Vertex tar.gz 备份" tar -xzf "$archive" -C "$VX_DATA_DIR"
      ;;
    *.tar)
      spinner_run "解压 Vertex tar 备份" tar -xf "$archive" -C "$VX_DATA_DIR"
      ;;
    *)
      log_err "暂不支持的备份格式，仅支持 zip/tar/tar.gz/tgz。"
      ;;
  esac

  chown -R "$APP_USER:$APP_USER" "$VX_DATA_DIR" || true
  log_ok "Vertex 备份恢复完成。"
}

reset_vertex_password() {
  section "处理 Vertex 密码"

  local changed=0
  local escaped_pass
  local vx_pass_md5

  escaped_pass="$(printf '%s' "$APP_PASS" | sed 's/[\/&]/\\&/g')"
  vx_pass_md5="$(printf '%s' "$APP_PASS" | md5sum | awk '{print $1}')"

  local set_file="${VX_DATA_DIR}/setting.json"
  if [[ -f "$set_file" ]]; then
    python3 - "$set_file" "$APP_USER" "$vx_pass_md5" <<'PY'
import json, sys
p, u, pw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(p, 'r', encoding='utf-8') as f:
        d = json.load(f)
except Exception:
    d = {}
d["username"] = u
d["password"] = pw
d["port"] = int(d.get("port", 3000) or 3000)
with open(p, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
    changed=1
  fi

  local candidates=(
    "${VX_DATA_DIR}/config.json"
    "${VX_DATA_DIR}/setting.json"
    "${VX_DATA_DIR}/settings.json"
    "${VX_DATA_DIR}/app/config.json"
    "${VX_DATA_DIR}/data/config.json"
    "${VX_DATA_DIR}/data/setting.json"
  )

  local f
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      if grep -qE '"username"[[:space:]]*:' "$f"; then
        sed -i -E "s/(\"username\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1${APP_USER}\2/g" "$f" || true
        changed=1
      fi
      if grep -qE '"password"[[:space:]]*:' "$f"; then
        sed -i -E "s/(\"password\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1${escaped_pass}\2/g" "$f" || true
        changed=1
      fi
      if grep -qE '"adminPassword"[[:space:]]*:' "$f"; then
        sed -i -E "s/(\"adminPassword\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1${escaped_pass}\2/g" "$f" || true
        changed=1
      fi
    fi
  done

  chown -R "$APP_USER:$APP_USER" "$VX_DIR" || true

  if [[ $changed -eq 1 ]]; then
    log_ok "已尝试更新 Vertex 登录配置。"
  else
    log_warn "未识别到 Vertex 明确密码配置文件。"
    log_warn "若你的 Vertex 数据结构变更，请按实际情况补强 reset_vertex_password()。"
  fi
}

install_vertex() {
  section "部署 Vertex"

  mkdir -p "$VX_DIR"
  docker rm -f "$VX_CONTAINER_NAME" >/dev/null 2>&1 || true

  spinner_run "拉取 Vertex 镜像" docker pull "$VERTEX_IMAGE"
  spinner_run "启动 Vertex 容器" docker run -d \
    --name "$VX_CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${VX_PORT}:3000" \
    -v "${VX_DIR}:/vertex" \
    -e TZ="${TIMEZONE}" \
    "$VERTEX_IMAGE"

  open_port "$VX_PORT"
  log_ok "Vertex 已启动。"
}

vertex_post_check() {
  if docker ps --format '{{.Names}}' | grep -qx "$VX_CONTAINER_NAME"; then
    log_ok "Vertex 容器运行正常。"
  else
    log_warn "Vertex 容器未处于运行状态，请执行以下命令排查："
    echo "  docker logs ${VX_CONTAINER_NAME} --tail 200"
  fi
}

# ================= FileBrowser 增强 =================
install_fb_frontend_assets() {
  section "部署 FileBrowser 前端增强资源"

  local JS_REMOTE_URL="https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/refs/heads/main/asp-mediainfo.js"
  local SS_JS_URL="https://raw.githubusercontent.com/yimouleng/Auto-Seedbox-PT/refs/heads/main/asp-screenshot.js"

  spinner_run "拉取 MediaInfo 前端扩展" \
    sh -c "wget -qO /usr/local/bin/asp-mediainfo.js \"${JS_REMOTE_URL}?v=$(date +%s%N)\""

  spinner_run "拉取 SweetAlert2" \
    wget -qO /usr/local/bin/sweetalert2.all.min.js \
    "https://cdn.jsdelivr.net/npm/sweetalert2@11/dist/sweetalert2.all.min.js"

  spinner_run "拉取 Screenshot 截图扩展" \
    sh -c "wget -qO /usr/local/bin/asp-screenshot.js \"${SS_JS_URL}?v=$(date +%s%N)\""

  chmod 644 /usr/local/bin/asp-mediainfo.js /usr/local/bin/asp-screenshot.js /usr/local/bin/sweetalert2.all.min.js
}

write_mediainfo_backend() {
  cat > /usr/local/bin/asp-mediainfo.py << 'EOF_PY'
import http.server, socketserver, urllib.parse, subprocess, json, os, sys
PORT = int(sys.argv[2])
BASE_DIR = sys.argv[1]

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/mi':
            query = urllib.parse.parse_qs(parsed.query)
            file_path = query.get('file', [''])[0].lstrip('/')
            full_path = os.path.abspath(os.path.join(BASE_DIR, file_path))

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()

            if not full_path.startswith(os.path.abspath(BASE_DIR)) or not os.path.isfile(full_path):
                self.wfile.write(json.dumps({"error": "非法路径或文件不存在"}).encode('utf-8'))
                return

            try:
                res = subprocess.run(['mediainfo', '--Output=JSON', full_path], capture_output=True, text=True)
                try:
                    json.loads(res.stdout)
                    self.wfile.write(res.stdout.encode('utf-8'))
                    return
                except:
                    pass

                res_text = subprocess.run(['mediainfo', full_path], capture_output=True, text=True)
                lines = res_text.stdout.split('\n')
                tracks = []
                current_track = {}
                for line in lines:
                    line = line.strip()
                    if not line:
                        if current_track:
                            tracks.append(current_track)
                            current_track = {}
                        continue
                    if ':' not in line and '@type' not in current_track:
                        current_track['@type'] = line
                    elif ':' in line:
                        k, v = line.split(':', 1)
                        current_track[k.strip()] = v.strip()
                if current_track:
                    tracks.append(current_track)

                self.wfile.write(json.dumps({"media": {"track": tracks}}).encode('utf-8'))

            except Exception as e:
                self.wfile.write(json.dumps({"error": str(e)}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
EOF_PY
  chmod +x /usr/local/bin/asp-mediainfo.py
}

write_screenshot_backend() {
  cat > /usr/local/bin/asp-screenshot.py << 'EOF_PY_SS'
import http.server, socketserver, urllib.parse, subprocess, json, os, sys, time, shutil, uuid, zipfile

PORT = int(sys.argv[2])
BASE_DIR = sys.argv[1]
OUT_ROOT = "/tmp/asp_screens"

def safe_join(base, rel):
    rel = (rel or "").lstrip("/")
    full = os.path.abspath(os.path.join(base, rel))
    base_abs = os.path.abspath(base)
    if not full.startswith(base_abs + os.sep) and full != base_abs:
        return None
    return full

def cleanup_old(max_age_sec=48*3600, max_dirs=200):
    try:
        if not os.path.isdir(OUT_ROOT):
            return
        now = time.time()
        items = []
        for name in os.listdir(OUT_ROOT):
            p = os.path.join(OUT_ROOT, name)
            if os.path.isdir(p):
                try:
                    st = os.stat(p)
                    items.append((st.st_mtime, p))
                except Exception:
                    pass
        items.sort()
        removed = 0
        for mtime, p in items:
            if removed >= 40:
                break
            if (now - mtime) > max_age_sec:
                shutil.rmtree(p, ignore_errors=True)
                removed += 1
        if len(items) > max_dirs:
            for _, p in items[: max(0, len(items) - max_dirs)]:
                shutil.rmtree(p, ignore_errors=True)
    except Exception:
        pass

def ffprobe_meta(path):
    meta = {"width": None, "height": None, "duration": None}
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=12
        )
        s = (r.stdout or "").strip()
        if s:
            meta["duration"] = float(s)
    except Exception:
        pass
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height",
             "-of", "json", path],
            capture_output=True, text=True, timeout=12
        )
        j = json.loads(r.stdout or "{}")
        streams = j.get("streams") or []
        if streams:
            meta["width"] = int(streams[0].get("width")) if streams[0].get("width") else None
            meta["height"] = int(streams[0].get("height")) if streams[0].get("height") else None
    except Exception:
        pass
    return meta

def make_timestamps(dur, n, head_pct, tail_pct):
    if not dur or dur <= 0 or n <= 0:
        return [1.0] * n
    if n == 1:
        return [max(0.0, dur * 0.5)]
    head = max(0.0, min(head_pct, 49.0)) / 100.0
    tail = max(0.0, min(tail_pct, 49.0)) / 100.0
    start = dur * head
    end = dur * (1.0 - tail)
    if end <= start + 1.0:
        start = 0.0
        end = max(1.0, dur * 0.9)
    step = (end - start) / (n - 1)
    return [max(0.0, start + i * step) for i in range(n)]

def make_zip(out_dir, files, zip_name="screenshots.zip"):
    zip_path = os.path.join(out_dir, zip_name)
    try:
        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for f in files:
                fp = os.path.join(out_dir, f)
                if os.path.isfile(fp):
                    z.write(fp, arcname=f)
        if os.path.isfile(zip_path) and os.path.getsize(zip_path) > 0:
            return zip_name
    except Exception:
        pass
    return None

class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, payload):
        b = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/api/ss":
            self._send(404, {"error": "not found"})
            return

        qs = urllib.parse.parse_qs(parsed.query)
        rel = qs.get("file", [""])[0]

        def geti(key, default):
            try:
                return int(qs.get(key, [str(default)])[0] or default)
            except Exception:
                return default

        probe = (qs.get("probe", ["0"])[0] or "0").strip()

        full = safe_join(BASE_DIR, rel)
        if not full or not os.path.isfile(full):
            self._send(400, {"error": "非法路径或文件不存在"})
            return

        if probe in ("1", "true", "yes"):
            meta = ffprobe_meta(full)
            self._send(200, {"meta": meta})
            return

        n = geti("n", 6)
        width = geti("width", 1280)
        head = geti("head", 5)
        tail = geti("tail", 5)
        fmt = (qs.get("fmt", ["jpg"])[0] or "jpg").lower()
        zip_on = (qs.get("zip", ["1"])[0] or "1").strip()

        n = max(1, min(n, 20))
        width = max(320, min(width, 3840))
        head = max(0, min(head, 49))
        tail = max(0, min(tail, 49))
        if fmt not in ("jpg", "jpeg", "png"):
            fmt = "jpg"
        make_zip_on = zip_on not in ("0", "false", "no")

        os.makedirs(OUT_ROOT, exist_ok=True)
        cleanup_old()

        token = uuid.uuid4().hex
        out_dir = os.path.join(OUT_ROOT, token)
        os.makedirs(out_dir, exist_ok=True)

        meta = ffprobe_meta(full)
        dur = meta.get("duration")
        ts = make_timestamps(dur, n, head, tail)

        files = []
        for i, t in enumerate(ts, start=1):
            out_name = f"{i}.{fmt}"
            out_path = os.path.join(out_dir, out_name)
            vf = f"scale={width}:-2"
            cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error",
                   "-ss", f"{t:.3f}", "-i", full,
                   "-frames:v", "1", "-an",
                   "-vf", vf]
            if fmt in ("jpg", "jpeg"):
                cmd += ["-q:v", "2"]
            cmd += ["-y", out_path]
            try:
                subprocess.run(cmd, timeout=35, check=True)
                if os.path.isfile(out_path) and os.path.getsize(out_path) > 0:
                    files.append(out_name)
            except Exception:
                pass

        if not files:
            try:
                shutil.rmtree(out_dir, ignore_errors=True)
            except Exception:
                pass
            self._send(500, {"error": "截图失败：ffmpeg 执行失败或文件不支持"})
            return

        zip_file = make_zip(out_dir, files) if make_zip_on else None

        payload = {
            "base": f"/__asp_ss__/{token}/",
            "files": files,
            "zip": zip_file,
            "params": {"n": n, "width": width, "head": head, "tail": tail, "fmt": fmt},
            "meta": meta
        }
        self._send(200, payload)

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
EOF_PY_SS
  chmod +x /usr/local/bin/asp-screenshot.py
}

install_mediainfo_service() {
  write_mediainfo_backend

  cat > /etc/systemd/system/asp-mediainfo.service << EOF
[Unit]
Description=ASP MediaInfo API Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/asp-mediainfo.py "$FB_SCAN_BASE" $MI_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable asp-mediainfo.service >/dev/null 2>&1 || true
  systemctl restart asp-mediainfo.service
}

install_screenshot_service() {
  write_screenshot_backend

  cat > /etc/systemd/system/asp-screenshot.service << EOF
[Unit]
Description=ASP Screenshot API Service (ffmpeg)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/asp-screenshot.py "$FB_SCAN_BASE" $SS_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable asp-screenshot.service >/dev/null 2>&1 || true
  systemctl restart asp-screenshot.service
}

install_fb_nginx_proxy() {
  section "配置 FileBrowser Nginx 代理"

  cat > "$NGINX_FB_CONF" << EOF
server {
    listen $FB_PORT;
    server_name _;
    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:18081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Accept-Encoding "";
        sub_filter '</body>' '<script src="/asp-mediainfo.js"></script><script src="/asp-screenshot.js"></script></body>';
        sub_filter_once on;
    }

    location = /asp-mediainfo.js {
        alias /usr/local/bin/asp-mediainfo.js;
        add_header Content-Type "application/javascript; charset=utf-8";
    }

    location = /sweetalert2.all.min.js {
        alias /usr/local/bin/sweetalert2.all.min.js;
        add_header Content-Type "application/javascript; charset=utf-8";
    }

    location = /asp-screenshot.js {
        alias /usr/local/bin/asp-screenshot.js;
        add_header Content-Type "application/javascript; charset=utf-8";
        add_header Cache-Control "no-store";
    }

    location /api/ss {
        proxy_pass http://127.0.0.1:$SS_PORT;
    }

    location /__asp_ss__/ {
        alias /tmp/asp_screens/;
        autoindex off;
        add_header Cache-Control "no-store";
    }

    location /api/mi {
        proxy_pass http://127.0.0.1:$MI_PORT;
    }
}
EOF

  nginx -t >/dev/null 2>&1 || log_err "Nginx 配置校验失败，请检查 $NGINX_FB_CONF"
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
}

install_filebrowser() {
  section "部署 FileBrowser"

  docker rm -f "$FB_CONTAINER_NAME" >/dev/null 2>&1 || true

  rm -rf "${FB_DIR}"
  mkdir -p "${FB_DIR}/config" "${FB_DIR}/database"

  install_fb_frontend_assets
  install_mediainfo_service
  install_screenshot_service
  install_fb_nginx_proxy

  spinner_run "拉取 FileBrowser 镜像" docker pull "$FILEBROWSER_IMAGE"

  spinner_run "初始化 FileBrowser 数据库" \
    sh -c "docker run --rm --user 0:0 \
      -v \"${FB_DIR}/database\":/database \
      ${FILEBROWSER_IMAGE} \
      -d /database/filebrowser.db config init >/dev/null 2>&1 || true"

  spinner_run "创建 FileBrowser 管理员" \
    sh -c "docker run --rm --user 0:0 \
      -v \"${FB_DIR}/database\":/database \
      ${FILEBROWSER_IMAGE} \
      -d /database/filebrowser.db users add \"${APP_USER}\" \"${APP_PASS}\" --perm.admin >/dev/null 2>&1 || true"

  spinner_run "启动 FileBrowser 容器" docker run -d \
    --name "$FB_CONTAINER_NAME" \
    --restart unless-stopped \
    --user 0:0 \
    -v "${FB_MOUNT_SOURCE}:/srv" \
    -v "${FB_DIR}/database:/database" \
    -v "${FB_DIR}/config:/config" \
    -p 127.0.0.1:18081:80 \
    "$FILEBROWSER_IMAGE" \
    -d /database/filebrowser.db

  systemctl daemon-reload
  systemctl enable asp-mediainfo.service asp-screenshot.service nginx >/dev/null 2>&1 || true
  systemctl restart asp-mediainfo.service
  systemctl restart asp-screenshot.service
  systemctl restart nginx

  open_port "$FB_PORT"
  log_ok "FileBrowser 已启动（含 MediaInfo + Screenshot）。"
}

filebrowser_post_check() {
  if docker ps --format '{{.Names}}' | grep -qx "$FB_CONTAINER_NAME"; then
    log_ok "FileBrowser 容器运行正常。"
  else
    log_warn "FileBrowser 容器未处于运行状态，请执行以下命令排查："
    echo "  docker logs ${FB_CONTAINER_NAME} --tail 200"
  fi
}

# ================= 端口处理 =================
handle_ports() {
  section "检查端口"

  if [[ "$CUSTOM_PORT" == true ]]; then
    [[ "$DO_VX" == true ]] && VX_PORT="$(get_input_port '请输入 Vertex 端口' "$VX_PORT")"
    [[ "$DO_FB" == true ]] && FB_PORT="$(get_input_port '请输入 FileBrowser 端口' "$FB_PORT")"
  else
    if [[ "$DO_VX" == true ]] && check_port_occupied "$VX_PORT"; then
      log_err "默认 Vertex 端口 ${VX_PORT} 已被占用，请改用 -o。"
    fi
    if [[ "$DO_FB" == true ]] && check_port_occupied "$FB_PORT"; then
      log_err "默认 FileBrowser 端口 ${FB_PORT} 已被占用，请改用 -o。"
    fi
  fi

  while check_port_occupied "$MI_PORT"; do
    MI_PORT=$((MI_PORT + 1))
  done
  while check_port_occupied "$SS_PORT"; do
    SS_PORT=$((SS_PORT + 1))
  done

  if [[ "$DO_VX" == true && "$DO_FB" == true && "$VX_PORT" == "$FB_PORT" ]]; then
    log_err "Vertex 与 FileBrowser 端口不能相同。"
  fi

  log_ok "端口检查通过。"
}

# ================= 卸载 =================
uninstall_apps() {
  section "卸载模式"

  echo "即将移除以下资源："
  echo "  - 容器: ${VX_CONTAINER_NAME}, ${FB_CONTAINER_NAME}"
  echo "  - 目录: ${VX_DIR}, ${FB_DIR}"
  echo "  - 服务: asp-mediainfo.service, asp-screenshot.service"
  echo "  - Nginx: ${NGINX_FB_CONF}"
  echo
  echo "不会自动删除："
  echo "  - 自定义 -r 指定的目录"
  echo "  - 主脚本安装的其它组件"
  echo

  confirm "确认开始卸载吗？" || {
    log_warn "用户取消卸载。"
    exit 0
  }

  docker rm -f "$VX_CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm -f "$FB_CONTAINER_NAME" >/dev/null 2>&1 || true

  systemctl stop asp-mediainfo.service 2>/dev/null || true
  systemctl disable asp-mediainfo.service 2>/dev/null || true
  systemctl stop asp-screenshot.service 2>/dev/null || true
  systemctl disable asp-screenshot.service 2>/dev/null || true

  rm -f /etc/systemd/system/asp-mediainfo.service
  rm -f /etc/systemd/system/asp-screenshot.service
  rm -f /usr/local/bin/asp-mediainfo.py
  rm -f /usr/local/bin/asp-screenshot.py
  rm -f /usr/local/bin/asp-mediainfo.js
  rm -f /usr/local/bin/asp-screenshot.js
  rm -f /usr/local/bin/sweetalert2.all.min.js
  rm -f "$NGINX_FB_CONF"

  systemctl daemon-reload
  systemctl restart nginx >/dev/null 2>&1 || true

  rm -rf "$VX_DIR" "$FB_DIR"

  log_ok "卸载完成。"
  echo
  echo "如需删除 FileBrowser 实际数据目录，请手动执行："
  echo "  rm -rf <你的 -r 目录>"
}

# ================= 总结输出 =================
show_plan() {
  section "安装计划"

  echo "执行模式:"
  [[ "$DO_VX" == true ]] && echo "  - 安装 Vertex"
  [[ "$DO_FB" == true ]] && echo "  - 安装 FileBrowser"

  echo
  echo "基础信息:"
  echo "  - 用户名          : ${APP_USER}"
  echo "  - 安装目录        : ${BASE_DIR}"
  [[ "$DO_VX" == true ]] && echo "  - Vertex 端口     : ${VX_PORT}"
  [[ "$DO_FB" == true ]] && echo "  - FileBrowser 端口: ${FB_PORT}"

  if [[ "$DO_FB" == true ]]; then
    if [[ "$FB_MODE" == "custom-root" ]]; then
      echo "  - FB 模式         : 自定义根目录"
      echo "  - FB 根目录       : ${FB_ROOT}"
    else
      echo "  - FB 模式         : 主脚本目录方式"
      echo "  - FB 根目录       : ${HB}"
    fi
  fi

  if [[ -n "$VX_RESTORE_URL" ]]; then
    echo "  - Vertex 备份     : ${VX_RESTORE_URL}"
  fi
}

summary() {
  local ip
  ip="$(get_public_ip)"

  section "安装完成"

  if [[ "$DO_VX" == true ]]; then
    echo -e " Vertex URL           : ${CYAN}http://${ip}:${VX_PORT}${NC}"
    echo -e " Vertex 用户          : ${CYAN}${APP_USER}${NC}"
    echo -e " Vertex 密码          : ${CYAN}${APP_PASS}${NC}"
    echo -e " Vertex 数据目录      : ${CYAN}${VX_DIR}${NC}"
    echo -e " Vertex 容器名        : ${CYAN}${VX_CONTAINER_NAME}${NC}"
    echo -e " Vertex 镜像          : ${CYAN}${VERTEX_IMAGE}${NC}"
    echo -e " Vertex 说明          : ${YELLOW}未默认配置下载器，请登录后手动设置。${NC}"
    echo -e " Vertex 日志命令      : ${CYAN}docker logs ${VX_CONTAINER_NAME} --tail 200${NC}"
    echo -e " Vertex 重启命令      : ${CYAN}docker restart ${VX_CONTAINER_NAME}${NC}"
    echo
  fi

  if [[ "$DO_FB" == true ]]; then
    echo -e " FileBrowser URL      : ${CYAN}http://${ip}:${FB_PORT}${NC}"
    echo -e " FileBrowser 用户     : ${CYAN}${APP_USER}${NC}"
    echo -e " FileBrowser 密码     : ${CYAN}${APP_PASS}${NC}"
    echo -e " FileBrowser 根目录   : ${CYAN}${FB_ROOT}${NC}"
    echo -e " FileBrowser 扫描根   : ${CYAN}${FB_SCAN_BASE}${NC}"
    echo -e " FileBrowser 模式     : ${CYAN}${FB_MODE}${NC}"
    echo -e " FileBrowser 容器名   : ${CYAN}${FB_CONTAINER_NAME}${NC}"
    echo -e " FileBrowser 镜像     : ${CYAN}${FILEBROWSER_IMAGE}${NC}"
    echo -e " MediaInfo            : ${YELLOW}由本机 Nginx 代理分发${NC}"
    echo -e " Screenshot           : ${YELLOW}由本机 Nginx 代理分发${NC}"
    echo -e " FileBrowser 日志命令 : ${CYAN}docker logs ${FB_CONTAINER_NAME} --tail 200${NC}"
    echo -e " FileBrowser 重启命令 : ${CYAN}docker restart ${FB_CONTAINER_NAME}${NC}"
    echo
  fi

  echo -e " 安装日志             : ${CYAN}${LOG_FILE}${NC}"
  echo
}

# ================= 主流程 =================
main() {
  : > "$LOG_FILE"

  banner
  parse_args "$@"
  check_root
  check_system

  if [[ "$ACTION" == "uninstall" ]]; then
    uninstall_apps
    exit 0
  fi

  validate_args
  setup_user
  prepare_dirs
  ensure_base_dependencies
  handle_ports
  show_plan
  ensure_docker

  if [[ "$DO_VX" == true ]]; then
    restore_vertex_backup
    reset_vertex_password
    install_vertex
    vertex_post_check
  fi

  if [[ "$DO_FB" == true ]]; then
    install_filebrowser
    filebrowser_post_check
  fi

  summary
}

main "$@"
