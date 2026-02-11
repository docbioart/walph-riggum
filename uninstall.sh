#!/usr/bin/env bash
# Walph Riggum - Uninstallation Script

set -euo pipefail

INSTALL_DIR="${HOME}/bin"

echo "Walph Riggum Uninstaller"
echo "========================"
echo ""

# Remove wrapper scripts
if [[ -f "$INSTALL_DIR/walph" ]]; then
    echo "Removing $INSTALL_DIR/walph..."
    rm -f "$INSTALL_DIR/walph"
fi

if [[ -f "$INSTALL_DIR/walph-init" ]]; then
    echo "Removing $INSTALL_DIR/walph-init..."
    rm -f "$INSTALL_DIR/walph-init"
fi

if [[ -f "$INSTALL_DIR/jeeroy" ]]; then
    echo "Removing $INSTALL_DIR/jeeroy..."
    rm -f "$INSTALL_DIR/jeeroy"
fi

if [[ -f "$INSTALL_DIR/goodbunny" ]]; then
    echo "Removing $INSTALL_DIR/goodbunny..."
    rm -f "$INSTALL_DIR/goodbunny"
fi

echo ""
echo "Uninstallation complete!"
echo ""
echo "Note: This script does not remove the walphriggum directory."
echo "To fully remove, delete: $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
