#!/bin/bash
# setup-ca.sh — Certificate Authority VM setup for Gatekeeper
#
# Generates the user CA key (FIDO2/YubiKey-backed by default, plain ed25519
# with --plain), initializes the serial counter, and installs the minting
# scripts. Run once on a dedicated, minimal VM.
set -euo pipefail

CA_DIR="/etc/ssh/ca"
CA_KEY="$CA_DIR/user_ca_key"
SERIAL_DIR="/var/lib/gatekeeper-ca"
APPLICATION="ssh:gatekeeper-ca"
COMMENT="gatekeeper-user-ca"
PLAIN=false

usage() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  --plain               Generate a plain ed25519 CA key instead of FIDO2
                        (no hardware token required — weaker, but portable)
  --application <name>  FIDO2 application namespace (default: $APPLICATION)
  --comment <text>      CA key comment (default: $COMMENT)
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plain)        PLAIN=true; shift ;;
    --application)  APPLICATION="$2"; shift 2 ;;
    --comment)      COMMENT="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ $(id -u) -ne 0 ]]; then
  echo "This script must be run as root!" >&2
  exit 1
fi

OS_ID=""
[[ -f /etc/os-release ]] && OS_ID=$(. /etc/os-release && echo "$ID")

echo "### Installing dependencies ###"
case "$OS_ID" in
  opensuse*|sles)
    zypper install -y openssh rsync
    $PLAIN || zypper install -y yubikey-manager
    ;;
  *)
    apt update
    apt install -y openssh-client rsync
    $PLAIN || apt install -y yubikey-manager
    ;;
esac

if ! $PLAIN; then
  echo "### YubiKey check ###"
  ykman info || {
    echo "No YubiKey detected. Insert the token or re-run with --plain." >&2
    exit 1
  }
fi

if [[ -f "$CA_KEY" ]]; then
  echo "CA key already exists at $CA_KEY — refusing to overwrite." >&2
  exit 1
fi

mkdir -p "$CA_DIR"
chmod 0700 "$CA_DIR"

echo "### Generating CA key ###"
if $PLAIN; then
  ssh-keygen -t ed25519 -f "$CA_KEY" -C "$COMMENT"
else
  # -O resident        : key handle lives on the token (survives re-plugging)
  # -O verify-required : PIN required on every signing operation
  # The on-disk file is only a handle stub — no private key material.
  ssh-keygen -t ed25519-sk \
    -O resident \
    -O "application=$APPLICATION" \
    -O verify-required \
    -f "$CA_KEY" \
    -C "$COMMENT"
fi

chmod 0600 "$CA_KEY"
chown root:root "$CA_KEY" "$CA_KEY.pub"

echo "### Initializing serial counter ###"
mkdir -p "$SERIAL_DIR"
[[ -f "$SERIAL_DIR/serial" ]] || echo 1000 > "$SERIAL_DIR/serial"
chmod 0600 "$SERIAL_DIR/serial"

echo "### Installing minting scripts ###"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -o root -g root -m 0750 "$SCRIPT_DIR/mintcert.sh" /usr/local/sbin/mintcert.sh
install -o root -g root -m 0750 "$SCRIPT_DIR/create-role-certs.sh" /usr/local/sbin/create-role-certs.sh

echo
echo "Done. CA public key:"
echo "----------------------------------------------------------------------"
cat "$CA_KEY.pub"
echo "----------------------------------------------------------------------"
echo "Distribute $CA_KEY.pub to the Gatekeeper and every endpoint as"
echo "/etc/ssh/user_ca_key.pub (the setup scripts install it for you)."
