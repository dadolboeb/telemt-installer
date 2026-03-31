#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="telemt"
REPO_NAME="telemt"

BIN_PATH="/usr/local/bin/telemt"
CONF_DIR="/etc/telemt"
CONF_PATH="${CONF_DIR}/telemt.toml"
SERVICE_PATH="/etc/systemd/system/telemt.service"

SERVICE_USER="telemt"
SERVICE_GROUP="telemt"
PANEL_USER="telemt-panel"
WORK_DIR="/opt/telemt"

log(){ echo -e "\n[telemt-installer] $*\n"; }
warn(){ echo -e "\n[telemt-installer][WARN] $*\n" >&2; }
die(){ echo -e "\n[telemt-installer][ERROR] $*\n" >&2; exit 1; }

need_root(){
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Запусти от root: sudo bash $0"
}

need_cmd(){
  command -v "$1" >/dev/null 2>&1
}

apt_install(){
  local pkgs=("$@")
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "${pkgs[@]}"
}

ask(){
  local prompt="$1" default="${2:-}" v=""
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " v
    echo "${v:-$default}"
  else
    read -r -p "$prompt: " v
    echo "$v"
  fi
}

confirm(){
  local prompt="$1" default="${2:-y}" v=""
  read -r -p "$prompt (y/n) [$default]: " v
  v="${v:-$default}"
  [[ "$v" =~ ^[Yy]$ ]]
}

arch_tag(){
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) die "Неподдерживаемая архитектура: $m" ;;
  esac
}

libc_tag(){
  if ldd --version 2>&1 | grep -qi musl; then
    echo "musl"
  else
    echo "gnu"
  fi
}

get_latest_release_tag(){
  curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])'
}

get_latest_asset_url(){
  local arch libc file
  arch="$(arch_tag)"
  libc="$(libc_tag)"
  file="telemt-${arch}-linux-${libc}.tar.gz"
  echo "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${file}"
}

ensure_system_user(){
  if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    groupadd --system "$SERVICE_GROUP"
  fi

  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd \
      --system \
      --gid "$SERVICE_GROUP" \
      --home-dir "$WORK_DIR" \
      --create-home \
      --shell /usr/sbin/nologin \
      "$SERVICE_USER"
  fi

  mkdir -p "$WORK_DIR"
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$WORK_DIR"
  chmod 0750 "$WORK_DIR"
}

ensure_panel_access(){
  if id -u "$PANEL_USER" >/dev/null 2>&1; then
    usermod -aG "$SERVICE_GROUP" "$PANEL_USER" || true
    log "Пользователь ${PANEL_USER} добавлен в группу ${SERVICE_GROUP}"
  else
    warn "Пользователь ${PANEL_USER} не найден. Если поставишь telemt_panel позже, добавь его в группу ${SERVICE_GROUP}"
  fi
}

download_and_install_binary(){
  log "Скачиваю последний релиз telemt..."
  local url tmp version extracted

  version="$(get_latest_release_tag)"
  url="$(get_latest_asset_url)"

  log "Последний релиз: ${version}"
  log "Ассет: ${url}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  curl -fL "$url" -o "$tmp/telemt.tar.gz"
  mkdir -p "$tmp/unpack"
  tar -xzf "$tmp/telemt.tar.gz" -C "$tmp/unpack"

  extracted="$(find "$tmp/unpack" -type f -name "telemt" | head -n1 || true)"
  [[ -n "$extracted" ]] || die "Не найден бинарь telemt внутри архива"

  install -m 0755 "$extracted" "$BIN_PATH"
  log "Бинарь установлен: $BIN_PATH"
}

gen_user_secret_line(){
  local username="${1:-tgproxy}"
  local key
  key="$(openssl rand -hex 16)"
  echo "\"${username}\" = \"${key}\""
}

csv_to_toml_array(){
  python3 - "$1" <<'PY'
import sys
items=[x.strip() for x in sys.argv[1].split(",") if x.strip()]
print(", ".join(f'"{x}"' for x in items))
PY
}

write_config(){
  log "Создаю актуальный конфиг..."

  mkdir -p "$CONF_DIR"

  local port announce_ip tls_domain username user_line
  local enable_metrics metrics_mode metrics_port metrics_listen metrics_whitelist_csv metrics_whitelist_arr
  local enable_api api_listen api_whitelist_csv api_whitelist_arr api_auth_header api_read_only
  local enable_timing_norm timing_floor timing_ceil
  local enable_aggressive_shape
  local use_middle_proxy
  local prefer_ipv6
  local log_level

  port="$(ask "server.port" "443")"

  announce_ip="$(ask "announce_ip (внешний IP или домен сервера)" "")"
  [[ -n "$announce_ip" ]] || die "announce_ip обязателен"

  tls_domain="$(ask "tls_domain (домен для faketls/masking)" "")"
  [[ -n "$tls_domain" ]] || die "tls_domain обязателен"

  username="$(ask "Имя пользователя в access.users" "tgproxy")"
  user_line="$(gen_user_secret_line "$username")"

  use_middle_proxy="false"
  if confirm "Включить use_middle_proxy?" "n"; then
    use_middle_proxy="true"
  fi

  prefer_ipv6="false"
  if confirm "Предпочитать IPv6 при исходящих соединениях?" "n"; then
    prefer_ipv6="true"
  fi

  log_level="$(ask "general.log_level" "normal")"

  enable_metrics="false"
  metrics_mode="listen"
  metrics_port="9090"
  metrics_listen="127.0.0.1:9090"
  metrics_whitelist_csv="127.0.0.1/32,::1/128"
  metrics_whitelist_arr='"127.0.0.1/32", "::1/128"'

  if confirm "Включить metrics endpoint?" "n"; then
    enable_metrics="true"
    if confirm "Использовать metrics_listen вместо metrics_port?" "y"; then
      metrics_mode="listen"
      metrics_listen="$(ask "metrics_listen" "127.0.0.1:9090")"
    else
      metrics_mode="port"
      metrics_port="$(ask "metrics_port" "9090")"
    fi
    metrics_whitelist_csv="$(ask "metrics_whitelist CIDR (через запятую)" "$metrics_whitelist_csv")"
    metrics_whitelist_arr="$(csv_to_toml_array "$metrics_whitelist_csv")"
  fi

  enable_api="true"
  api_listen="$(ask "server.api.listen" "127.0.0.1:9091")"
  api_whitelist_csv="$(ask "server.api.whitelist CIDR (через запятую)" "127.0.0.1/32,::1/128")"
  api_whitelist_arr="$(csv_to_toml_array "$api_whitelist_csv")"

  api_auth_header=""
  if confirm "Защитить API Authorization header?" "n"; then
    api_auth_header="$(ask "Authorization header (пример: Bearer supersecret)" "")"
    [[ -n "$api_auth_header" ]] || die "Authorization header не может быть пустым"
  fi

  api_read_only="false"
  if confirm "Сделать API read_only?" "n"; then
    api_read_only="true"
  fi

  enable_timing_norm="false"
  timing_floor="180"
  timing_ceil="320"
  if confirm "Включить timing normalization hardening?" "n"; then
    enable_timing_norm="true"
    timing_floor="$(ask "mask_timing_normalization_floor_ms" "180")"
    timing_ceil="$(ask "mask_timing_normalization_ceiling_ms" "320")"
  fi

  enable_aggressive_shape="false"
  if confirm "Включить aggressive shape hardening?" "n"; then
    enable_aggressive_shape="true"
  fi

  cat > "$CONF_PATH" <<EOF
# telemt.toml generated by installer

[general]
prefer_ipv6 = ${prefer_ipv6}
use_middle_proxy = ${use_middle_proxy}
log_level = "${log_level}"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = ["${username}"]
public_host = "${announce_ip}"
public_port = ${port}

[server]
port = ${port}
listen_addr_ipv4 = "0.0.0.0"
listen_addr_ipv6 = "::"
proxy_protocol = false
# proxy_protocol_trusted_cidrs = ["127.0.0.1/32", "::1/128"]
EOF

  if [[ "$enable_metrics" == "true" ]]; then
    if [[ "$metrics_mode" == "listen" ]]; then
      cat >> "$CONF_PATH" <<EOF
metrics_listen = "${metrics_listen}"
metrics_whitelist = [${metrics_whitelist_arr}]
EOF
    else
      cat >> "$CONF_PATH" <<EOF
metrics_port = ${metrics_port}
metrics_whitelist = [${metrics_whitelist_arr}]
EOF
    fi
  else
    cat >> "$CONF_PATH" <<'EOF'
# metrics_port = 9090
# metrics_listen = "127.0.0.1:9090"
# metrics_whitelist = ["127.0.0.1/32", "::1/128"]
EOF
  fi

  cat >> "$CONF_PATH" <<EOF

[server.api]
enabled = ${enable_api}
listen = "${api_listen}"
whitelist = [${api_whitelist_arr}]
read_only = ${api_read_only}
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000
runtime_edge_enabled = false
runtime_edge_cache_ttl_ms = 1000
runtime_edge_top_n = 10
runtime_edge_events_capacity = 256
EOF

  if [[ -n "$api_auth_header" ]]; then
    cat >> "$CONF_PATH" <<EOF
auth_header = "${api_auth_header}"
EOF
  else
    cat >> "$CONF_PATH" <<'EOF'
# auth_header = "Bearer change-me"
EOF
  fi

  cat >> "$CONF_PATH" <<EOF

[[server.listeners]]
ip = "0.0.0.0"
announce_ip = "${announce_ip}"

[[server.listeners]]
ip = "::"

[timeouts]
client_handshake = 15
tg_connect = 10
client_keepalive = 60
client_ack = 300

[censorship]
tls_domain = "${tls_domain}"
mask = true
mask_port = 443
fake_cert_len = 2048
tls_emulation = true
tls_front_dir = "tlsfront"

mask_shape_hardening = true
mask_shape_hardening_aggressive_mode = ${enable_aggressive_shape}
mask_shape_bucket_floor_bytes = 512
mask_shape_bucket_cap_bytes = 4096
mask_shape_above_cap_blur = false
mask_shape_above_cap_blur_max_bytes = 512

mask_timing_normalization_enabled = ${enable_timing_norm}
mask_timing_normalization_floor_ms = ${timing_floor}
mask_timing_normalization_ceiling_ms = ${timing_ceil}

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
${user_line}

[[upstreams]]
type = "direct"
enabled = true
weight = 1
EOF

  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$CONF_DIR"
  chmod 0770 "$CONF_DIR"
  chmod 0660 "$CONF_PATH"

  log "Конфиг записан: $CONF_PATH"
  log "Секрет пользователя:"
  echo "  ${user_line}"
}

ensure_tlsfront_dir(){
  mkdir -p "${WORK_DIR}/tlsfront"
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "${WORK_DIR}/tlsfront"
  chmod 0750 "${WORK_DIR}/tlsfront"
}

write_systemd(){
  log "Создаю systemd unit..."

  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${WORK_DIR}
ExecStart=${BIN_PATH} ${CONF_PATH}
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "$SERVICE_PATH"
  systemctl daemon-reload
  systemctl enable --now telemt
  log "Сервис запущен"
}

print_links_from_api(){
  log "Пробую получить tg:// ссылки через API..."

  local i api_url auth_header
  api_url="http://127.0.0.1:9091/v1/users"
  auth_header="$(grep -E '^[[:space:]]*auth_header[[:space:]]*=' "$CONF_PATH" 2>/dev/null | sed -E 's/^[^"]*"([^"]+)".*/\1/' || true)"

  for i in {1..20}; do
    if [[ -n "$auth_header" ]]; then
      if curl -fsS -H "Authorization: ${auth_header}" "$api_url" >/tmp/telemt-users.$$ 2>/dev/null; then
        echo
        echo "================= TELEMT USERS API ================="
        cat /tmp/telemt-users.$$
        echo
        echo "===================================================="
        echo
        rm -f /tmp/telemt-users.$$
        return 0
      fi
    else
      if curl -fsS "$api_url" >/tmp/telemt-users.$$ 2>/dev/null; then
        echo
        echo "================= TELEMT USERS API ================="
        cat /tmp/telemt-users.$$
        echo
        echo "===================================================="
        echo
        rm -f /tmp/telemt-users.$$
        return 0
      fi
    fi
    sleep 1
  done

  warn "Не удалось получить API-ответ."
  warn "Проверь вручную:"
  if [[ -n "$auth_header" ]]; then
    warn "curl -H 'Authorization: ${auth_header}' ${api_url}"
  else
    warn "curl ${api_url}"
  fi
}

post_checks(){
  echo
  echo "Полезные проверки:"
  echo "  systemctl status telemt --no-pager"
  echo "  journalctl -u telemt -n 100 --no-pager"
  echo "  ls -ld ${CONF_DIR}"
  echo "  ls -l ${CONF_PATH}"
  echo "  id ${SERVICE_USER}"
  if id -u "$PANEL_USER" >/dev/null 2>&1; then
    echo "  id ${PANEL_USER}"
  fi
  echo

  warn "Если в логах будет 'No upstreams available', проверь, что в конфиге нет scopes='*' у default upstream."
  warn "Если будет 'Connection timeout to 149.154.x.x:443', это уже сетевая проблема VPS/outbound, а не формат конфига."
}

main(){
  need_root

  if ! need_cmd curl || ! need_cmd python3 || ! need_cmd openssl || ! need_cmd tar || ! need_cmd ca-certificates; then
    log "Ставлю зависимости..."
    apt_install curl python3 openssl tar ca-certificates
  fi

  ensure_system_user
  ensure_panel_access
  download_and_install_binary
  write_config
  ensure_tlsfront_dir
  write_systemd
  print_links_from_api || true
  post_checks

  log "Готово."
}

main "$@"
