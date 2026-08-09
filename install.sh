#!/usr/bin/env bash
#
# SLBCK - SaguaroLocalBackup installer
# Usage: sudo ./install.sh
#
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./install.sh" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="/usr/local/bin/slbck"
CONFIG_DIR="/etc/slbck"

install -m 755 "$SRC_DIR/slbck.sh" "$BIN"
ln -sf "$BIN" /usr/local/bin/slbck-setup
mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/slbck.conf" ]; then
    install -m 600 "$SRC_DIR/slbck.conf.example" "$CONFIG_DIR/slbck.conf"
    echo "Default config installed to $CONFIG_DIR/slbck.conf"
else
    echo "Existing config kept: $CONFIG_DIR/slbck.conf"
fi

mkdir -p /var/backups/slbck
chmod 700 /var/backups/slbck
touch /var/log/slbck.log
chmod 640 /var/log/slbck.log

echo
echo "SLBCK installed: $BIN (menu: slbck-setup)"
echo "Next step:  slbck-setup"
