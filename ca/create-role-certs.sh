#!/bin/bash
# create-role-certs.sh — sign the Gatekeeper's role keypairs
#
# Pulls every role public key from the Gatekeeper, signs each with the
# principal equal to its filename (zone or zone-techuser compound), restricts
# it to the Gatekeeper's source address, and pushes the certs back.
#
# Run on the CA VM (YubiKey inserted if FIDO2). Never copies the CA private
# key anywhere.
set -euo pipefail

GATEKEEPER=""
GATEKEEPER_IP=""
CA_KEY="/etc/ssh/ca/user_ca_key"
SERIAL_FILE="/var/lib/gatekeeper-ca/serial"
KEYS_DIR="/etc/goto/keys"
VALIDITY="+365d"
WORKDIR=""

usage() {
  cat <<EOF
Usage: ${0##*/} -g <gatekeeper-host> -i <gatekeeper-ip> [OPTIONS]

Options:
  -g, --gatekeeper <host>   Gatekeeper host (SSH as root) (required)
  -i, --ip <address>        Gatekeeper source IP embedded in each role cert
                            (endpoints reject the cert from any other IP) (required)
  -V, --validity <+365d>    Certificate validity in days (default: $VALIDITY)
      --ca-key <path>       CA private key / handle stub (default: $CA_KEY)
      --keys-dir <path>     Role keys directory on the Gatekeeper (default: $KEYS_DIR)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--gatekeeper) GATEKEEPER="$2"; shift 2 ;;
    -i|--ip)         GATEKEEPER_IP="$2"; shift 2 ;;
    -V|--validity)   VALIDITY="$2"; shift 2 ;;
    --ca-key)        CA_KEY="$2"; shift 2 ;;
    --keys-dir)      KEYS_DIR="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -z "$GATEKEEPER" ]]    && { usage; echo "Gatekeeper host is required (-g)" >&2; exit 1; }
[[ -z "$GATEKEEPER_IP" ]] && { usage; echo "Gatekeeper IP is required (-i)" >&2; exit 1; }

if [[ "$(id -u)" != "0" ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "### Pulling role public keys from $GATEKEEPER ###"
rsync -a "root@$GATEKEEPER:$KEYS_DIR/*.pub" "$WORKDIR/" \
  --exclude '*-cert.pub'

SERIAL=$(cat "$SERIAL_FILE")

shopt -s nullglob
for PUBKEY in "$WORKDIR"/*.pub; do
  ROLE=$(basename "$PUBKEY" .pub)
  SERIAL=$((SERIAL + 1))

  # -n "$ROLE"  : the compound principal (e.g. marketing-operator) matches the
  #               endpoint unix user of the same name; its principals file
  #               lists the zone and the tech-user names.
  # source-address : a role cert stolen off disk is useless from any other IP.
  ssh-keygen -s "$CA_KEY" \
    -I "goto-role-$ROLE" \
    -n "$ROLE" \
    -O "source-address=$GATEKEEPER_IP" \
    -V "$VALIDITY" \
    -z "$SERIAL" \
    "$PUBKEY"

  echo "Signed: $ROLE (serial $SERIAL)"
done

echo "$SERIAL" > "$SERIAL_FILE"

echo "### Pushing certificates back to $GATEKEEPER ###"
rsync -a "$WORKDIR"/*-cert.pub "root@$GATEKEEPER:$KEYS_DIR/"

ssh "root@$GATEKEEPER" bash -s <<EOF
set -euo pipefail
chown root:goto $KEYS_DIR/*-cert.pub
chmod 0640 $KEYS_DIR/*-cert.pub
EOF

echo "Done. Verify with: ssh root@$GATEKEEPER ssh-keygen -Lf $KEYS_DIR/<role>-cert.pub"
