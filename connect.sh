#!/bin/bash
set -e

# Configuration - UPDATE THIS
SERVER="https://app.claudetorio.ai"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}"
echo "============================================================="
echo "          CLAUDETORIO - Connect to Arena"
echo "============================================================="
echo -e "${NC}"

# Check dependencies
command -v curl >/dev/null 2>&1 || { echo -e "${RED}Error: curl is required${NC}"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo -e "${RED}Error: jq is required. Install with: sudo apt install jq${NC}"; exit 1; }

# Check for FLE (factorio-learning-environment)
FLE_CMD=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_fle() {
    # Always use our custom wrapper for remote server support
    if [ -f "$SCRIPT_DIR/.venv/bin/fle" ]; then
        FLE_CMD="$SCRIPT_DIR/.venv/bin/fle"
        return 0
    fi
    return 1
}

install_fle() {
    echo -e "${YELLOW}Setting up FLE (factorio-learning-environment)...${NC}"

    # Always create our custom wrapper that supports remote connections
    mkdir -p "$SCRIPT_DIR/.venv/bin"

    # Create the wrapper script
    cat > "$SCRIPT_DIR/.venv/bin/fle" << 'FLEWRAPPER'
#!/usr/bin/env bash
# Custom FLE wrapper with remote server support

set -e

FLE_VENV="$HOME/.fle-venv"

# Read server config from environment
FLE_SERVER_HOST="${FLE_SERVER_HOST:-127.0.0.1}"
FLE_RCON_PORT="${FLE_RCON_PORT:-27000}"
FLE_RCON_PASSWORD="${FLE_RCON_PASSWORD:-factorio}"

# Create venv if it doesn't exist
if [ ! -d "$FLE_VENV" ] || [ ! -f "$FLE_VENV/bin/python3" ]; then
    echo "Installing FLE dependencies (first run only)..." >&2

    # Detect NixOS
    if [ -f /etc/NIXOS ] || [ -d /nix/store ]; then
        nix-shell -p python312 --run "
            python3 -m venv $FLE_VENV
            $FLE_VENV/bin/pip install --quiet 'factorio-learning-environment[mcp,eval]' 'fastmcp<2.0' openai anthropic aiohttp
        "
    else
        python3 -m venv "$FLE_VENV"
        "$FLE_VENV/bin/pip" install --quiet 'factorio-learning-environment[mcp,eval]' 'fastmcp<2.0' openai anthropic aiohttp
    fi
fi

# Handle NixOS library path
if [ -f /etc/NIXOS ] || [ -d /nix/store ]; then
    LIBCXX=$(nix-build '<nixpkgs>' -A stdenv.cc.cc.lib --no-out-link 2>/dev/null)/lib
    export LD_LIBRARY_PATH="$LIBCXX:$LD_LIBRARY_PATH"
fi

# Create a Python wrapper that patches FLE for remote connections BEFORE import
PATCH_SCRIPT=$(cat << PYTHONPATCH
import os
import sys

# Get config from environment
server_host = os.environ.get('FLE_SERVER_HOST', '127.0.0.1')
rcon_port = int(os.environ.get('FLE_RCON_PORT', '27000'))
rcon_password = os.environ.get('FLE_RCON_PASSWORD', 'factorio')

# Create a mock module for cluster_ips that returns our config
class MockClusterIPs:
    @staticmethod
    def get_local_container_ips():
        return [server_host], [rcon_port + 17197], [rcon_port]

# Install our mock before any FLE imports
sys.modules['fle.commons.cluster_ips'] = MockClusterIPs()

# Also create the run_envs mock with our values
class MockRunEnvs:
    START_RCON_PORT = rcon_port
    START_GAME_PORT = rcon_port + 17197
    RCON_PASSWORD = rcon_password

    @staticmethod
    def resolve_state_dir():
        from pathlib import Path
        from platformdirs import user_state_dir
        return Path(user_state_dir("fle"))

sys.modules['fle.cluster.run_envs'] = MockRunEnvs()

# Now run the actual FLE command
if len(sys.argv) > 1 and sys.argv[1] == 'mcp':
    from fle.env.protocols._mcp import mcp
    mcp.run(transport="stdio")
else:
    from fle.run import main
    main()
PYTHONPATCH
)

# Run with the patch
exec "$FLE_VENV/bin/python3" -c "$PATCH_SCRIPT" "$@"
FLEWRAPPER

    chmod +x "$SCRIPT_DIR/.venv/bin/fle"
    FLE_CMD="$SCRIPT_DIR/.venv/bin/fle"
    echo -e "${GREEN}FLE wrapper created${NC}"
    return 0
}

if ! check_fle; then
    install_fle || exit 1
fi

# Check for existing session
if [ -f .claudetorio_session ]; then
    EXISTING_SESSION=$(cat .claudetorio_session)
    echo -e "${YELLOW}Found existing session: ${EXISTING_SESSION}${NC}"
    echo ""
    read -p "Reconnect to existing session? (y/n): " RECONNECT
    if [ "$RECONNECT" = "y" ]; then
        SESSION_INFO=$(curl -s "$SERVER/api/session/$EXISTING_SESSION" 2>/dev/null || echo '{}')
        if echo "$SESSION_INFO" | jq -e '.session_id' > /dev/null 2>&1; then
            STATUS=$(echo "$SESSION_INFO" | jq -r '.status')
            if [ "$STATUS" = "active" ]; then
                echo -e "${GREEN}Session is still active!${NC}"
                SLOT=$(echo "$SESSION_INFO" | jq -r '.slot')
                UDP_PORT=$((34197 + SLOT))
                echo ""
                echo -e "${GREEN}============================================${NC}"
                echo -e "  Session ID:  ${EXISTING_SESSION}"
                echo -e "  Spectate:    ${SERVER#https://}:${UDP_PORT}"
                echo -e "${GREEN}============================================${NC}"
                exit 0
            fi
        fi
        echo -e "${YELLOW}Previous session has ended. Starting fresh.${NC}"
        rm .claudetorio_session
    else
        rm .claudetorio_session
    fi
fi

# Get username
echo ""
read -p "Enter your username (lowercase, 2-20 chars): " USERNAME
USERNAME=$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')

if [ ${#USERNAME} -lt 2 ] || [ ${#USERNAME} -gt 20 ]; then
    echo -e "${RED}Error: Username must be 2-20 characters (letters, numbers, underscore)${NC}"
    exit 1
fi

# Check for existing saves
echo ""
echo "Checking for existing saves..."
SAVES=$(curl -s "$SERVER/api/users/$USERNAME/saves" 2>/dev/null || echo '[]')

# Check if response is actually an array (not an error object)
SAVE_NAME=""
if echo "$SAVES" | jq -e 'type == "array"' > /dev/null 2>&1; then
    SAVE_COUNT=$(echo "$SAVES" | jq 'length')
    if [ "$SAVE_COUNT" -gt "0" ]; then
        echo -e "${GREEN}Found ${SAVE_COUNT} save(s):${NC}"
        echo "$SAVES" | jq -r '.[] | "  -> \(.save_name) (score: \(.score_at_save // 0 | floor), \(.playtime_hours // 0 | floor)h played)"'
        echo ""
        read -p "Enter save name to resume (or press Enter for new game): " SAVE_NAME
    else
        echo "No existing saves found. Starting fresh!"
    fi
else
    echo "No existing saves found. Starting fresh!"
fi

# Claim session
echo ""
echo "Claiming session..."

if [ -n "$SAVE_NAME" ]; then
    PAYLOAD="{\"username\": \"$USERNAME\", \"save_name\": \"$SAVE_NAME\"}"
else
    PAYLOAD="{\"username\": \"$USERNAME\"}"
fi

RESPONSE=$(curl -s -X POST "$SERVER/api/session/claim" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

# Check for errors
if echo "$RESPONSE" | jq -e '.detail' > /dev/null 2>&1; then
    ERROR=$(echo "$RESPONSE" | jq -r '.detail')
    echo -e "${RED}Error: ${ERROR}${NC}"
    exit 1
fi

# Parse response
SESSION_ID=$(echo "$RESPONSE" | jq -r '.session_id')
SLOT=$(echo "$RESPONSE" | jq -r '.slot')
UDP_PORT=$(echo "$RESPONSE" | jq -r '.udp_port')
SPECTATE_ADDR=$(echo "$RESPONSE" | jq -r '.spectate_address')
EXPIRES=$(echo "$RESPONSE" | jq -r '.expires_at')
MCP_CONFIG=$(echo "$RESPONSE" | jq '.mcp_config')

# Save session info
echo "$SESSION_ID" > .claudetorio_session

# Generate Claude Code MCP config with correct FLE path
mkdir -p .claude

# Update the MCP config to use our FLE path if it's not the default 'fle'
if [ "$FLE_CMD" != "fle" ]; then
    MCP_CONFIG=$(echo "$MCP_CONFIG" | jq --arg cmd "$FLE_CMD" '.mcpServers.factorio.command = $cmd')
fi

echo "$MCP_CONFIG" > .claude/settings.json

# Also create a standalone MCP config file
echo "$MCP_CONFIG" > mcp-config.json

echo ""
echo -e "${GREEN}=============================================================${NC}"
echo -e "${GREEN}              Session Claimed Successfully!                  ${NC}"
echo -e "${GREEN}=============================================================${NC}"
echo ""
echo -e "  ${BLUE}Session ID:${NC}  $SESSION_ID"
echo -e "  ${BLUE}Username:${NC}    $USERNAME"
echo -e "  ${BLUE}Slot:${NC}        $SLOT"
echo -e "  ${BLUE}Expires:${NC}     $EXPIRES"
echo ""
echo -e "${YELLOW}=============================================================${NC}"
echo -e "${YELLOW}  TO SPECTATE YOUR GAME:${NC}"
echo -e "     1. Open Factorio"
echo -e "     2. Multiplayer -> Connect to address"
echo -e "     3. Enter: ${GREEN}${SPECTATE_ADDR}${NC}"
echo -e "${YELLOW}=============================================================${NC}"
echo ""
echo -e "${YELLOW}  LEADERBOARD: ${BLUE}${SERVER}${NC}"
echo -e "${YELLOW}  TO SAVE & DISCONNECT: ${BLUE}./disconnect.sh${NC}"
echo ""

# Auto-launch Claude Code with the MCP config
echo -e "${GREEN}Launching Claude Code...${NC}"
echo ""
exec claude --mcp-config mcp-config.json
