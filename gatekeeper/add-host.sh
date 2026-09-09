#!/bin/bash
# add-host.sh — register, enable, list, or remove destination hosts
#
# Runs on the Gatekeeper (root). Replaces remote DB self-registration:
# endpoints are provisioned with setup-endpoint.sh, then registered here.
# New hosts start with enabled=0 — going live is an explicit --enable.
set -euo pipefail

DB_PATH="/var/lib/goto/gatekeeper.db"
NAME=""
IP=""
ZONES=""
AUTHORIZATION=0
ACTION="add"
TARGET=""

usage() {
  cat <<EOF
Usage:
  ${0##*/} -n <name> -i <ip> -z <zone1,zone2,...> [--authorization]   Register a host (enabled=0)
  ${0##*/} --enable <name>                                            Set enabled=1
  ${0##*/} --disable <name>                                           Set enabled=0
  ${0##*/} --delete <name>                                            Remove a host
  ${0##*/} --list                                                     List all hosts

Options:
  -n, --name <name>        Host name ID (unique)
  -i, --ip <address>       Host IPv4 address
  -z, --zones <z1,z2,...>  Zones this host belongs to (comma-separated)
      --authorization      Self-managed authorization: GoTo connects with the
                           caller's real login instead of the role user
      --db <path>          Database path (default: $DB_PATH)
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)        NAME="$2"; shift 2 ;;
    -i|--ip)          IP="$2"; shift 2 ;;
    -z|--zones)       ZONES="$2"; shift 2 ;;
    --authorization)  AUTHORIZATION=1; shift ;;
    --enable)         ACTION="enable";  TARGET="$2"; shift 2 ;;
    --disable)        ACTION="disable"; TARGET="$2"; shift 2 ;;
    --delete)         ACTION="delete";  TARGET="$2"; shift 2 ;;
    --list)           ACTION="list"; shift ;;
    --db)             DB_PATH="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $(id -u) -ne 0 ]] && { echo "This script must be run as root!" >&2; exit 1; }
[[ -f "$DB_PATH" ]]  || { echo "Database not found at $DB_PATH" >&2; exit 1; }

fix_perms() {
  chown root:goto "$DB_PATH"
  chmod 0640 "$DB_PATH"
}

case "$ACTION" in
  add)
    [[ -z "$NAME" ]]  && { usage; echo "Host name is required (-n)" >&2; exit 1; }
    [[ -z "$IP" ]]    && { usage; echo "Host IP is required (-i)" >&2; exit 1; }
    [[ -z "$ZONES" ]] && { usage; echo "Zones are required (-z)" >&2; exit 1; }

    # Warn about zones that don't exist yet (typos won't route)
    for z in ${ZONES//,/ }; do
      if [[ "$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM zone WHERE name='$z'")" == "0" ]]; then
        echo "Warning: zone '$z' does not exist in the zone table (add-zone.sh -z $z)" >&2
      fi
    done

    sqlite3 "$DB_PATH" \
      "INSERT INTO VM (nameID, ipv4, zone, enabled, \"authorization\")
       VALUES ('$NAME', '$IP', '$ZONES', 0, $AUTHORIZATION)"
    fix_perms
    echo "Registered '$NAME' ($IP, zones: $ZONES) with enabled=0."
    echo "Go live with: ${0##*/} --enable $NAME"
    ;;
  enable)
    sqlite3 "$DB_PATH" "UPDATE VM SET enabled=1 WHERE nameID='$TARGET'"
    fix_perms
    echo "Host '$TARGET' enabled."
    ;;
  disable)
    sqlite3 "$DB_PATH" "UPDATE VM SET enabled=0 WHERE nameID='$TARGET'"
    fix_perms
    echo "Host '$TARGET' disabled."
    ;;
  delete)
    sqlite3 "$DB_PATH" "DELETE FROM VM WHERE nameID='$TARGET'"
    fix_perms
    echo "Host '$TARGET' removed."
    ;;
  list)
    sqlite3 -header -column "$DB_PATH" \
      'SELECT nameID, ipv4, zone, enabled, "authorization" FROM VM ORDER BY zone, nameID'
    ;;
esac
