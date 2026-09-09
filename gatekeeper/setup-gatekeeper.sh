#!/bin/bash
# setup-gatekeeper.sh — Gatekeeper VM setup
#
# Installs and configures everything the jump host needs:
#   - Node.js runtime + GoTo (ForceCommand)
#   - SQLite database with the zone/VM schema (GoTo opens it read-only)
#   - Hardened sshd_config with CA-only auth and GoTo as ForceCommand
#   - Role keypairs per zone (and per zone × tech-user)
#   - Per-role ssh-agent units for non-root role-credential access
#
# Zones are fully dynamic: pass any names you want with --zones. Hosts are
# registered afterwards with add-host.sh on this machine.
set -euo pipefail

ZONES=""
TECH_USERS="observer,operator"
SUPERUSER_ZONE="admin"
ADDRESS=""
CA_PUBKEY="./user_ca_key.pub"
GOTO_LIB="/usr/local/lib/goto"
KEYS_DIR="/etc/goto/keys"
DB_DIR="/var/lib/goto"
DB_PATH="$DB_DIR/gatekeeper.db"

usage() {
  cat <<EOF
Usage: ${0##*/} -z <zone1,zone2,...> -a <public-address> [OPTIONS]

Options:
  -z, --zones <z1,z2,...>       Zone names to create (comma-separated, required)
  -a, --address <host-or-ip>    Public address of this Gatekeeper, used in
                                the sshuttle command and config (required)
  -t, --tech-users <t1,t2>      Tech-user suffixes (default: $TECH_USERS)
  -s, --superuser-zone <name>   Superuser zone name (default: $SUPERUSER_ZONE;
                                sees all hosts, gets Shell>; "" to skip)
  -c, --ca-pubkey <path>        CA public key file (default: $CA_PUBKEY)
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -z|--zones)          ZONES="$2"; shift 2 ;;
    -a|--address)        ADDRESS="$2"; shift 2 ;;
    -t|--tech-users)     TECH_USERS="$2"; shift 2 ;;
    -s|--superuser-zone) SUPERUSER_ZONE="$2"; shift 2 ;;
    -c|--ca-pubkey)      CA_PUBKEY="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $(id -u) -ne 0 ]]  && { echo "This script must be run as root!" >&2; exit 1; }
[[ -z "$ZONES" ]]     && { usage; echo "Zones are required (-z)" >&2; exit 1; }
[[ -z "$ADDRESS" ]]   && { usage; echo "Public address is required (-a)" >&2; exit 1; }

# -c accepts a remote scp-style path (root@ca-vm:/etc/ssh/ca/user_ca_key.pub)
# so you don't need to hop back to the CA VM just to copy one file.
if [[ "$CA_PUBKEY" == *":"* ]]; then
  TMP_CA=$(mktemp)
  scp -q "$CA_PUBKEY" "$TMP_CA"
  CA_PUBKEY="$TMP_CA"
fi
[[ -f "$CA_PUBKEY" ]] || { echo "CA public key not found: $CA_PUBKEY" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OS_ID=""
[[ -f /etc/os-release ]] && OS_ID=$(. /etc/os-release && echo "$ID")

echo "### Installing dependencies ###"
case "$OS_ID" in
  opensuse*|sles)
    # gcc/make/python3 only needed if better-sqlite3 has no prebuilt binary
    zypper install -y openssh nodejs npm sqlite3 gcc gcc-c++ make python3
    ;;
  *)
    apt update
    apt install -y openssh-server nodejs npm sqlite3 build-essential python3
    ;;
esac

NODE_BIN="$(command -v node)"
[[ -n "$NODE_BIN" ]] || { echo "node not found in PATH after install" >&2; exit 1; }
NODE_MAJOR="$("$NODE_BIN" -v | sed 's/^v//' | cut -d. -f1)"
if (( NODE_MAJOR < 20 )); then
  echo "Node.js >= 20 (LTS) is required; found $("$NODE_BIN" -v)." >&2
  echo "Install an LTS release (e.g. via NodeSource or nvm) and re-run, or" >&2
  echo "edit /usr/local/bin/goto afterwards to point at the right binary." >&2
  exit 1
fi

echo "### Creating goto group ###"
groupadd -f goto

echo "### Initializing SQLite database ###"
mkdir -p "$DB_DIR"
sqlite3 "$DB_PATH" < "$REPO_DIR/db/schema.sql"
chown -R root:goto "$DB_DIR"
chmod 0750 "$DB_DIR"
chmod 0640 "$DB_PATH"

echo "### Seeding zones ###"
IFS=',' read -ra ZONE_ARR <<< "$ZONES"
for Z in "${ZONE_ARR[@]}"; do
  Z="$(echo "$Z" | xargs)"
  sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO zone (name) VALUES ('$Z')"
done
if [[ -n "$SUPERUSER_ZONE" ]]; then
  sqlite3 "$DB_PATH" "INSERT INTO zone (name, superuser) VALUES ('$SUPERUSER_ZONE', 1)
                      ON CONFLICT(name) DO UPDATE SET superuser = 1"
fi
chmod 0640 "$DB_PATH"
echo "Set zone inheritance if needed with e.g.:"
echo "  add-zone.sh -z analyst -I marketing,sales"

echo "### Installing CA public key ###"
install -o root -g root -m 0644 "$CA_PUBKEY" /etc/ssh/user_ca_key.pub

echo "### Installing hardened sshd_config ###"
install -o root -g root -m 0644 "$SCRIPT_DIR/sshd_config.gatekeeper" /etc/ssh/sshd_config
mkdir -p /etc/ssh/principals
chmod 0755 /etc/ssh/principals

echo "### Creating role keypairs ###"
mkdir -p "$KEYS_DIR"
chmod 0750 "$KEYS_DIR"
chown root:goto "$KEYS_DIR"

ALL_ROLES=()
IFS=',' read -ra TECH_ARR <<< "$TECH_USERS"
for Z in "${ZONE_ARR[@]}"; do
  Z="$(echo "$Z" | xargs)"
  ALL_ROLES+=("$Z")
  for T in "${TECH_ARR[@]}"; do
    T="$(echo "$T" | xargs)"
    ALL_ROLES+=("$Z-$T")
  done
done
[[ -n "$SUPERUSER_ZONE" ]] && ALL_ROLES+=("$SUPERUSER_ZONE")

for ROLE in "${ALL_ROLES[@]}"; do
  if [[ ! -f "$KEYS_DIR/$ROLE" ]]; then
    ssh-keygen -t ed25519 -f "$KEYS_DIR/$ROLE" -C "goto-role-$ROLE" -N ""
  fi
done
chown root:goto "$KEYS_DIR"/*
chmod 0640 "$KEYS_DIR"/*

echo "### Installing GoTo ###"
mkdir -p "$GOTO_LIB"
install -o root -g root -m 0644 "$SCRIPT_DIR/goto/index.mjs" "$GOTO_LIB/index.mjs"
install -o root -g root -m 0644 "$SCRIPT_DIR/goto/package.json" "$GOTO_LIB/package.json"
( cd "$GOTO_LIB" && npm install --omit=dev )

# ForceCommand wrapper — explicit node binary, no symlink
cat > /usr/local/bin/goto <<EOF
#!/bin/bash
cd $GOTO_LIB && exec $NODE_BIN index.mjs "\$@"
EOF
chmod 0755 /usr/local/bin/goto

mkdir -p /etc/goto
if [[ ! -f /etc/goto/config.json ]]; then
  cat > /etc/goto/config.json <<EOF
{
  "db": {
    "path": "$DB_PATH"
  },
  "gatekeeper": {
    "address": "$ADDRESS",
    "sshuttleExclude": "$ADDRESS"
  },
  "endpointPort": 22,
  "keysDir": "$KEYS_DIR",
  "agentDir": "/run/goto"
}
EOF
fi
chown root:goto /etc/goto/config.json
chmod 0640 /etc/goto/config.json

echo "### Installing helper scripts ###"
install -o root -g root -m 0750 "$SCRIPT_DIR/add-zone.sh" /usr/local/sbin/add-zone.sh
install -o root -g root -m 0750 "$SCRIPT_DIR/add-host.sh" /usr/local/sbin/add-host.sh
install -o root -g root -m 0750 "$REPO_DIR/endpoint/setup-endpoint.sh" /usr/local/sbin/setup-endpoint.sh

# Endpoint payload — setup-endpoint.sh pushes this to targets over SSH
install -d -o root -g root -m 0755 /usr/local/share/gatekeeper
install -o root -g root -m 0644 "$REPO_DIR/endpoint/sshd_config.endpoint" /usr/local/share/gatekeeper/sshd_config.endpoint

echo "### Installing per-role agent units ###"
install -o root -g root -m 0755 "$REPO_DIR/systemd/goto-agent-load" /usr/local/sbin/goto-agent-load
install -o root -g root -m 0644 "$REPO_DIR/systemd/goto-agent@.service" /etc/systemd/system/goto-agent@.service
systemctl daemon-reload
for ROLE in "${ALL_ROLES[@]}"; do
  systemctl enable --now "goto-agent@$ROLE"
done

systemctl reload sshd 2>/dev/null || systemctl reload ssh

echo
echo "Done. Next steps (all signing stays on the CA VM, endpoints deploy from here):"
echo "  1. On the CA VM, sign the role keys and mint your users:"
echo "       create-role-certs.sh -g $ADDRESS -i <this-host-public-ip>"
echo "       mintcert.sh -u alice -p <zone> [-t observer|operator] -k alice.pub -g $ADDRESS"
echo "  2. Deploy each endpoint with ONE command from this machine:"
echo "       setup-endpoint.sh -n <name> -i <ip> -z <zones> --enable"
