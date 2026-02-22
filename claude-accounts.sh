#!/usr/bin/env bash
# claude-accounts — manage multiple Claude Code CLI accounts
#
# Each account gets a fully isolated directory containing both credentials
# (~/.claude.json) and all Claude data (~/.claude/), so history, telemetry,
# usage stats, and session data never leak between accounts.
#
# Layout after first `save`:
#   ~/.claude-accounts/<name>/config.json  ← credentials (was ~/.claude.json)
#   ~/.claude-accounts/<name>/data/        ← all Claude data (was ~/.claude/)
#   ~/.claude.json  → symlink to active account's config.json
#   ~/.claude       → symlink to active account's data/
#
# Usage: claude-accounts <command> [name]

set -euo pipefail

PROFILES_DIR="${HOME}/.claude-accounts"
CLAUDE_JSON="${HOME}/.claude.json"
CLAUDE_DIR="${HOME}/.claude"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

mkdir -p "$PROFILES_DIR"

# ─── helpers ────────────────────────────────────────────────────────────────

account_dir()    { echo "${PROFILES_DIR}/${1}"; }
current_account() { [[ -f "${PROFILES_DIR}/.current" ]] && cat "${PROFILES_DIR}/.current" || echo ""; }
set_current()    { echo "$1" > "${PROFILES_DIR}/.current"; }
account_exists() { [[ -d "$(account_dir "$1")" && -f "$(account_dir "$1")/config.json" ]]; }

require_name() {
  if [[ -z "${1:-}" ]]; then
    echo -e "${RED}Error:${RESET} account name is required."
    echo "  Usage: $(basename "$0") $2 <name>"
    exit 1
  fi
  if [[ ! "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}Error:${RESET} account name must contain only letters, numbers, hyphens, and underscores."
    exit 1
  fi
}

# Point ~/.claude.json and ~/.claude symlinks to an account's directory
activate_symlinks() {
  local name="$1"
  local acct
  acct=$(account_dir "$name")

  # Remove old symlinks
  [[ -L "$CLAUDE_JSON" ]] && rm -f "$CLAUDE_JSON"
  [[ -L "$CLAUDE_DIR" ]]  && rm -f "$CLAUDE_DIR"

  ln -s "${acct}/config.json" "$CLAUDE_JSON"
  ln -s "${acct}/data"        "$CLAUDE_DIR"
  set_current "$name"
}

# Ensure symlinks are in place (save must be run first)
require_symlink_mode() {
  if [[ -e "$CLAUDE_JSON" && ! -L "$CLAUDE_JSON" ]] || \
     [[ -e "$CLAUDE_DIR"  && ! -L "$CLAUDE_DIR" ]]; then
    echo -e "${RED}Error:${RESET} Account switching is not set up yet."
    echo "  Run '$(basename "$0") save <name>' first to save your current login."
    exit 1
  fi
}

# Migrate old flat-file profiles (*.json) to new directory structure
maybe_migrate_old_format() {
  local migrated=false

  for f in "${PROFILES_DIR}"/*.json; do
    [[ -f "$f" ]] || continue
    local base
    base=$(basename "$f" .json)

    # Skip stats-cache files
    [[ "$base" == *.stats-cache ]] && continue

    # Skip if already migrated
    [[ -d "${PROFILES_DIR}/${base}" ]] && continue

    migrated=true
    echo -e "${CYAN}Migrating${RESET} old profile '${base}' to new format..."
    mkdir -p "${PROFILES_DIR}/${base}/data"
    mv "$f" "${PROFILES_DIR}/${base}/config.json"
    rm -f "${PROFILES_DIR}/${base}.stats-cache.json"
  done

  # Clean up any remaining stats-cache files
  for f in "${PROFILES_DIR}"/*.stats-cache.json; do
    [[ -f "$f" ]] && rm -f "$f"
  done

  if $migrated; then
    echo -e "${GREEN}Migration complete.${RESET}"
    echo ""
  fi
}

# ─── commands ───────────────────────────────────────────────────────────────

cmd_save() {
  require_name "${1:-}" "save"
  local name="$1"
  local acct
  acct=$(account_dir "$name")

  if account_exists "$name"; then
    echo -e "${YELLOW}Account '${name}' already exists.${RESET}"
    read -rp "Overwrite? [y/N] " confirm
    [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]] && { echo "Aborted."; exit 0; }
    rm -rf "$acct"
  fi

  mkdir -p "$acct"

  if [[ -L "$CLAUDE_JSON" ]] && [[ -L "$CLAUDE_DIR" ]]; then
    # Already in symlink mode — copy current data to new account
    cp -L "$CLAUDE_JSON" "${acct}/config.json"
    cp -a "$(readlink "$CLAUDE_DIR")" "${acct}/data"
    activate_symlinks "$name"
  else
    # First-time setup: move real files into account directory + create symlinks
    if [[ -f "$CLAUDE_JSON" ]]; then
      mv "$CLAUDE_JSON" "${acct}/config.json"
    else
      echo '{}' > "${acct}/config.json"
    fi

    if [[ -d "$CLAUDE_DIR" ]]; then
      mv "$CLAUDE_DIR" "${acct}/data"
    else
      mkdir -p "${acct}/data"
    fi

    activate_symlinks "$name"
  fi

  echo -e "${GREEN}Saved${RESET} current login as '${BOLD}${name}${RESET}'."
}

cmd_use() {
  require_name "${1:-}" "use"
  local name="$1"

  maybe_migrate_old_format

  if ! account_exists "$name"; then
    echo -e "${RED}Error:${RESET} No account named '${name}'."
    echo "  Run '$(basename "$0") list' to see available accounts."
    exit 1
  fi

  local current
  current=$(current_account)
  if [[ "$current" == "$name" ]]; then
    echo -e "Already on account '${BOLD}${name}${RESET}'."
    return
  fi

  require_symlink_mode
  activate_symlinks "$name"
  echo -e "${GREEN}Switched${RESET} to account '${BOLD}${name}${RESET}'."
}

cmd_add() {
  require_name "${1:-}" "add"
  local name="$1"

  if account_exists "$name"; then
    echo -e "${YELLOW}Account '${name}' already exists.${RESET}"
    read -rp "Overwrite? [y/N] " confirm
    [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]] && { echo "Aborted."; exit 0; }
    rm -rf "$(account_dir "$name")"
  fi

  require_symlink_mode

  local acct
  acct=$(account_dir "$name")
  mkdir -p "${acct}/data"
  echo '{}' > "${acct}/config.json"

  echo -e "${CYAN}Starting Claude Code for login.${RESET}"
  echo -e "Sign in with your desired account, then type ${BOLD}/exit${RESET} or press Ctrl+C.\n"
  read -rp "Press ENTER to continue..."

  # Remember current account in case login fails
  local prev
  prev=$(current_account)

  # Switch to the new empty account
  activate_symlinks "$name"

  claude || true

  # Check if login succeeded
  local login_ok=true
  if command -v jq &>/dev/null; then
    if ! jq -e '.oauthAccount' "${acct}/config.json" &>/dev/null; then
      login_ok=false
    fi
  elif [[ ! -s "${acct}/config.json" ]] || [[ "$(cat "${acct}/config.json")" == "{}" ]]; then
    login_ok=false
  fi

  if ! $login_ok; then
    echo -e "\n${YELLOW}Warning:${RESET} No credentials detected. Did you complete the login?"
    # Roll back to previous account
    if [[ -n "$prev" ]] && account_exists "$prev"; then
      activate_symlinks "$prev"
      echo -e "  Switched back to '${prev}'."
    fi
    rm -rf "$acct"
    return 1
  fi

  echo -e "\n${GREEN}Account '${BOLD}${name}${RESET}${GREEN}' saved.${RESET}"
}

cmd_list() {
  maybe_migrate_old_format

  local current
  current=$(current_account)
  local found=false

  for d in "${PROFILES_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    # Only count directories that have a config.json (valid accounts)
    [[ -f "${d}config.json" ]] || continue
    found=true
    break
  done

  if ! $found; then
    echo -e "${YELLOW}No saved accounts yet.${RESET}"
    echo "  Save your current login with:  $(basename "$0") save <name>"
    return
  fi

  echo -e "${BOLD}Saved accounts:${RESET}"
  for d in "${PROFILES_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}config.json" ]] || continue
    local name
    name=$(basename "$d")
    if [[ "$name" == "$current" ]]; then
      echo -e "  ${GREEN}* ${name}${RESET}  (active)"
    else
      echo -e "  ${CYAN}  ${name}${RESET}"
    fi
  done
}

cmd_remove() {
  require_name "${1:-}" "remove"
  local name="$1"

  if ! account_exists "$name"; then
    echo -e "${RED}Error:${RESET} No account named '${name}'."
    exit 1
  fi

  if [[ "$(current_account)" == "$name" ]]; then
    echo -e "${RED}Error:${RESET} Cannot remove the active account."
    echo "  Switch to another account first:  $(basename "$0") use <other>"
    exit 1
  fi

  read -rp "Remove account '${name}' and all its data? [y/N] " confirm
  [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]] && { echo "Aborted."; exit 0; }

  rm -rf "$(account_dir "$name")"
  echo -e "${GREEN}Removed${RESET} account '${name}'."
}

cmd_current() {
  local c
  c=$(current_account)
  if [[ -z "$c" ]]; then
    echo -e "${YELLOW}No active account.${RESET} Run '$(basename "$0") save <name>' to get started."
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
  echo -e "  ${CYAN}save <name>${RESET}    Save current login as <name> (run this first!)"
  echo -e "  ${CYAN}use  <name>${RESET}    Switch to a saved account"
  echo -e "  ${CYAN}add  <name>${RESET}    Log in with a new account and save it"
  echo -e "  ${CYAN}list${RESET}           Show all saved accounts"
  echo -e "  ${CYAN}current${RESET}        Show the active account"
  echo -e "  ${CYAN}remove <name>${RESET}  Delete a saved account and its data"
  echo ""
  echo -e "${BOLD}First-time setup:${RESET}"
  echo "  1. $(basename "$0") save work        # saves your current login"
  echo "  2. $(basename "$0") add personal     # log in with another account"
  echo "  3. $(basename "$0") use work         # switch between accounts"
  echo ""
  echo -e "${BOLD}How it works:${RESET}"
  echo "  Each account gets a fully isolated directory with its own credentials,"
  echo "  history, settings, and usage data. Switching accounts changes symlinks"
  echo "  so nothing is shared between accounts."
  echo ""
  echo -e "${BOLD}Layout:${RESET}"
  echo "  ~/.claude.json  → symlink → ~/.claude-accounts/<name>/config.json"
  echo "  ~/.claude/      → symlink → ~/.claude-accounts/<name>/data/"
  echo ""
  echo -e "${BOLD}Profiles stored in:${RESET} ~/.claude-accounts/"
}

# ─── dispatch ────────────────────────────────────────────────────────────────

case "${1:-help}" in
  save)    cmd_save    "${2:-}" ;;
  use)     cmd_use     "${2:-}" ;;
  add)     cmd_add     "${2:-}" ;;
  list)    cmd_list ;;
  remove)  cmd_remove  "${2:-}" ;;
  current) cmd_current ;;
  help|--help|-h) cmd_help ;;
  *)
    echo -e "${RED}Unknown command:${RESET} ${1}"
    echo "Run '$(basename "$0") help' for usage."
    exit 1
    ;;
esac
