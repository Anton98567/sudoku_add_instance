#!/bin/bash
#
# sudoku-add-instance.sh вЂ” manage multiple Sudoku server instances on one host.
#
# Requires an existing easy-install deployment:
#   /usr/local/bin/sudoku  and  /etc/sudoku/config.json
#
# Each new instance gets:
#   * its own keypair (or a split key derived from --master-key)
#   * its own server config   /etc/sudoku/config<N>.json
#   * its own systemd unit    sudoku<N>.service
#   * its own sudoku:// short link and standalone node YAML
#
# Per-instance client keys are saved in /etc/sudoku/instances/<name>.env
# so short links can be regenerated later (--list).
#
# Usage:
#   sudo ./sudoku-add-instance.sh [options]
#
# Modes:
#   --list                     print ALL installed instances (short links + YAML nodes)
#                              and save them to --save FILE, or by default to
#                              /root/sudoku_saved_<N>.txt (N = instance count)
#   --count N                  create N instances at once (default: 1)
#   --delete N                 delete instance N (config, systemd unit, UFW rule, state file)
#                              may be repeated: --delete 3 --delete 5
#                              the base install (config.json) cannot be deleted
#   --delete-all               delete ALL additional instances (base install is kept)
#   --delete-all --with-base   delete everything: all instances + base install
#                              (services, /etc/sudoku, firewall rules)
#
# Options:
#   --port PORT         server listen port for the first/new instance (default: random free port in 50001-65535)
#   --name NAME         instance index/suffix, e.g. 3  => config3.json / sudoku3.service
#                       (default: first free number starting from 2; only valid with --count 1)
#   --server-ip HOST    host/IP advertised in the short links (default: auto-detect)
#   --client-port PORT  client local proxy port inside the exported short links (default: 10233)
#   --http-path-root    HTTP mask path_root (default: copied from base config.json)
#   --node-name NAME    node name in the exported YAML (default: sudoku-<instance>)
#   --master-key HEX    derive split private keys via `sudoku -keygen -more HEX`
#                       (server keeps the base master public key)
#   --save FILE         save the listed/created configs (short links + YAML) to FILE
#                       (with --list, defaults to /root/sudoku_saved_<N>.txt)
#   --force             skip the confirmation prompt (with --delete)
#   --help              show this help

set -e

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sudoku"
INSTANCE_STATE_DIR="${CONFIG_DIR}/instances"
EXPORT_STATE_FILE="${CONFIG_DIR}/export-state.env"
SUDOKU_BIN="${INSTALL_DIR}/sudoku"
BASE_CFG="${CONFIG_DIR}/config.json"
DEFAULT_ASCII_MODE="up_ascii_down_entropy"
DEFAULT_HTTP_MASK_MODE="auto"
DEFAULT_HTTP_MASK_TLS="false"
DEFAULT_HTTP_MASK_MULTIPLEX="on"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
die()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------- args

MODE_LIST="false"
COUNT="1"
SERVER_IP=""
SUDOKU_PORT=""
SUDOKU_CLIENT_PORT="10233"
INSTANCE_NAME=""
HTTP_MASK_PATH_ROOT=""
NODE_NAME=""
MASTER_KEY=""
SAVE_FILE=""
FORCE="false"
DELETE_NAMES=()
DELETE_ALL="false"
WITH_BASE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) MODE_LIST="true"; shift ;;
        --count) COUNT="$2"; shift 2 ;;
        --delete) DELETE_NAMES+=("$2"); shift 2 ;;
        --delete-all) DELETE_ALL="true"; shift ;;
        --with-base) WITH_BASE="true"; shift ;;
        --port) SUDOKU_PORT="$2"; shift 2 ;;
        --name) INSTANCE_NAME="$2"; shift 2 ;;
        --server-ip) SERVER_IP="$2"; shift 2 ;;
        --client-port) SUDOKU_CLIENT_PORT="$2"; shift 2 ;;
        --http-path-root) HTTP_MASK_PATH_ROOT="$2"; shift 2 ;;
        --node-name) NODE_NAME="$2"; shift 2 ;;
        --master-key) MASTER_KEY="$2"; shift 2 ;;
        --save) SAVE_FILE="$2"; shift 2 ;;
        --force) FORCE="true"; shift ;;
        --help) usage ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done

[[ "${COUNT}" =~ ^[0-9]+$ && "${COUNT}" -ge 1 ]] || die "Invalid --count: ${COUNT}"
[[ "${MODE_LIST}" == "true" && "${COUNT}" -ne 1 ]] && die "--list cannot be combined with --count"
[[ "${MODE_LIST}" == "true" && "${#DELETE_NAMES[@]}" -gt 0 ]] && die "--list and --delete cannot be combined"
[[ "${MODE_LIST}" == "true" && "${DELETE_ALL}" == "true" ]] && die "--list and --delete-all cannot be combined"
[[ "${#DELETE_NAMES[@]}" -gt 0 && "${COUNT}" -ne 1 ]] && die "--count cannot be combined with --delete"
[[ "${DELETE_ALL}" == "true" && "${COUNT}" -ne 1 ]] && die "--count cannot be combined with --delete-all"
[[ "${#DELETE_NAMES[@]}" -gt 0 && "${DELETE_ALL}" == "true" ]] && die "--delete and --delete-all cannot be combined"
[[ "${WITH_BASE}" == "true" && "${DELETE_ALL}" != "true" ]] && die "--with-base requires --delete-all"
[[ -n "${INSTANCE_NAME}" && "${COUNT}" -ne 1 ]] && die "--name is only valid with --count 1"
[[ -n "${SUDOKU_PORT}" && "${COUNT}" -ne 1 ]] && die "--port is only valid with --count 1 (bulk mode picks free ports automatically)"

# ---------------------------------------------------------------- helpers

is_valid_port() {
    local p="${1:-}"
    [[ "${p}" =~ ^[0-9]+$ ]] || return 1
    ((p >= 1 && p <= 65535))
}

trim() { local s="${1:-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "${s}"; }

is_tcp_port_in_use() {
    local port="${1:-}"
    if command -v ss >/dev/null 2>&1; then
        ss -Hltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])${port}$"
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk 'NR > 2 {print $4}' | grep -Eq "(^|:|\\])${port}$"
        return $?
    fi
    return 1
}

random_uint32() {
    local v=""
    v=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
    [[ -n "${v}" ]] || v=$RANDOM
    printf '%s' "${v}"
}

pick_free_port() {
    local port attempt
    for attempt in $(seq 1 128); do
        port=$((50001 + ($(random_uint32) % 15535)))
        if ! is_tcp_port_in_use "${port}"; then
            printf '%s' "${port}"
            return 0
        fi
    done
    die "Could not find a free port in 50001-65535"
}

next_free_instance_name() {
    local n=2
    while [[ -f "${CONFIG_DIR}/config${n}.json" || -f "/etc/systemd/system/sudoku${n}.service" ]]; do
        n=$((n + 1))
    done
    printf '%s' "${n}"
}

get_public_ip() {
    if [[ -n "${SERVER_IP}" ]]; then
        return 0
    fi
    local ip="" api
    for api in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        if ip=$(curl -fsSL --max-time 10 "${api}" 2>/dev/null); then
            ip=$(trim "${ip}")
            if [[ -n "${ip}" ]]; then
                SERVER_IP="${ip}"
                return 0
            fi
        fi
    done
    die "Could not auto-detect public IP; pass --server-ip explicitly"
}

generate_keypair() {
    local mode="${1:-fresh}" master_key="${2:-}" out priv pub
    if [[ "${mode}" == "more" ]]; then
        out=$("${SUDOKU_BIN}" -keygen -more "${master_key}" 2>&1)
        priv=$(printf '%s\n' "${out}" \
            | sed -n 's/.*Split Private Key:[[:space:]]*\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' \
            | head -n 1)
        pub=$(jq -r '.key // empty' "${BASE_CFG}")
    else
        out=$("${SUDOKU_BIN}" -keygen 2>&1)
        priv=$(printf '%s\n' "${out}" \
            | sed -n 's/.*Available Private Key:[[:space:]]*\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' \
            | head -n 1)
        pub=$(printf '%s\n' "${out}" \
            | sed -n 's/.*Master Public Key:[[:space:]]*\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' \
            | head -n 1)
    fi
    [[ -n "${priv}" ]] || { printf '%s\n' "${out}" >&2; return 1; }
    AVAILABLE_PRIVATE_KEY="${priv}"
    MASTER_PUBLIC_KEY="${pub}"
    return 0
}

build_short_link() {
    local host="${1}" port="${2}" client_port="${3}" key="${4}" table="${5}"
    local mode="${6}" tls="${7}" mux="${8}" path_root="${9}"
    local tmp_dir client_cfg out link

    tmp_dir=$(mktemp -d)
    client_cfg="${tmp_dir}/client.json"
    cat > "${client_cfg}" << EOF
{
  "mode": "client",
  "transport": "tcp",
  "local_port": ${client_port},
  "server_address": "${host}:${port}",
  "key": "${key}",
  "aead": "chacha20-poly1305",
  "ascii": "${DEFAULT_ASCII_MODE}",
  "padding_min": 5,
  "padding_max": 15,
  "custom_table": "${table}",
  "enable_pure_downlink": false,
  "httpmask": {
    "disable": true,
    "mode": "${mode}",
    "tls": ${tls},
    "host": "${HTTP_MASK_HOST:-}",
    "path_root": "${path_root}",
    "multiplex": "${mux}"
  },
  "rule_urls": ["global"]
}
EOF
    out=$("${SUDOKU_BIN}" -c "${client_cfg}" -export-link 2>&1 || true)
    rm -rf "${tmp_dir}"
    link=$(printf '%s\n' "${out}" | grep -Eo 'sudoku://[^[:space:]]+' | tail -n 1)
    [[ -n "${link}" ]] || return 1
    printf '%s' "${link}"
}

render_node_yaml() {
    local node_name="${1}" host="${2}" port="${3}" key="${4}" table="${5}"
    local mode="${6}" tls="${7}" mux="${8}" path_root="${9}"
    printf -- '- name: "%s"\n' "${node_name}"
    echo "  type: sudoku"
    printf '  server: "%s"\n' "${host}"
    printf '  port: %s\n' "${port}"
    printf '  key: "%s"\n' "${key}"
    echo "  aead-method: chacha20-poly1305"
    echo "  padding-min: 2"
    echo "  padding-max: 7"
    printf '  table-type: %s\n' "${DEFAULT_ASCII_MODE}"
    if [[ -n "${table}" ]]; then
        printf '  custom-table: %s\n' "${table}"
    fi
    echo "  httpmask:"
    echo "    disable: true"
    printf '    mode: %s\n' "${mode}"
    printf '    tls: %s\n' "${tls}"
    printf '    host: "%s"\n' "${HTTP_MASK_HOST:-}"
    printf '    multiplex: "%s"\n' "${mux}"
    printf '    path-root: "%s"\n' "${path_root}"
    echo "  enable-pure-downlink: false"
}

# ---------------------------------------------------------------- checks

if [[ "${MODE_LIST}" != "true" ]]; then
    [[ "${EUID}" -eq 0 ]] || die "Must be run as root (use sudo)"
fi
[[ -x "${SUDOKU_BIN}" ]] || die "sudoku binary not found at ${SUDOKU_BIN}; run the easy-install script first"
[[ -f "${BASE_CFG}" ]] || die "Base config not found at ${BASE_CFG}; run the easy-install script first"
command -v jq >/dev/null 2>&1 || die "jq is required but not installed"
is_valid_port "${SUDOKU_CLIENT_PORT}" || die "Invalid --client-port: ${SUDOKU_CLIENT_PORT}"

# ---------------------------------------------------------------- create one instance

create_instance() {
    local name="${1}" port="${2}" node_name="${3}" cfg_file service_file state_file

    cfg_file="${CONFIG_DIR}/config${name}.json"
    service_file="/etc/systemd/system/sudoku${name}.service"
    state_file="${INSTANCE_STATE_DIR}/${name}.env"

    [[ -f "${cfg_file}" || -f "${service_file}" ]] && die "Instance '${name}' already exists (${cfg_file} or ${service_file})"

    info "=== Creating instance '${name}' on port ${port} ==="

    if [[ -n "${MASTER_KEY}" ]]; then
        generate_keypair "more" "${MASTER_KEY}" || die "Failed to derive split key"
    else
        generate_keypair "fresh" || die "Failed to generate keypair"
    fi

    local table mode tls mux path_root
    table=$(jq -r '.custom_table // empty' "${BASE_CFG}")
    mode=$(jq -r '.httpmask.mode // "'"${DEFAULT_HTTP_MASK_MODE}"'"' "${BASE_CFG}")
    tls=$(jq -r '.httpmask.tls // '"${DEFAULT_HTTP_MASK_TLS}"'' "${BASE_CFG}")
    mux=$(jq -r '.httpmask.multiplex // "'"${DEFAULT_HTTP_MASK_MULTIPLEX}"'"' "${BASE_CFG}")
    path_root="${HTTP_MASK_PATH_ROOT}"
    if [[ -z "${path_root}" ]]; then
        path_root=$(jq -r '.httpmask.path_root // ""' "${BASE_CFG}")
    fi
    [[ -z "${path_root}" || "${path_root}" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid http path root: ${path_root}"

    info "Writing ${cfg_file} ..."
    jq \
        --argjson p "${port}" \
        --arg key "${MASTER_PUBLIC_KEY}" \
        --arg pr "${path_root}" \
        '.local_port = $p | .key = $key | .httpmask.path_root = $pr' \
        "${BASE_CFG}" > "${cfg_file}"
    chmod 600 "${cfg_file}"

    info "Creating sudoku${name}.service ..."
    cat > "${service_file}" << EOF
[Unit]
Description=Sudoku Proxy Server (instance ${name})
After=network.target

[Service]
Type=simple
ExecStart=${SUDOKU_BIN} -c ${cfg_file}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "sudoku${name}" >/dev/null 2>&1
    systemctl restart "sudoku${name}" >/dev/null 2>&1 || systemctl start "sudoku${name}"

    sleep 2
    if ! systemctl is-active --quiet "sudoku${name}"; then
        journalctl -u "sudoku${name}" -n 30 --no-pager >&2
        die "Service sudoku${name} failed to start"
    fi
    ok "Service sudoku${name} is active"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || warn "Could not open port ${port} in UFW"
        ok "UFW: allowed ${port}/tcp"
    fi

    get_public_ip
    info "Generating short link for ${SERVER_IP}:${port} ..."
    local link
    if ! link=$(build_short_link "${SERVER_IP}" "${port}" "${SUDOKU_CLIENT_PORT}" "${AVAILABLE_PRIVATE_KEY}" "${table}" "${mode}" "${tls}" "${mux}" "${path_root}"); then
        warn "Short link generation failed for instance '${name}'"
        link=""
    else
        ok "Short link generated"
    fi

    mkdir -p "${INSTANCE_STATE_DIR}"
    cat > "${state_file}" << EOF
INSTANCE_NAME="${name}"
SUDOKU_PORT="${port}"
SERVER_IP="${SERVER_IP}"
SUDOKU_CLIENT_PORT="${SUDOKU_CLIENT_PORT}"
MASTER_PUBLIC_KEY="${MASTER_PUBLIC_KEY}"
AVAILABLE_PRIVATE_KEY="${AVAILABLE_PRIVATE_KEY}"
HTTP_MASK_DISABLE="true"
HTTP_MASK_MODE="${mode}"
HTTP_MASK_TLS="${tls}"
HTTP_MASK_MULTIPLEX="${mux}"
HTTP_MASK_PATH_ROOT="${path_root}"
CUSTOM_TABLE="${table}"
NODE_NAME="${node_name}"
SHORT_LINK="${link}"
EOF
    chmod 600 "${state_file}"

    CREATE_LINKS+=("${link}")
    CREATE_META+=("${name}|${port}|${node_name}")
    ok "Instance '${name}' installed (${cfg_file})"
}

# ---------------------------------------------------------------- print all instances

print_all() {
    echo ""
    echo "===================================================="
    echo "  All Sudoku instances on this host"
    echo "===================================================="
    printf '  %-4s %-22s %-8s %s\n' "#" "config" "port" "short link"
    printf '  %-4s %-22s %-8s %s\n' "--" "------" "----" "----------"

    local idx=0
    local seen_ports=""
    local state_file
    local user_server_ip="${SERVER_IP}"
    for state_file in "${INSTANCE_STATE_DIR}"/*.env; do
        [[ -f "${state_file}" ]] || continue
        # shellcheck disable=SC1090
        source "${state_file}"
        [[ -n "${user_server_ip}" ]] && SERVER_IP="${user_server_ip}"
        seen_ports+=" ${SUDOKU_PORT}"
        local link="${SHORT_LINK}"
        get_public_ip
        if [[ -n "${AVAILABLE_PRIVATE_KEY}" && -n "${SUDOKU_PORT}" ]]; then
            local rebuilt
            if rebuilt=$(build_short_link "${SERVER_IP}" "${SUDOKU_PORT}" "${SUDOKU_CLIENT_PORT:-10233}" "${AVAILABLE_PRIVATE_KEY}" "${CUSTOM_TABLE:-}" "${HTTP_MASK_MODE:-auto}" "${HTTP_MASK_TLS:-false}" "${HTTP_MASK_MULTIPLEX:-on}" "${HTTP_MASK_PATH_ROOT:-}" 2>/dev/null); then
                link="${rebuilt}"
            fi
        fi
        printf '  %-4s %-22s %-8s %s\n' "${INSTANCE_NAME}" "config${INSTANCE_NAME}.json" "${SUDOKU_PORT}" "${link}"
        [[ -n "${ALL_YAML}" ]] && ALL_YAML+=$'\n'
        ALL_YAML+="$(render_node_yaml "${NODE_NAME:-sudoku-${INSTANCE_NAME}}" "${SERVER_IP}" "${SUDOKU_PORT}" "${AVAILABLE_PRIVATE_KEY}" "${CUSTOM_TABLE:-}" "${HTTP_MASK_MODE:-auto}" "${HTTP_MASK_TLS:-false}" "${HTTP_MASK_MULTIPLEX:-on}" "${HTTP_MASK_PATH_ROOT:-}")"
        idx=$((idx + 1))
    done

    local base_name base_port base_key base_table base_mode base_tls base_mux base_path base_link
    base_name="1"
    base_port=$(jq -r '.local_port // empty' "${BASE_CFG}")
    base_key=$(jq -r '.key // empty' "${BASE_CFG}")
    base_table=$(jq -r '.custom_table // empty' "${BASE_CFG}")
    base_mode=$(jq -r '.httpmask.mode // "'"${DEFAULT_HTTP_MASK_MODE}"'"' "${BASE_CFG}")
    base_tls=$(jq -r '.httpmask.tls // '"${DEFAULT_HTTP_MASK_TLS}"'' "${BASE_CFG}")
    base_mux=$(jq -r '.httpmask.multiplex // "'"${DEFAULT_HTTP_MASK_MULTIPLEX}"'"' "${BASE_CFG}")
    base_path=$(jq -r '.httpmask.path_root // ""' "${BASE_CFG}")
    base_link=""
    local base_priv=""
    if [[ -f "${EXPORT_STATE_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${EXPORT_STATE_FILE}"
        [[ -n "${user_server_ip}" ]] && SERVER_IP="${user_server_ip}"
        base_priv="${AVAILABLE_PRIVATE_KEY:-}"
        base_link="${SHORT_LINK:-}"
    fi
    if [[ " ${seen_ports} " != *" ${base_port} "* ]]; then
        get_public_ip
        if [[ -n "${base_priv}" && -n "${base_port}" ]]; then
            local rebuilt
            if rebuilt=$(build_short_link "${SERVER_IP}" "${base_port}" "${SUDOKU_CLIENT_PORT:-10233}" "${base_priv}" "${base_table}" "${base_mode}" "${base_tls}" "${base_mux}" "${base_path}" 2>/dev/null); then
                base_link="${rebuilt}"
            fi
        fi
        printf '  %-4s %-22s %-8s %s\n' "${base_name}" "config.json" "${base_port}" "${base_link:-<cannot rebuild, no saved key>}"
        [[ -n "${ALL_YAML}" ]] && ALL_YAML+=$'\n'
        ALL_YAML+="$(render_node_yaml "${EXPORTED_SUBSCRIPTION_NODE_NAME:-sudoku}" "${SERVER_IP}" "${base_port}" "${base_priv}" "${base_table}" "${base_mode}" "${base_tls}" "${base_mux}" "${base_path}")"
    fi

    if [[ "${idx}" -eq 0 && " ${seen_ports} " != *" ${base_port} "* ]]; then
        echo "  (no instances found besides the base install)"
    fi

    if [[ -n "${ALL_YAML}" ]]; then
        echo ""
        echo "===================================================="
        echo "  All nodes for Mihomo YAML (proxies: section)"
        echo "===================================================="
        echo "proxies:"
        printf '%s\n' "${ALL_YAML}" | sed 's/^/  /'
    fi
    echo "===================================================="
    echo ""
}

# ---------------------------------------------------------------- delete one instance

delete_instance() {
    local name="${1}"
    local cfg_file="${CONFIG_DIR}/config${name}.json"
    local service_file="/etc/systemd/system/sudoku${name}.service"
    local state_file="${INSTANCE_STATE_DIR}/${name}.env"
    local service_name="sudoku${name}"
    local port=""

    if [[ "${name}" == "1" || "${cfg_file}" == "${BASE_CFG}" ]]; then
        die "Cannot delete the base install (${BASE_CFG}). Use the easy-install --uninstall instead."
    fi

    if [[ ! -f "${cfg_file}" && ! -f "${service_file}" && ! -f "${state_file}" ]]; then
        die "Instance '${name}' not found"
    fi

    if [[ -f "${state_file}" ]]; then
        # shellcheck disable=SC1090
        source "${state_file}"
        port="${SUDOKU_PORT}"
    elif [[ -f "${cfg_file}" ]]; then
        port=$(jq -r '.local_port // empty' "${cfg_file}")
    fi

    if [[ "${FORCE}" != "true" ]]; then
        read -r -p "Delete instance '${name}' (port ${port:-?})? [y/N] " ans || ans=""
        [[ "${ans}" =~ ^[yY]$ ]] || die "Aborted"
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -f "${service_file}" ]]; then
        systemctl stop "${service_name}" >/dev/null 2>&1 || true
        systemctl disable "${service_name}" >/dev/null 2>&1 || true
        rm -f "${service_file}"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ok "Stopped and removed ${service_name}.service"
    fi

    rm -f "${cfg_file}" "${state_file}"

    if [[ -n "${port}" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${port}/tcp" >/dev/null 2>&1 || warn "Could not remove UFW rule for port ${port}"
    fi

    ok "Instance '${name}' deleted (port ${port:-unknown})"
}

# ---------------------------------------------------------------- delete all instances

collect_instance_names() {
    local f n found x
    local names=()
    for f in "${INSTANCE_STATE_DIR}"/*.env; do
        [[ -f "${f}" ]] || continue
        names+=("$(basename "${f}" .env)")
    done
    for f in "${CONFIG_DIR}"/config[0-9]*.json; do
        [[ -f "${f}" ]] || continue
        n=$(basename "${f}" .json)
        n="${n#config}"
        found=""
        for x in "${names[@]}"; do
            [[ "${x}" == "${n}" ]] && found="1"
        done
        [[ -z "${found}" ]] && names+=("${n}")
    done
    printf '%s\n' "${names[@]}"
}

delete_all_instances() {
    local names=()
    local n
    while IFS= read -r n; do
        [[ -n "${n}" ]] && names+=("${n}")
    done < <(collect_instance_names)

    if [[ "${#names[@]}" -eq 0 ]]; then
        warn "No additional instances to delete"
        return 0
    fi

    if [[ "${FORCE}" != "true" ]]; then
        read -r -p "Delete ALL ${#names[@]} additional instances (${names[*]})? Base install will be kept. [y/N] " ans || ans=""
        [[ "${ans}" =~ ^[yY]$ ]] || die "Aborted"
    fi

    for n in "${names[@]}"; do
        delete_instance "${n}"
    done
    ok "Deleted ${#names[@]} instance(s)"
}

remove_base_install() {
    if [[ "${FORCE}" != "true" ]]; then
        read -r -p "Also delete the BASE install (config.json, sudoku.service, /etc/sudoku)? This cannot be undone. [y/N] " ans || ans=""
        [[ "${ans}" =~ ^[yY]$ ]] || die "Aborted"
    fi

    local svc
    for svc in sudoku sudoku-fallback sudoku-sing-box; do
        if command -v systemctl >/dev/null 2>&1 && [[ -f "/etc/systemd/system/${svc}.service" ]]; then
            systemctl stop "${svc}" >/dev/null 2>&1 || true
            systemctl disable "${svc}" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${svc}.service"
            ok "Stopped and removed ${svc}.service"
        fi
    done
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true

    rm -rf "${CONFIG_DIR}" "/usr/local/lib/sudoku-fallback" "/etc/sing-box/sudoku-warp.json"
    ok "Base install removed (${CONFIG_DIR})"
    warn "Binary ${SUDOKU_BIN} left in place; remove it manually if you no longer need it: rm ${SUDOKU_BIN}"
}

# ---------------------------------------------------------------- save output

count_instances() {
    local n=0 f base_port seen=""
    for f in "${INSTANCE_STATE_DIR}"/*.env; do
        [[ -f "${f}" ]] || continue
        n=$((n + 1))
    done
    base_port=$(jq -r '.local_port // empty' "${BASE_CFG}")
    if [[ -n "${base_port}" ]]; then
        for f in "${INSTANCE_STATE_DIR}"/*.env; do
            [[ -f "${f}" ]] || continue
            # shellcheck disable=SC1090
            source "${f}"
            [[ "${SUDOKU_PORT}" == "${base_port}" ]] && seen="1"
        done
        [[ -z "${seen}" ]] && n=$((n + 1))
    fi
    printf '%s' "${n}"
}

save_output() {
    local content="${1}" file="${2}" dir
    [[ -n "${file}" ]] || return 1
    dir=$(dirname "${file}")
    if [[ -d "${dir}" || -z "${dir}" ]]; then
        if printf '%s\n' "${content}" > "${file}" 2>/dev/null; then
            chmod 600 "${file}" 2>/dev/null || true
            ok "Saved to ${file}"
            return 0
        fi
    fi
    warn "Could not save to ${file}"
    return 1
}

# ---------------------------------------------------------------- main

CREATE_LINKS=()
CREATE_META=()

if [[ "${MODE_LIST}" == "true" ]]; then
    ALL_OUTPUT=$(print_all)
    printf '%s\n' "${ALL_OUTPUT}"
    if [[ -z "${SAVE_FILE}" ]]; then
        SAVE_FILE="/root/sudoku_saved_$(count_instances).txt"
    fi
    save_output "${ALL_OUTPUT}" "${SAVE_FILE}"
    exit 0
fi

if [[ "${#DELETE_NAMES[@]}" -gt 0 ]]; then
    [[ "${EUID}" -eq 0 ]] || die "Must be run as root (use sudo)"
    local_n=""
    for local_n in "${DELETE_NAMES[@]}"; do
        [[ "${local_n}" =~ ^[0-9]+$ ]] || die "Invalid instance number: ${local_n}"
        delete_instance "${local_n}"
    done
    echo ""
    ALL_OUTPUT=$(print_all)
    printf '%s\n' "${ALL_OUTPUT}"
    if [[ -n "${SAVE_FILE}" ]]; then
        save_output "${ALL_OUTPUT}" "${SAVE_FILE}"
    fi
    exit 0
fi

if [[ "${DELETE_ALL}" == "true" ]]; then
    [[ "${EUID}" -eq 0 ]] || die "Must be run as root (use sudo)"
    delete_all_instances
    if [[ "${WITH_BASE}" == "true" ]]; then
        remove_base_install
        echo ""
        ok "All Sudoku configs on this host have been removed"
        exit 0
    fi
    echo ""
    ALL_OUTPUT=$(print_all)
    printf '%s\n' "${ALL_OUTPUT}"
    if [[ -n "${SAVE_FILE}" ]]; then
        save_output "${ALL_OUTPUT}" "${SAVE_FILE}"
    fi
    exit 0
fi

[[ "${EUID}" -eq 0 ]] || die "Must be run as root (use sudo)"

if [[ -n "${SUDOKU_PORT}" ]]; then
    is_valid_port "${SUDOKU_PORT}" || die "Invalid --port: ${SUDOKU_PORT}"
    is_tcp_port_in_use "${SUDOKU_PORT}" && die "Port ${SUDOKU_PORT} is already in use"
fi

if [[ -z "${NODE_NAME}" && -n "${INSTANCE_NAME}" ]]; then
    NODE_NAME="sudoku-${INSTANCE_NAME}"
fi

local_i=0
while [[ "${local_i}" -lt "${COUNT}" ]]; do
    local_i=$((local_i + 1))
    if [[ -n "${INSTANCE_NAME}" ]]; then
        name="${INSTANCE_NAME}"
    else
        name=$(next_free_instance_name)
    fi
    if [[ -n "${NODE_NAME}" ]]; then
        node_name="${NODE_NAME}"
    else
        node_name="sudoku-${name}"
    fi
    if [[ -n "${SUDOKU_PORT}" ]]; then
        port="${SUDOKU_PORT}"
    else
        port=$(pick_free_port)
    fi
    create_instance "${name}" "${port}" "${node_name}"
done

echo ""
echo "===================================================="
echo "  Created instances"
echo "===================================================="
for i in "${!CREATE_META[@]}"; do
    IFS='|' read -r m_name m_port m_node <<< "${CREATE_META[${i}]}"
    printf '  [%s] config%s.json  port %s  %s\n' "${m_name}" "${m_name}" "${m_port}" "${CREATE_LINKS[${i}]}"
done
echo ""
ALL_OUTPUT=$(print_all)
printf '%s\n' "${ALL_OUTPUT}"
if [[ -n "${SAVE_FILE}" ]]; then
    save_output "${ALL_OUTPUT}" "${SAVE_FILE}"
fi

