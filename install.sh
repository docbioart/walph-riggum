#!/usr/bin/env bash
# Walph Riggum - Global Installation Script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/bin"

# Source shared utilities for check_chrome_mcp
source "$SCRIPT_DIR/lib/utils.sh"

echo "Walph Riggum Installer"
echo "======================"
echo ""

# Check dependencies
echo "Checking dependencies..."
echo ""

# Required: Claude CLI
if command -v claude &> /dev/null; then
    echo "✓ Claude CLI found"
else
    echo "✗ Claude CLI not found (required)"
    echo "  Install from: https://github.com/anthropics/claude-code"
    exit 1
fi

# Required: Git
if command -v git &> /dev/null; then
    echo "✓ Git found"
else
    echo "✗ Git not found (required)"
    exit 1
fi

# Optional: pandoc (for Jeeroy document conversion)
if command -v pandoc &> /dev/null; then
    echo "✓ pandoc found"
else
    echo "⚠ pandoc not found (optional - needed for docx/pdf conversion)"
    echo "  Install: brew install pandoc"
fi

# Optional: chrome-devtools MCP (for UI testing)
if check_chrome_mcp; then
    echo "✓ chrome-devtools MCP found"
else
    echo "⚠ chrome-devtools MCP not found (recommended for UI testing)"
    echo "  Without it, UI testing must be done manually."
    echo "  See: https://github.com/anthropics/anthropic-quickstarts"
fi

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

# Create init wrapper (calls walph init instead of init.sh)
cat > "$INSTALL_DIR/walph-init" << EOF
#!/usr/bin/env bash
# Walph Riggum init wrapper script
exec "$SCRIPT_DIR/walph.sh" init "\$@"
EOF

chmod +x "$INSTALL_DIR/walph-init"

# Create jeeroy wrapper
echo "Installing jeeroy command..."

cat > "$INSTALL_DIR/jeeroy" << EOF
#!/usr/bin/env bash
# Jeeroy Lenkins wrapper script
exec "$SCRIPT_DIR/jeeroy.sh" "\$@"
EOF

chmod +x "$INSTALL_DIR/jeeroy"

# Create goodbunny wrapper
echo "Installing goodbunny command..."

cat > "$INSTALL_DIR/goodbunny" << EOF
#!/usr/bin/env bash
# Good Bunny wrapper script
exec "$SCRIPT_DIR/goodbunny.sh" "\$@"
EOF

chmod +x "$INSTALL_DIR/goodbunny"

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
echo "  goodbunny audit          # Audit code quality"
echo "  goodbunny fix            # Fix code quality issues"
echo "  jeeroy ./docs            # Convert docs to Walph specs"
echo "  jeeroy ./docs --lfg      # Convert docs and auto-build"
