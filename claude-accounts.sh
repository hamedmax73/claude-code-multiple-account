#!/usr/bin/env bash
# claude-accounts — manage multiple Claude Code CLI accounts
# Usage: claude-accounts <command> [name]

set -euo pipefail

PROFILES_DIR="${HOME}/.claude-accounts"
CLAUDE_JSON="${HOME}/.claude.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

mkdir -p "$PROFILES_DIR"

# ─── helpers ────────────────────────────────────────────────────────────────

profile_path() { echo "${PROFILES_DIR}/${1}.json"; }

current_account() {
  local marker="${PROFILES_DIR}/.current"
  [[ -f "$marker" ]] && cat "$marker" || echo ""
}

set_current() {
  echo "$1" > "${PROFILES_DIR}/.current"
}

require_name() {
  if [[ -z "${1:-}" ]]; then
    echo -e "${RED}Error:${RESET} account name is required."
    echo "  Usage: $(basename "$0") $2 <name>"
    exit 1
  fi
}

require_claude_json() {
  if [[ ! -f "$CLAUDE_JSON" ]]; then
    echo -e "${RED}Error:${RESET} ~/.claude.json not found. Run 'claude' and log in first."
    exit 1
  fi
}

# ─── commands ───────────────────────────────────────────────────────────────

cmd_list() {
  local current
  current=$(current_account)

  profiles=("${PROFILES_DIR}"/*.json)

  if [[ ! -e "${profiles[0]}" ]]; then
    echo -e "${YELLOW}No saved accounts yet.${RESET}"
    echo "  Save your current login with:  $(basename "$0") save <name>"
    return
  fi

  echo -e "${BOLD}Saved accounts:${RESET}"
  for p in "${PROFILES_DIR}"/*.json; do
    local name
    name=$(basename "$p" .json)
    if [[ "$name" == "$current" ]]; then
      echo -e "  ${GREEN}* ${name}${RESET}  (active)"
    else
      echo -e "  ${CYAN}  ${name}${RESET}"
    fi
  done
}

cmd_save() {
  require_name "${1:-}" "save"
  require_claude_json
  local name="$1"
  local dest
  dest=$(profile_path "$name")

  cp "$CLAUDE_JSON" "$dest"
  set_current "$name"
  echo -e "${GREEN}Saved${RESET} current credentials as '${BOLD}${name}${RESET}'."
}

cmd_use() {
  require_name "${1:-}" "use"
  local name="$1"
  local src
  src=$(profile_path "$name")

  if [[ ! -f "$src" ]]; then
    echo -e "${RED}Error:${RESET} No account named '${name}' found."
    echo "  Run '$(basename "$0") list' to see available accounts."
    exit 1
  fi

  # Back up current credentials before switching
  if [[ -f "$CLAUDE_JSON" ]]; then
    cp "$CLAUDE_JSON" "${CLAUDE_JSON}.backup"
  fi

  cp "$src" "$CLAUDE_JSON"
  set_current "$name"
  echo -e "${GREEN}Switched${RESET} to account '${BOLD}${name}${RESET}'."
  echo -e "  Previous credentials backed up to ${YELLOW}~/.claude.json.backup${RESET}"
}

cmd_add() {
  require_name "${1:-}" "add"
  local name="$1"
  local dest
  dest=$(profile_path "$name")

  if [[ -f "$dest" ]]; then
    echo -e "${YELLOW}Account '${name}' already exists.${RESET}"
    read -rp "Overwrite? [y/N] " confirm
    [[ "${confirm,,}" != "y" ]] && { echo "Aborted."; exit 0; }
  fi

  echo -e "${CYAN}Step 1:${RESET} Starting Claude Code for login. Sign in with your desired account."
  echo -e "        After login, type ${BOLD}/exit${RESET} or press Ctrl+C to return here.\n"
  read -rp "Press ENTER to open Claude Code login..."

  # Clear credentials so Claude forces a fresh login
  if [[ -f "$CLAUDE_JSON" ]]; then
    cp "$CLAUDE_JSON" "${CLAUDE_JSON}.backup"
    # Remove only auth-related keys (oauthAccount, apiKey) while keeping other settings
    if command -v jq &>/dev/null; then
      jq 'del(.oauthAccount, .primaryApiKey, .cachedApiKey)' "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
    else
      # fallback: wipe the file entirely
      echo '{}' > "$CLAUDE_JSON"
    fi
  fi

  claude || true  # run claude; user logs in and exits

  if [[ ! -f "$CLAUDE_JSON" ]]; then
    echo -e "${RED}Error:${RESET} No credentials saved. Did you complete login?"
    exit 1
  fi

  cp "$CLAUDE_JSON" "$dest"
  set_current "$name"
  echo -e "\n${GREEN}Account '${BOLD}${name}${RESET}${GREEN}' saved successfully.${RESET}"
}

cmd_remove() {
  require_name "${1:-}" "remove"
  local name="$1"
  local target
  target=$(profile_path "$name")

  if [[ ! -f "$target" ]]; then
    echo -e "${RED}Error:${RESET} No account named '${name}' found."
    exit 1
  fi

  read -rp "Remove account '${name}'? [y/N] " confirm
  [[ "${confirm,,}" != "y" ]] && { echo "Aborted."; exit 0; }

  rm "$target"

  # Clear .current marker if removed account was active
  if [[ "$(current_account)" == "$name" ]]; then
    rm -f "${PROFILES_DIR}/.current"
  fi

  echo -e "${GREEN}Removed${RESET} account '${name}'."
}

cmd_current() {
  local c
  c=$(current_account)
  if [[ -z "$c" ]]; then
    echo -e "${YELLOW}No active account tracked.${RESET} Use 'save <name>' to tag the current login."
  else
    echo -e "Active account: ${GREEN}${BOLD}${c}${RESET}"
  fi
}

cmd_help() {
  echo -e "${BOLD}claude-accounts${RESET} — manage multiple Claude Code CLI accounts"
  echo ""
  echo -e "${BOLD}Usage:${RESET}"
  echo "  $(basename "$0") <command> [name]"
  echo ""
  echo -e "${BOLD}Commands:${RESET}"
  echo -e "  ${CYAN}list${RESET}           Show all saved accounts"
  echo -e "  ${CYAN}save <name>${RESET}    Save current ~/.claude.json credentials as <name>"
  echo -e "  ${CYAN}use  <name>${RESET}    Switch to a saved account"
  echo -e "  ${CYAN}add  <name>${RESET}    Open Claude for fresh login and save as <name>"
  echo -e "  ${CYAN}remove <name>${RESET}  Delete a saved account"
  echo -e "  ${CYAN}current${RESET}        Show the active account name"
  echo ""
  echo -e "${BOLD}Profiles stored in:${RESET} ~/.claude-accounts/"
}

# ─── dispatch ────────────────────────────────────────────────────────────────

case "${1:-help}" in
  list)    cmd_list ;;
  save)    cmd_save    "${2:-}" ;;
  use)     cmd_use     "${2:-}" ;;
  add)     cmd_add     "${2:-}" ;;
  remove)  cmd_remove  "${2:-}" ;;
  current) cmd_current ;;
  help|--help|-h) cmd_help ;;
  *)
    echo -e "${RED}Unknown command:${RESET} ${1}"
    echo "Run '$(basename "$0") help' for usage."
    exit 1
    ;;
esac
