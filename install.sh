#!/usr/bin/env bash
# Ralph Wiggum - Global Installation Script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/bin"

echo "Ralph Wiggum Installer"
echo "======================"
echo ""

# Create install directory if needed
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Creating $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
fi

# Create wrapper script
echo "Installing ralph command..."

cat > "$INSTALL_DIR/ralph" << EOF
#!/usr/bin/env bash
# Ralph Wiggum wrapper script
exec "$SCRIPT_DIR/ralph.sh" "\$@"
EOF

chmod +x "$INSTALL_DIR/ralph"

# Create init wrapper
cat > "$INSTALL_DIR/ralph-init" << EOF
#!/usr/bin/env bash
# Ralph Wiggum init wrapper script
exec "$SCRIPT_DIR/init.sh" "\$@"
EOF

chmod +x "$INSTALL_DIR/ralph-init"

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
echo "  ralph plan               # Generate implementation plan"
echo "  ralph build              # Start building"
echo "  ralph-init my-project    # Initialize new project"
