#!/usr/bin/env bash
# Ralph Wiggum - Uninstallation Script

set -euo pipefail

INSTALL_DIR="${HOME}/bin"

echo "Ralph Wiggum Uninstaller"
echo "========================"
echo ""

# Remove wrapper scripts
if [[ -f "$INSTALL_DIR/ralph" ]]; then
    echo "Removing $INSTALL_DIR/ralph..."
    rm -f "$INSTALL_DIR/ralph"
fi

if [[ -f "$INSTALL_DIR/ralph-init" ]]; then
    echo "Removing $INSTALL_DIR/ralph-init..."
    rm -f "$INSTALL_DIR/ralph-init"
fi

echo ""
echo "Uninstallation complete!"
echo ""
echo "Note: This script does not remove the ralphwiggum directory."
echo "To fully remove, delete: $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
