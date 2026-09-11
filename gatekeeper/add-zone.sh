#!/bin/bash
# add-zone.sh — add a new zone to a running Gatekeeper
#
# Creates the zone row and generates the role keypairs (base + tech-user
# variants). Role certs still need signing on the CA VM afterwards
# (create-role-certs.sh).
set -euo pipefail

ZONE=""
TECH_USERS="observer,operator"
INHERITS=""
SUPERUSER=0
KEYS_DIR="/etc/goto/keys"
DB_PATH="/var/lib/goto/gatekeeper.db"

usage() {
  cat <<EOF
Usage: ${0##*/} -z <zone> [OPTIONS]

Options:
  -z, --zone <name>         Zone name (required)
  -t, --tech-users <t1,t2>  Tech-user suffixes (default: $TECH_USERS; "" for none)
  -I, --inherits <z1,z2>    Zones whose hosts this zone also sees
  -S, --superuser           Mark the zone as superuser
      --db <path>           Database path (default: $DB_PATH)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -z|--zone)       ZONE="$2"; shift 2 ;;
    -t|--tech-users) TECH_USERS="$2"; shift 2 ;;
    -I|--inherits)   INHERITS="$2"; shift 2 ;;
    -S|--superuser)  SUPERUSER=1; shift ;;
    --db)            DB_PATH="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $(id -u) -ne 0 ]] && { echo "This script must be run as root!" >&2; exit 1; }
[[ -z "$ZONE" ]] && { usage; echo "Zone name is required (-z)" >&2; exit 1; }
[[ "$ZONE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Zone name must match [a-z0-9-]" >&2; exit 1; }
[[ -f "$DB_PATH" ]] || { echo "Database not found at $DB_PATH" >&2; exit 1; }

echo "### Registering zone in DB ###"
sqlite3 "$DB_PATH" <<SQL
INSERT INTO zone (name, inherits, superuser)
VALUES ('$ZONE', NULLIF('$INHERITS',''), $SUPERUSER)
ON CONFLICT(name) DO UPDATE SET
  inherits  = NULLIF('$INHERITS',''),
  superuser = $SUPERUSER;
SQL
chown root:goto "$DB_PATH"
chmod 0640 "$DB_PATH"

echo "### Generating role keypairs ###"
ROLES=("$ZONE")
if [[ -n "$TECH_USERS" ]]; then
  IFS=',' read -ra TECH_ARR <<< "$TECH_USERS"
  for T in "${TECH_ARR[@]}"; do
    ROLES+=("$ZONE-$(echo "$T" | xargs)")
  done
fi

for ROLE in "${ROLES[@]}"; do
  if [[ ! -f "$KEYS_DIR/$ROLE" ]]; then
    ssh-keygen -t ed25519 -f "$KEYS_DIR/$ROLE" -C "goto-role-$ROLE" -N ""
    chown root:goto "$KEYS_DIR/$ROLE" "$KEYS_DIR/$ROLE.pub"
    chmod 0640 "$KEYS_DIR/$ROLE" "$KEYS_DIR/$ROLE.pub"
  fi
done

echo
echo "Zone '$ZONE' registered with roles: ${ROLES[*]}"
echo "Next: sign the new role keys on the CA VM:"
echo "  create-role-certs.sh -g <this-gatekeeper> -i <this-gatekeeper-ip>"
echo "Then deploy endpoints with:"
echo "  setup-endpoint.sh -n <name> -i <ip> -z $ZONE --enable"
