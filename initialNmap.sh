#!/bin/bash
#
# Lightweight nmap kickoff script — just starts the scans for an assessment/box.
#
# Usage: sudo ./scan.sh <target>
#   <target> can be:
#     - a single IP        e.g. 10.10.10.5
#     - a CIDR range       e.g. 10.10.10.0/24
#     - a file of targets  one IP/host per line ('#' for comments, blanks ignored)

# --- root check ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run with root"
  exit 13
fi

# --- arg check ---
if [ $# -eq 0 ]; then
  echo "Usage: $0 <ip | cidr | file>"
  exit 2
fi

TARGET="$1"

# --- build the target list ---
declare -a targets
if [ -f "$TARGET" ]; then
  # File of targets: drop comments/blank lines, strip stray CRs from Windows files
  mapfile -t targets < <(grep -vE '^[[:space:]]*(#|$)' "$TARGET" | tr -d '\r')
elif [[ "$TARGET" == */* ]]; then
  # CIDR range: expand to individual hosts so each gets its own labelled output
  mapfile -t targets < <(nmap -n -sL "$TARGET" | awk '/Nmap scan report/{print $NF}')
else
  # Single IP / hostname
  targets=("$TARGET")
fi

if [ "${#targets[@]}" -eq 0 ]; then
  echo "No targets found in '$TARGET'"
  exit 1
fi

# --- scan definitions (flags left exactly as your original) ---
initial_scan()  { echo "[*] Initial scan : $1"; nmap -T4 -oA "$2/initialScan" "$1"; }
full_tcp_scan() { echo "[*] Full TCP scan: $1"; nmap -T4 -p- -A -oA "$2/FullTCP" "$1"; }
udp_scan()      { echo "[*] UDP scan     : $1"; nmap -T4 -sU --max-retries 5 -oA "$2/UDPScan" "$1"; }

# --- run ---
mkdir -p scans

if [ "${#targets[@]}" -eq 1 ]; then
  # Single target: flat output, original ordering
  ip="${targets[0]}"
  initial_scan  "$ip" "scans"
  full_tcp_scan "$ip" "scans"
  udp_scan      "$ip" "scans"
else
  # Multiple targets: per-IP output dirs.
  # Phase 1: quick scan every host. Phase 2: full TCP every host. Phase 3: UDP last.
  for ip in "${targets[@]}"; do
    mkdir -p "scans/$ip"
    initial_scan "$ip" "scans/$ip"
  done
  for ip in "${targets[@]}"; do
    full_tcp_scan "$ip" "scans/$ip"
  done
  for ip in "${targets[@]}"; do
    udp_scan "$ip" "scans/$ip"
  done
fi

# --- hand ownership back to the invoking user so you don't need sudo to edit results ---
if [ -n "$SUDO_USER" ]; then
  chown -R "$SUDO_USER:$SUDO_USER" scans
fi
