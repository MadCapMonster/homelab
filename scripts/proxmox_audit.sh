#!/usr/bin/env bash
# proxmox_audit.sh — Audit a Proxmox VE server via its REST API.
#
# Required environment variables:
#   PROXMOX_HOST          Proxmox hostname or IP (e.g. 192.168.1.10 or pve.example.com)
#   PROXMOX_TOKEN_ID      API token ID in the form  user@realm!tokenname
#   PROXMOX_TOKEN_SECRET  API token secret
#
# Optional environment variables:
#   PROXMOX_PORT          HTTPS port (default: 8006)
#   PROXMOX_NODE          Node name to audit (default: first node returned by the API)
#   PROXMOX_INSECURE      Set to "true" to skip TLS certificate verification
#   GITHUB_STEP_SUMMARY   Set automatically by GitHub Actions; results are appended here

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
fail() { echo -e "${RED}[FAIL]${RESET}  $*" >&2; }

# Check required tools
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    fail "Required tool '$cmd' is not installed."
    exit 1
  fi
done

# ── configuration ─────────────────────────────────────────────────────────────

: "${PROXMOX_HOST:?PROXMOX_HOST must be set}"
: "${PROXMOX_TOKEN_ID:?PROXMOX_TOKEN_ID must be set}"
: "${PROXMOX_TOKEN_SECRET:?PROXMOX_TOKEN_SECRET must be set}"

PROXMOX_PORT="${PROXMOX_PORT:-8006}"
PROXMOX_INSECURE="${PROXMOX_INSECURE:-false}"
BASE_URL="https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json"

CURL_OPTS=(-sf -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}")
[[ "${PROXMOX_INSECURE}" == "true" ]] && CURL_OPTS+=(-k)

# ── API wrapper ───────────────────────────────────────────────────────────────

pve_get() {
  # Usage: pve_get /path/to/endpoint
  local endpoint="$1"
  curl "${CURL_OPTS[@]}" "${BASE_URL}${endpoint}"
}

# ── markdown helpers ──────────────────────────────────────────────────────────

SUMMARY=""
md() { SUMMARY+="$*"$'\n'; }

md_h1()  { md "# $*"; }
md_h2()  { md "## $*"; }
md_h3()  { md "### $*"; }
md_sep() { md "---"; }

write_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "${SUMMARY}" >> "${GITHUB_STEP_SUMMARY}"
  fi
}

# ── byte conversion ───────────────────────────────────────────────────────────

bytes_to_human() {
  local bytes="${1:-0}"
  if   (( bytes >= 1073741824 )); then printf "%.1f GiB" "$(echo "scale=1; $bytes/1073741824" | bc)"
  elif (( bytes >= 1048576    )); then printf "%.1f MiB" "$(echo "scale=1; $bytes/1048576"    | bc)"
  elif (( bytes >= 1024       )); then printf "%.1f KiB" "$(echo "scale=1; $bytes/1024"       | bc)"
  else printf "%d B" "$bytes"
  fi
}

pct_bar() {
  # Returns a simple text gauge: "███░░ 60%"
  local pct="${1:-0}"
  local filled=$(( pct / 10 ))
  local empty=$(( 10 - filled ))
  local bar=""
  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty;  i++ )); do bar+="░"; done
  printf "%s %d%%" "$bar" "$pct"
}

# ── audit sections ────────────────────────────────────────────────────────────

audit_version() {
  log "Fetching Proxmox version..."
  local data
  data=$(pve_get "/version")
  local version release
  version=$(echo "$data" | jq -r '.data.version')
  release=$(echo "$data" | jq -r '.data.release')
  ok "Proxmox VE ${version} (${release})"
  md_h2 "🖥️ Proxmox VE Version"
  md "| Field | Value |"
  md "|-------|-------|"
  md "| Version | \`${version}\` |"
  md "| Release | \`${release}\` |"
  md ""
}

audit_nodes() {
  log "Fetching node list..."
  local data
  data=$(pve_get "/nodes")
  local node_count
  node_count=$(echo "$data" | jq '.data | length')
  ok "Found ${node_count} node(s)"

  md_h2 "🗂️ Nodes"
  md "| Node | Status | CPUs | CPU Usage | Memory Used | Memory Total | Uptime |"
  md "|------|--------|------|-----------|-------------|--------------|--------|"

  echo "$data" | jq -c '.data[]' | while read -r node; do
    local name status maxcpu cpu mem maxmem uptime_s uptime_h mem_used_h mem_total_h cpu_pct
    name=$(echo "$node" | jq -r '.node')
    status=$(echo "$node" | jq -r '.status')
    maxcpu=$(echo "$node" | jq -r '.maxcpu // 0')
    cpu=$(echo "$node" | jq -r '.cpu // 0')
    mem=$(echo "$node" | jq -r '.mem // 0')
    maxmem=$(echo "$node" | jq -r '.maxmem // 0')
    uptime_s=$(echo "$node" | jq -r '.uptime // 0')

    uptime_h=$(( uptime_s / 3600 ))d\ $(( (uptime_s % 3600) / 60 ))h
    mem_used_h=$(bytes_to_human "$mem")
    mem_total_h=$(bytes_to_human "$maxmem")
    cpu_pct=$(echo "scale=1; $cpu * 100" | bc)

    local status_icon="✅"
    [[ "$status" != "online" ]] && status_icon="❌"

    md "| \`${name}\` | ${status_icon} ${status} | ${maxcpu} | ${cpu_pct}% | ${mem_used_h} | ${mem_total_h} | ${uptime_h} |"
  done
  md ""
}

resolve_node() {
  # Sets global AUDIT_NODE to PROXMOX_NODE if provided, else the first online node
  if [[ -n "${PROXMOX_NODE:-}" ]]; then
    AUDIT_NODE="${PROXMOX_NODE}"
    log "Using node: ${AUDIT_NODE}"
    return
  fi
  local data
  data=$(pve_get "/nodes")
  AUDIT_NODE=$(echo "$data" | jq -r '[.data[] | select(.status=="online")] | first | .node')
  if [[ -z "${AUDIT_NODE}" || "${AUDIT_NODE}" == "null" ]]; then
    fail "No online nodes found."
    exit 1
  fi
  log "Auto-selected node: ${AUDIT_NODE}"
}

audit_node_status() {
  log "Fetching status for node ${AUDIT_NODE}..."
  local data
  data=$(pve_get "/nodes/${AUDIT_NODE}/status")

  local cpu_pct mem_used mem_total mem_pct rootfs_used rootfs_total rootfs_pct
  cpu_pct=$(echo "$data" | jq -r '.data.cpu // 0' | awk '{printf "%.1f", $1*100}')
  mem_used=$(echo "$data" | jq -r '.data.memory.used // 0')
  mem_total=$(echo "$data" | jq -r '.data.memory.total // 0')
  rootfs_used=$(echo "$data" | jq -r '.data.rootfs.used // 0')
  rootfs_total=$(echo "$data" | jq -r '.data.rootfs.total // 0')

  mem_pct=$(echo "scale=0; $mem_used * 100 / $mem_total" | bc 2>/dev/null || echo 0)
  rootfs_pct=$(echo "scale=0; $rootfs_used * 100 / $rootfs_total" | bc 2>/dev/null || echo 0)

  ok "Node ${AUDIT_NODE} — CPU ${cpu_pct}% | Memory $(pct_bar "$mem_pct") | Root FS $(pct_bar "$rootfs_pct")"

  md_h2 "📊 Node Resource Usage (${AUDIT_NODE})"
  md "| Resource | Used | Total | Usage |"
  md "|----------|------|-------|-------|"
  md "| CPU | ${cpu_pct}% | 100% | $(pct_bar "${cpu_pct%%.*}") |"
  md "| Memory | $(bytes_to_human "$mem_used") | $(bytes_to_human "$mem_total") | $(pct_bar "$mem_pct") |"
  md "| Root FS | $(bytes_to_human "$rootfs_used") | $(bytes_to_human "$rootfs_total") | $(pct_bar "$rootfs_pct") |"
  md ""
}

audit_vms() {
  log "Fetching virtual machines on ${AUDIT_NODE}..."
  local data
  data=$(pve_get "/nodes/${AUDIT_NODE}/qemu")
  local total running stopped
  total=$(echo "$data" | jq '.data | length')
  running=$(echo "$data" | jq '[.data[] | select(.status=="running")] | length')
  stopped=$(echo "$data" | jq '[.data[] | select(.status=="stopped")] | length')
  ok "VMs — total: ${total}  running: ${running}  stopped: ${stopped}"

  md_h2 "💻 Virtual Machines (QEMU/KVM)"
  if (( total == 0 )); then
    md "_No virtual machines found._"
    md ""
    return
  fi

  md "| VMID | Name | Status | CPUs | CPU Usage | Memory Used | Memory Alloc |"
  md "|------|------|--------|------|-----------|-------------|--------------|"

  echo "$data" | jq -c '.data[] | [.vmid,.name,.status,.cpus,.cpu,.mem,.maxmem] | @tsv' -r | \
  while IFS=$'\t' read -r vmid name status cpus cpu mem maxmem; do
    local status_icon cpu_pct mem_used_h mem_total_h
    status_icon="✅"
    [[ "$status" == "stopped" ]] && status_icon="⏹️"
    [[ "$status" != "running" && "$status" != "stopped" ]] && status_icon="⚠️"
    cpu_pct=$(echo "scale=1; ${cpu:-0} * 100" | bc)
    mem_used_h=$(bytes_to_human "${mem:-0}")
    mem_total_h=$(bytes_to_human "${maxmem:-0}")
    md "| ${vmid} | \`${name}\` | ${status_icon} ${status} | ${cpus} | ${cpu_pct}% | ${mem_used_h} | ${mem_total_h} |"
  done
  md ""
}

audit_containers() {
  log "Fetching LXC containers on ${AUDIT_NODE}..."
  local data
  data=$(pve_get "/nodes/${AUDIT_NODE}/lxc")
  local total running stopped
  total=$(echo "$data" | jq '.data | length')
  running=$(echo "$data" | jq '[.data[] | select(.status=="running")] | length')
  stopped=$(echo "$data" | jq '[.data[] | select(.status=="stopped")] | length')
  ok "Containers — total: ${total}  running: ${running}  stopped: ${stopped}"

  md_h2 "📦 LXC Containers"
  if (( total == 0 )); then
    md "_No LXC containers found._"
    md ""
    return
  fi

  md "| CTID | Name | Status | CPUs | CPU Usage | Memory Used | Memory Alloc |"
  md "|------|------|--------|------|-----------|-------------|--------------|"

  echo "$data" | jq -c '.data[] | [.vmid,.name,.status,.cpus,.cpu,.mem,.maxmem] | @tsv' -r | \
  while IFS=$'\t' read -r ctid name status cpus cpu mem maxmem; do
    local status_icon cpu_pct mem_used_h mem_total_h
    status_icon="✅"
    [[ "$status" == "stopped" ]] && status_icon="⏹️"
    [[ "$status" != "running" && "$status" != "stopped" ]] && status_icon="⚠️"
    cpu_pct=$(echo "scale=1; ${cpu:-0} * 100" | bc)
    mem_used_h=$(bytes_to_human "${mem:-0}")
    mem_total_h=$(bytes_to_human "${maxmem:-0}")
    md "| ${ctid} | \`${name}\` | ${status_icon} ${status} | ${cpus} | ${cpu_pct}% | ${mem_used_h} | ${mem_total_h} |"
  done
  md ""
}

audit_storage() {
  log "Fetching storage on ${AUDIT_NODE}..."
  local data
  data=$(pve_get "/nodes/${AUDIT_NODE}/storage")

  md_h2 "🗄️ Storage Pools"
  local total
  total=$(echo "$data" | jq '.data | length')
  if (( total == 0 )); then
    md "_No storage pools found._"
    md ""
    return
  fi

  md "| Storage | Type | Status | Used | Total | Usage |"
  md "|---------|------|--------|------|-------|-------|"

  echo "$data" | jq -c '.data[] | [.storage,.type,.active,.used,.total,.avail] | @tsv' -r | \
  while IFS=$'\t' read -r storage type active used total avail; do
    local status_icon used_h total_h pct
    status_icon="✅"
    [[ "${active}" != "1" ]] && status_icon="❌"
    used_h=$(bytes_to_human "${used:-0}")
    total_h=$(bytes_to_human "${total:-0}")
    pct=0
    (( total > 0 )) && pct=$(echo "scale=0; ${used:-0} * 100 / ${total}" | bc 2>/dev/null || echo 0)
    md "| \`${storage}\` | ${type} | ${status_icon} | ${used_h} | ${total_h} | $(pct_bar "$pct") |"
  done
  md ""
}

audit_network() {
  log "Fetching network interfaces on ${AUDIT_NODE}..."
  local data
  data=$(pve_get "/nodes/${AUDIT_NODE}/network")

  md_h2 "🌐 Network Interfaces"
  local total
  total=$(echo "$data" | jq '.data | length')
  if (( total == 0 )); then
    md "_No network interfaces found._"
    md ""
    return
  fi

  md "| Interface | Type | Active | CIDR / Bridge Ports |"
  md "|-----------|------|--------|---------------------|"

  echo "$data" | jq -c '.data[]' | while read -r iface; do
    local iname itype active cidr bridge_ports detail
    iname=$(echo "$iface" | jq -r '.iface')
    itype=$(echo "$iface" | jq -r '.type // "-"')
    active=$(echo "$iface" | jq -r '.active // 0')
    cidr=$(echo "$iface" | jq -r '.cidr // "-"')
    bridge_ports=$(echo "$iface" | jq -r '.bridge_ports // "-"')
    detail="${cidr}"
    [[ "${itype}" == "bridge" ]] && detail="${bridge_ports}"
    local status_icon="✅"
    [[ "${active}" != "1" ]] && status_icon="❌"
    md "| \`${iname}\` | ${itype} | ${status_icon} | ${detail} |"
  done
  md ""
}

audit_tasks() {
  log "Fetching recent tasks on ${AUDIT_NODE}..."
  local data
  data=$(pve_get "/nodes/${AUDIT_NODE}/tasks?limit=20")

  md_h2 "📋 Recent Tasks (last 20)"
  local total
  total=$(echo "$data" | jq '.data | length')
  if (( total == 0 )); then
    md "_No recent tasks found._"
    md ""
    return
  fi

  md "| Started | Type | Status | User |"
  md "|---------|------|--------|------|"

  echo "$data" | jq -c '.data[]' | while read -r task; do
    local starttime type status user started_fmt
    starttime=$(echo "$task" | jq -r '.starttime // 0')
    type=$(echo "$task" | jq -r '.type // "-"')
    status=$(echo "$task" | jq -r '.status // "running"')
    user=$(echo "$task" | jq -r '.user // "-"')
    started_fmt=$(date -d "@${starttime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${starttime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${starttime}")
    local status_icon="✅"
    [[ "$status" != "OK" && "$status" != "ok" ]] && status_icon="⚠️"
    [[ -z "$status" || "$status" == "running" ]] && status_icon="🔄"
    md "| ${started_fmt} | ${type} | ${status_icon} ${status} | ${user} |"
  done
  md ""
}

audit_cluster() {
  log "Checking cluster status..."
  local data
  data=$(pve_get "/cluster/status" 2>/dev/null) || { warn "Cluster API unavailable (standalone node?)."; return; }

  local is_cluster
  is_cluster=$(echo "$data" | jq '[.data[] | select(.type=="cluster")] | length')
  if (( is_cluster == 0 )); then
    log "No cluster configured (standalone Proxmox node)."
    return
  fi

  md_h2 "🔗 Cluster Status"
  md "| Member | Type | Status | Online |"
  md "|--------|------|--------|--------|"

  echo "$data" | jq -c '.data[]' | while read -r item; do
    local iname itype ip online quorate
    iname=$(echo "$item" | jq -r '.name // .id')
    itype=$(echo "$item" | jq -r '.type')
    ip=$(echo "$item" | jq -r '.ip // "-"')
    online=$(echo "$item" | jq -r '.online // "-"')
    quorate=$(echo "$item" | jq -r '.quorate // "-"')
    local status_icon="✅"
    [[ "${online}" == "0" ]] && status_icon="❌"
    local extra=""
    [[ "${itype}" == "cluster" ]] && extra=" (quorate: ${quorate})"
    md "| \`${iname}\` | ${itype} | ${status_icon}${extra} | ${online} |"
  done
  md ""
}

# ── main ──────────────────────────────────────────────────────────────────────

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
LOG_FILE="/tmp/proxmox_audit_$(date -u '+%Y%m%d_%H%M%S').log"

# Tee stdout/stderr to a log file for artifact upload
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}   Proxmox Audit — ${TIMESTAMP}${RESET}"
echo -e "${BOLD}   Host: ${PROXMOX_HOST}${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

md_h1 "🔍 Proxmox Audit Report"
md "> **Host:** \`${PROXMOX_HOST}\`  |  **Date:** ${TIMESTAMP}"
md ""
md_sep
md ""

audit_version
audit_cluster
resolve_node
audit_node_status
audit_vms
audit_containers
audit_storage
audit_network
audit_tasks

write_summary

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${GREEN}Audit complete.${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
