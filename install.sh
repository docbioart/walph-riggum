#!/usr/bin/env bash
# Walph Riggum - Global Installation Script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/bin"

# Shared utilities: dependency + MCP checks, harness names/hints
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/harness.sh"

echo "Walph Riggum Installer"
echo "======================"
echo ""

# Check dependencies
echo "Checking dependencies..."
echo ""

# Required: at least one agent CLI (claude, codex, or opencode)
HARNESSES_FOUND=()
for harness in claude codex opencode; do
    if command -v "$harness" &> /dev/null; then
        echo "✓ $harness found ($(harness_display_name "$harness"))"
        HARNESSES_FOUND+=("$harness")
    else
        echo "  $harness not found (optional — one agent CLI is required)"
    fi
done
if [[ ${#HARNESSES_FOUND[@]} -eq 0 ]]; then
    echo ""
    echo "✗ No agent CLI found. Install at least one:"
    echo "  claude:   $(harness_install_hint claude)"
    echo "  codex:    $(harness_install_hint codex)"
    echo "  opencode: $(harness_install_hint opencode)"
    exit 1
fi

# Required: Git
if command -v git &> /dev/null; then
    echo "✓ Git found"
else
    echo "✗ Git not found (required)"
    exit 1
fi

# Required: jq (parses the agents' JSON output, tracks cost)
if command -v jq &> /dev/null; then
    echo "✓ jq found"
else
    echo "✗ jq not found (required)"
    echo "  Install: brew install jq   /   sudo apt-get install jq"
    exit 1
fi

# Optional: pandoc (for Jeeroy document conversion)
if command -v pandoc &> /dev/null; then
    echo "✓ pandoc found"
else
    echo "⚠ pandoc not found (optional - needed for docx/pdf conversion)"
    echo "  Install: brew install pandoc"
fi

# Optional: chrome-devtools MCP (for UI testing), checked per installed harness
for harness in "${HARNESSES_FOUND[@]}"; do
    if check_chrome_mcp "$harness"; then
        echo "✓ chrome-devtools MCP configured for $harness"
    else
        echo "⚠ chrome-devtools MCP not configured for $harness (recommended for UI testing)"
    fi
done

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
echo "  walph build --harness codex   # ...on Codex (or opencode); claude is the default"
echo "  walph review-plan --reviewer codex:gpt-6-astra   # Second model reviews the plan"
echo "  walph init my-project    # Initialize new project"
echo "  goodbunny audit          # Audit code quality"
echo "  goodbunny fix            # Fix code quality issues"
echo "  goodbunny analyze        # Document codebase"
echo "  jeeroy ./docs            # Convert docs to Walph specs"
echo "  jeeroy ./docs --lfg      # Convert docs and auto-build"
