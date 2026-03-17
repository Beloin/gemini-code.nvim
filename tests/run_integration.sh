#!/usr/bin/env bash
# tests/run_integration.sh — Launch the gemini-code.nvim integration demo
#
# Usage:
#   ./tests/run_integration.sh
#
# After Neovim opens:
#   :GeminiCode         → launch mock CLI (normal mode)
#   :GeminiCodeAutoEdit → launch mock CLI with --approval-mode=auto_edit
#
# The mock CLI connects to the plugin's HTTP server, shows an interactive
# menu, and lets you exercise openDiff, closeDiff, and context updates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_FILE="$SCRIPT_DIR/integration_init.lua"

if ! command -v nvim &>/dev/null; then
  echo "ERROR: nvim not found in PATH" >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 not found in PATH" >&2
  exit 1
fi

echo "Launching gemini-code.nvim integration demo…"
echo "  :GeminiCode         → open mock CLI"
echo "  :GeminiCodeAutoEdit → open mock CLI with --approval-mode=auto_edit"
echo ""

exec nvim -u "$INIT_FILE" "$@"
