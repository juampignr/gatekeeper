#!/bin/bash
# mintcert.sh — mint a user certificate and provision the user on the Gatekeeper
#
# The certificate carries one or two principals:
#   zone only          -> ssh-keygen -n "<zone>"
#   zone + tech user   -> ssh-keygen -n "<zone>,<techuser>"
#
# GoTo derives the endpoint unix user from them: <zone> or <zone>-<techuser>.
set -euo pipefail

VERBOSE=false
PRINCIPAL=""
TECHNICALUSER=""
EXPIRATION="+90d"
KEY="./id_ed25519.pub"
MINTUSER=""
DELETE=""
SOURCEADDRESS=""
GATEKEEPER=""
CA_KEY="/etc/ssh/ca/user_ca_key"
SERIAL_FILE="/var/lib/gatekeeper-ca/serial"

usage() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  -v, --verbose                       Enable verbose mode
  -u, --user <username>               Login name on the Gatekeeper (required)
  -p, --principal <zone>              RBAC zone (must exist in the zone table)
  -t, --technical-user <name>         Optional tech-user principal (e.g. observer|operator)
  -e, --expiration +[0-9]d            Validity in days, e.g. +30d, +180d (default: $EXPIRATION)
  -k, --key <./key.pub>               User's public key (default: $KEY)
  -s, --source-address <CIDR[,CIDR]>  Restrict cert to these source networks (optional)
  -g, --gatekeeper <host>             Gatekeeper host to provision the user on (required)
      --ca-key <path>                 CA private key / handle stub (default: $CA_KEY)
  -d, --delete <username>             Delete the user and revert provisioning
  -h, --help                          Show this help
EOF
}

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "This script must be run as root" >&2
    exit 1
  fi
}

setup() {
  require_root

  [[ -z "$MINTUSER" ]]   && { usage; echo "A valid username must be provided through -u|--user" >&2; exit 1; }
  [[ -z "$PRINCIPAL" ]]  && { usage; echo "A zone must be provided through -p|--principal" >&2; exit 1; }
  [[ -z "$GATEKEEPER" ]] && { usage; echo "The Gatekeeper host must be provided through -g|--gatekeeper" >&2; exit 1; }
  [[ -f "$KEY" ]]        || { echo "Public key not found: $KEY" >&2; exit 1; }

  local SERIAL
  SERIAL=$(cat "$SERIAL_FILE")
  SERIAL=$((SERIAL + 1))

  local PRINCIPALS="$PRINCIPAL"
  [[ -n "$TECHNICALUSER" ]] && PRINCIPALS="$PRINCIPAL,$TECHNICALUSER"

  local -a OPTS=()
  [[ -n "$SOURCEADDRESS" ]] && OPTS+=(-O "source-address=$SOURCEADDRESS")

  $VERBOSE && echo "ssh-keygen -s $CA_KEY -I $MINTUSER -z $SERIAL -n $PRINCIPALS -V $EXPIRATION ${OPTS[*]:-} $KEY"

  ssh-keygen -s "$CA_KEY" -I "$MINTUSER" -z "$SERIAL" -n "$PRINCIPALS" -V "$EXPIRATION" "${OPTS[@]}" "$KEY"

  echo "### Provisioning user on $GATEKEEPER ###"
  ssh "root@$GATEKEEPER" bash -s <<EOF
set -euo pipefail
id -u "$MINTUSER" &>/dev/null || useradd -s /bin/bash -m "$MINTUSER"
install -o root -g root -m 0644 /dev/null "/etc/ssh/principals/$MINTUSER"
echo "$PRINCIPAL" > "/etc/ssh/principals/$MINTUSER"
usermod -aG goto "$MINTUSER"
EOF

  echo "$SERIAL" > "$SERIAL_FILE"

  echo "Certificate created: ${KEY%.pub}-cert.pub (serial $SERIAL, principals: $PRINCIPALS)"
  echo "Send it back to the user to place in ~/.ssh next to their private key,"
  echo "keeping the <keyname>-cert.pub naming — ssh loads it automatically:"
  echo "  ssh $MINTUSER@$GATEKEEPER"
}

delete() {
  require_root

  [[ -z "$DELETE" ]]     && { usage; echo "A valid username must be provided through -d USER" >&2; exit 1; }
  [[ -z "$GATEKEEPER" ]] && { usage; echo "The Gatekeeper host must be provided through -g|--gatekeeper" >&2; exit 1; }

  ssh "root@$GATEKEEPER" bash -s <<EOF
set -euo pipefail
id -u "$DELETE" &>/dev/null && userdel -r "$DELETE"
rm -f "/etc/ssh/principals/$DELETE"
EOF
  echo "User $DELETE removed from $GATEKEEPER."
  echo "Reminder: the cert itself stays valid until expiry — add its serial to"
  echo "the endpoints' RevokedKeys file if immediate revocation is required."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)        VERBOSE=true; shift ;;
    -u|--user)           MINTUSER="$2"; shift 2 ;;
    -p|--principal)      PRINCIPAL="$2"; shift 2 ;;
    -t|--technical-user) TECHNICALUSER="$2"; shift 2 ;;
    -e|--expiration)     EXPIRATION="$2"; shift 2 ;;
    -k|--key)            KEY="$2"; shift 2 ;;
    -s|--source-address) SOURCEADDRESS="$2"; shift 2 ;;
    -g|--gatekeeper)     GATEKEEPER="$2"; shift 2 ;;
    --ca-key)            CA_KEY="$2"; shift 2 ;;
    -d|--delete)         DELETE="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    -*)                  echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)                   break ;;
  esac
done

[[ -z "$DELETE" ]] && setup || delete
