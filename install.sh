#!/usr/bin/env bash
# Walph Riggum - Global Installation Script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/bin"

echo "Walph Riggum Installer"
echo "======================"
echo ""

# Create install directory if needed
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Creating $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
fi

# Create wrapper script
echo "Installing walph command..."

cat > "$INSTALL_DIR/walph" << EOF
#!/usr/bin/env bash
# Walph Riggum wrapper script
exec "$SCRIPT_DIR/walph.sh" "\$@"
EOF

chmod +x "$INSTALL_DIR/walph"

# Create init wrapper
cat > "$INSTALL_DIR/walph-init" << EOF
#!/usr/bin/env bash
# Walph Riggum init wrapper script
exec "$SCRIPT_DIR/init.sh" "\$@"
EOF

chmod +x "$INSTALL_DIR/walph-init"

echo ""
echo "Installation complete!"
echo ""

# Check if ~/bin is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo "NOTE: $INSTALL_DIR is not in your PATH."
    echo "Add this to your shell profile (.bashrc, .zshrc, etc.):"
    echo ""
    echo "  export PATH=\"\$HOME/bin:\$PATH\""
    echo ""
fi

echo "Usage:"
echo "  walph plan               # Generate implementation plan"
echo "  walph build              # Start building"
echo "  walph init my-project    # Initialize new project"
