#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="telemt"
REPO_NAME="telemt"

BIN_PATH="/usr/local/bin/telemt"
CONF_DIR="/etc/telemt"
CONF_PATH="${CONF_DIR}/telemt.toml"
SERVICE_PATH="/etc/systemd/system/telemt.service"

log(){ echo -e "\n[telemt-installer] $*\n"; }
warn(){ echo -e "\n[telemt-installer][WARN] $*\n" >&2; }
die(){ echo -e "\n[telemt-installer][ERROR] $*\n" >&2; exit 1; }

need_root(){
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Запусти от root: sudo bash $0"
}

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || return 1
}

apt_install(){
  local pkgs=("$@")
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

ask(){
  local prompt="$1" default="${2:-}"
  local v=""
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " v
    echo "${v:-$default}"
  else
    read -r -p "$prompt: " v
    echo "$v"
  fi
}

confirm(){
  local prompt="$1" default="${2:-y}"
  local v
  read -r -p "$prompt (y/n) [$default]: " v
  v="${v:-$default}"
  [[ "$v" =~ ^[Yy]$ ]]
}

arch_tag(){
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) echo "$m" ;;
  esac
}

get_latest_asset_url(){
  local arch json
  arch="$(arch_tag)"
  json="$(curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest")"

  python3 - <<'PY' "$json" "$arch"
import json, sys
data = json.loads(sys.argv[1])
arch = sys.argv[2]
assets = data.get("assets", [])
if not assets:
    print("")
    sys.exit(0)

def score(name: str):
    n = name.lower()
    s = 0
    if "linux" in n: s += 50
    if arch in n: s += 40
    if arch == "amd64" and ("x86_64" in n or "x64" in n): s += 30
    if arch == "arm64" and ("aarch64" in n): s += 30
    if n.endswith(".tar.gz") or n.endswith(".tgz"): s += 5
    if n.endswith(".gz"): s += 2
    return s

best = max(assets, key=lambda a: score(a.get("name","")))
if score(best.get("name","")) < 10:
    best = assets[0]
print(best.get("browser_download_url",""))
PY
}

download_and_install_binary(){
  log "Скачиваю последний релиз telemt..."

  local url tmp ft found
  url="$(get_latest_asset_url)"
  [[ -n "$url" ]] || die "Не нашёл assets в latest release. Проверь https://github.com/telemt/telemt/releases"

  log "Ассет: $url"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  curl -fL "$url" -o "$tmp/asset"

  ft="$(file -b "$tmp/asset" || true)"
  if echo "$ft" | grep -qiE 'gzip|tar'; then
    mkdir -p "$tmp/unpack"
    if tar -xzf "$tmp/asset" -C "$tmp/unpack" >/dev/null 2>&1; then
      :
    else
      gunzip -c "$tmp/asset" > "$tmp/unpack/telemt" || true
    fi
    found="$(find "$tmp/unpack" -maxdepth 3 -type f \( -name "telemt" -o -name "telemt*" \) 2>/dev/null | head -n1 || true)"
    [[ -n "$found" ]] || die "Не нашёл бинарь внутри архива. Проверь ассет: $url"
    install -m 0755 "$found" "$BIN_PATH"
  else
    install -m 0755 "$tmp/asset" "$BIN_PATH"
  fi

  log "Бинарь установлен: $BIN_PATH"
}

gen_user_tgproxy(){
  # tgproxy = "openssl rand -hex 16"
  local key
  key="$(openssl rand -hex 16)"
  echo "tgproxy = \"${key}\""
}

write_config(){
  log "Создаю конфиг."

  mkdir -p "$CONF_DIR"

  # Вопросы
  local port announce_ip tls_domain enable_metrics metrics_port metrics_whitelist_csv metrics_whitelist_arr
  local user_line

  port="$(ask "server.port" "443")"

  announce_ip="$(ask "announce_ip (внешний IP сервера)" "")"
  [[ -n "$announce_ip" ]] || die "announce_ip обязателен."

  tls_domain="$(ask "tls_domain (домен faketls для маскировки)" "")"
  [[ -n "$tls_domain" ]] || die "tls_domain обязателен."

  enable_metrics="false"
  metrics_port="9090"
  metrics_whitelist_arr="\"127.0.0.1\", \"::1\""
  if confirm "Включить метрики?" "n"; then
    enable_metrics="true"
    metrics_port="$(ask "metrics_port" "9090")"
    metrics_whitelist_csv="$(ask "metrics_whitelist (через запятую)" "127.0.0.1,::1")"
    metrics_whitelist_arr="$(python3 - <<'PY' "$metrics_whitelist_csv"
import sys
items=[i.strip() for i in sys.argv[1].split(",") if i.strip()]
print(", ".join([f'"{x}"' for x in items]) if items else '"127.0.0.1", "::1"')
PY
)"
  fi

  user_line="$(gen_user_tgproxy)"

  cat > "$CONF_PATH" <<EOF
# === UI ===
# Пользователи для отображения ссылок при запуске
show_link = ["tgproxy"]

# === Общие настройки ===
[general]
prefer_ipv6 = false
fast_mode = true
use_middle_proxy = false
#ad_tag = ""

[general.modes]
classic = false
secure = false
tls = true  # Рекомендуется для обхода блокировок

# === Привязка сервера ===
[server]
port = ${port}  # Стандартный HTTPS порт (рекомендуется)
listen_addr_ipv4 = "0.0.0.0"
listen_addr_ipv6 = "::"
EOF

  if [[ "$enable_metrics" == "true" ]]; then
    cat >> "$CONF_PATH" <<EOF
metrics_port = ${metrics_port}
metrics_whitelist = [${metrics_whitelist_arr}]
EOF
  else
    cat >> "$CONF_PATH" <<'EOF'
#metrics_port = 9090
#metrics_whitelist = ["127.0.0.1", "::1"]
EOF
  fi

  cat >> "$CONF_PATH" <<EOF

[[server.listeners]]
ip = "0.0.0.0"
announce_ip = "${announce_ip}"

[[server.listeners]]
ip = "::"

# === Таймауты (в секундах) ===
[timeouts]
client_handshake = 15
tg_connect = 10
client_keepalive = 60
client_ack = 300

# === Анти-цензура и маскировка ===
[censorship]
tls_domain = "${tls_domain}"  # Домен для маскировки
mask = true
mask_port = 443
fake_cert_len = 2048

# === Контроль доступа и пользователи ===
[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
${user_line}

# === Апстримы и маршрутизация ===
[[upstreams]]
type = "direct"
enabled = true
weight = 10
EOF

  chmod 600 "$CONF_PATH"
  log "Конфиг записан: $CONF_PATH"
  log "Сгенерированный ключ (сохрани себе):"
  echo "  ${user_line}"
}

write_systemd(){
  log "Создаю systemd unit..."

  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} ${CONF_PATH}
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now telemt

  log "Сервис запущен."
}

print_proxy_link(){
  log "Пытаюсь получить tg:// ссылку из journalctl..."

  local i line
  for i in {1..30}; do
    line="$(journalctl -u telemt -n 200 --no-pager 2>/dev/null | grep -Eo 'tg://proxy\?[^[:space:]]+' | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      echo
      echo "================= TELEMT PROXY LINK ================="
      echo "$line"
      echo "====================================================="
      echo
      return 0
    fi
    sleep 1
  done

  warn "Не удалось вытащить tg:// ссылку из логов за 30 секунд."
  warn "Посмотри вручную: journalctl -u telemt -f"
  return 1
}

main(){
  need_root

  if ! need_cmd curl || ! need_cmd python3 || ! need_cmd openssl || ! need_cmd file; then
    log "Ставлю зависимости (curl, python3, openssl, file)..."
    apt_install curl python3 openssl file ca-certificates
  fi

  download_and_install_binary
  write_config
  write_systemd
  print_proxy_link || true

  log "Готово."
}

main "$@"
