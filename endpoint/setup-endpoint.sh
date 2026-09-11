#!/bin/bash
# setup-endpoint.sh — provision AND register an endpoint, in one command
#
# Default mode (run on the GATEKEEPER):
#   setup-endpoint.sh -n crm-prod -i 192.168.10.11 -z marketing --enable
# pushes this script, the hardened sshd_config, and the CA public key to the
# target over your existing (pre-Gatekeeper) root SSH access, runs the
# provisioning remotely, registers the host in the local database, and
# optionally flips it live. You never log into the endpoint yourself.
#
# --local mode (what actually runs on the endpoint; also usable standalone):
#   creates, for each zone in -z:
#     <zone>          principals file: <zone>
#     <zone>-<tech>   principals file: <zone>, <tech>, <zone>-<tech>
#                     (the compound line is required — the role cert signed
#                     by create-role-certs.sh carries <zone>-<tech> as one
#                     single principal, not <zone> and <tech> separately)
#   plus the superuser zone user, and installs the CA-only sshd_config.
#
# Reverse: add -r to either mode to undo (remote reverse also deletes the
# host's database row).
set -euo pipefail

MODE="remote"
NAME=""
IP=""
ZONE=""
TECH_USERS="observer,operator"
SUPERUSER_ZONE="admin"
SSH_USER="root"
ENABLE=false
AUTHORIZATION=false
REVERSE=false
VERBOSE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_PUBKEY="/etc/ssh/user_ca_key.pub"

usage() {
  cat <<EOF
Usage (on the Gatekeeper):
  ${0##*/} -n <name> -i <ip> -z <zone1,zone2,...> [OPTIONS]

Options:
  -n, --name <name>            Host name ID for registration (required)
  -i, --ip <address>           Host IP (SSH target and registered IPv4) (required)
  -z, --zones <z1,z2,...>      RBAC zone(s) for this host, comma-separated (required)
  -t, --tech-users <t1,t2>     Tech-user suffixes (default: $TECH_USERS; "" for none)
  -s, --superuser-zone <name>  Superuser zone always provisioned (default: $SUPERUSER_ZONE)
      --ssh-user <user>        Bootstrap SSH user on the endpoint (default: $SSH_USER)
      --authorization          Register as self-managed authorization host
      --enable                 Flip the host live immediately
  -r, --reverse                Undo: remove users/config on the host and its DB row
      --local                  Run the provisioning on THIS machine instead of
                               deploying to a remote one (expects user_ca_key.pub
                               and sshd_config.endpoint next to the script)
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)             MODE="local"; shift ;;
    -v|--verbose)        VERBOSE=true; shift ;;
    -n|--name)           NAME="$2"; shift 2 ;;
    -i|--ip)             IP="$2"; shift 2 ;;
    -z|--zones)          ZONE="$2"; shift 2 ;;
    -t|--tech-users)     TECH_USERS="$2"; shift 2 ;;
    -s|--superuser-zone) SUPERUSER_ZONE="$2"; shift 2 ;;
    --ssh-user)          SSH_USER="$2"; shift 2 ;;
    --authorization)     AUTHORIZATION=true; shift ;;
    --enable)            ENABLE=true; shift ;;
    -r|--reverse)        REVERSE=true; shift ;;
    -h|--help)           usage; exit 0 ;;
    -*)                  echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)                   usage; break ;;
  esac
done

[[ $(id -u) -ne 0 ]] && { echo "This script must be run as root!" >&2; exit 1; }
[[ -z "$ZONE" ]] && { usage; echo "Zones are required (-z)" >&2; exit 1; }

# ─────────────────────────────── local mode ───────────────────────────────────
# The provisioning that runs on the endpoint itself.

OS_ID=""
[[ -f /etc/os-release ]] && OS_ID=$(. /etc/os-release && echo "$ID")

user_add() {
  id -u "$1" &>/dev/null || useradd -s /bin/bash -m "$1"
}

user_del() {
  case "$OS_ID" in
    opensuse*|sles) id -u "$1" &>/dev/null && userdel -r "$1" || true ;;
    *)              id -u "$1" &>/dev/null && deluser --remove-home "$1" || true ;;
  esac
}

write_principals() {
  # write_principals <unix-user> <principal>...
  local u="$1"; shift
  install -D -o root -g root -m 0644 /dev/null "/etc/ssh/principals/$u"
  printf '%s\n' "$@" > "/etc/ssh/principals/$u"
}

zone_list() { echo "${ZONE//,/ }"; }
tech_list() { [[ -n "$TECH_USERS" ]] && echo "${TECH_USERS//,/ }"; }

local_setup() {
  echo "### Copying CA pubKey ###"
  install -D -o root -g root -m 0644 "$SCRIPT_DIR/user_ca_key.pub" /etc/ssh/user_ca_key.pub

  echo "### Copying hardened sshd_config ###"
  install -D -o root -g root -m 0644 "$SCRIPT_DIR/sshd_config.endpoint" /etc/ssh/sshd_config

  mkdir -p /etc/ssh/principals && chmod 0755 /etc/ssh/principals

  echo "### Creating principals & technical users ###"

  for z in $(zone_list); do
    [[ "$z" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Invalid zone name: $z" >&2; exit 1; }

    # Base zone user — cert must carry "<zone>"
    user_add "$z"
    write_principals "$z" "$z"

    # Tech-user variants — cert carries the single compound principal
    # "<zone>-<tech>" (create-role-certs.sh signs the role key with its
    # filename as one principal, not "<zone>" + "<tech>" separately), so the
    # principals file must contain that exact compound string to match.
    for t in $(tech_list); do
      user_add "$z-$t"
      write_principals "$z-$t" "$z" "$t" "$z-$t"
    done
  done

  # Superuser zone is always present
  if [[ -n "$SUPERUSER_ZONE" ]]; then
    user_add "$SUPERUSER_ZONE"
    write_principals "$SUPERUSER_ZONE" "$SUPERUSER_ZONE"
  fi

  systemctl reload sshd 2>/dev/null || systemctl reload ssh
  echo "### Endpoint provisioned ###"
}

local_reverse() {
  for z in $(zone_list); do
    user_del "$z"
    for t in $(tech_list); do
      user_del "$z-$t"
    done
  done

  [[ -n "$SUPERUSER_ZONE" ]] && user_del "$SUPERUSER_ZONE"

  rm -f /etc/ssh/user_ca_key.pub
  rm -f /etc/ssh/principals/*

  systemctl restart sshd 2>/dev/null || systemctl restart ssh
  echo "### Endpoint reverted ###"
}

if [[ "$MODE" == "local" ]]; then
  $REVERSE && local_reverse || local_setup
  exit 0
fi

# ─────────────────────────────── remote mode ──────────────────────────────────
# Orchestration from the Gatekeeper: push payload, run --local remotely,
# register/deregister the host in the local database.

[[ -z "$NAME" ]] && { usage; echo "Host name is required (-n)" >&2; exit 1; }
[[ -z "$IP" ]]   && { usage; echo "Host IP is required (-i)" >&2; exit 1; }

# sshd_config.endpoint: next to the script (repo checkout) or installed payload
SSHD_CONFIG=""
for CANDIDATE in "$SCRIPT_DIR/sshd_config.endpoint" /usr/local/share/gatekeeper/sshd_config.endpoint; do
  [[ -f "$CANDIDATE" ]] && { SSHD_CONFIG="$CANDIDATE"; break; }
done
[[ -n "$SSHD_CONFIG" ]] || { echo "sshd_config.endpoint not found (run setup-gatekeeper.sh first)" >&2; exit 1; }
[[ -f "$CA_PUBKEY" ]]   || { echo "CA public key not found at $CA_PUBKEY" >&2; exit 1; }

# add-host.sh: installed, or sibling in the repo checkout
ADD_HOST="$(command -v add-host.sh || true)"
[[ -z "$ADD_HOST" && -x "$SCRIPT_DIR/../gatekeeper/add-host.sh" ]] && ADD_HOST="$SCRIPT_DIR/../gatekeeper/add-host.sh"
[[ -n "$ADD_HOST" ]] || { echo "add-host.sh not found" >&2; exit 1; }

REMOTE="$SSH_USER@$IP"

echo "### Pushing payload to $REMOTE ###"
TMP=$(ssh "$REMOTE" "mktemp -d")
scp -q "${BASH_SOURCE[0]}" "$REMOTE:$TMP/setup-endpoint.sh"
scp -q "$SSHD_CONFIG" "$REMOTE:$TMP/sshd_config.endpoint"
scp -q "$CA_PUBKEY" "$REMOTE:$TMP/user_ca_key.pub"

if $REVERSE; then
  echo "### Reverting endpoint $IP ###"
  ssh -t "$REMOTE" "bash '$TMP/setup-endpoint.sh' --local -r -z '$ZONE' -t '$TECH_USERS' -s '$SUPERUSER_ZONE'; rc=\$?; rm -rf '$TMP'; exit \$rc"

  echo "### Removing host from database ###"
  "$ADD_HOST" --delete "$NAME"
else
  echo "### Provisioning endpoint $IP ###"
  ssh -t "$REMOTE" "bash '$TMP/setup-endpoint.sh' --local -z '$ZONE' -t '$TECH_USERS' -s '$SUPERUSER_ZONE'; rc=\$?; rm -rf '$TMP'; exit \$rc"

  echo "### Registering host in database ###"
  ADD_ARGS=(-n "$NAME" -i "$IP" -z "$ZONE")
  $AUTHORIZATION && ADD_ARGS+=(--authorization)
  "$ADD_HOST" "${ADD_ARGS[@]}"

  if $ENABLE; then
    "$ADD_HOST" --enable "$NAME"
  else
    echo "Host registered with enabled=0. Go live with: add-host.sh --enable $NAME"
  fi
fi
