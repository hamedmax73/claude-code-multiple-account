#!/usr/bin/env bash
# claude-accounts — manage multiple Claude Code CLI accounts
#
# Each account gets a fully isolated directory containing both credentials
# and all Claude data, so history, telemetry, usage stats, and session data
# never leak between accounts.
#
# Layout:
#   ~/.claude-accounts/<name>/data/              ← all account data
#   ~/.claude-accounts/<name>/data/.claude.json  ← credentials
#
# Usage via CLAUDE_CONFIG_DIR (multiple accounts at the same time):
#   CLAUDE_CONFIG_DIR=~/.claude-accounts/<name>/data claude
#
# Bare `claude` (no env var) still works using ~/.claude.json + ~/.claude/
# as an unmanaged fallback.
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
account_data()   { echo "${PROFILES_DIR}/${1}/data"; }
account_config() { echo "${PROFILES_DIR}/${1}/data/.claude.json"; }
account_exists() { [[ -d "$(account_data "$1")" && -f "$(account_config "$1")" ]]; }

# Ensure the account's ide/ directory is a symlink to the global ~/.claude/ide/
# so that IDE integrations (JetBrains, VS Code) work with CLAUDE_CONFIG_DIR.
# The IDE plugin writes lock files to ~/.claude/ide/ regardless of CLAUDE_CONFIG_DIR,
# so we need the account's data dir to point there.
ensure_ide_symlink() {
  local data="$1"
  local global_ide="${CLAUDE_DIR}/ide"

  mkdir -p "$global_ide"

  # Already a correct symlink — nothing to do
  if [[ -L "${data}/ide" ]]; then
    local current_target
    current_target=$(readlink "${data}/ide")
    [[ "$current_target" == "$global_ide" ]] && return
    rm -f "${data}/ide"
  fi

  # Real directory with stale lock files — remove it
  if [[ -d "${data}/ide" ]]; then
    rm -rf "${data}/ide"
  fi

  ln -s "$global_ide" "${data}/ide"
}

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

# Migrate old formats to current directory structure
maybe_migrate() {
  local migrated=false

  # Phase 0: Restore symlinks left by previous versions
  # If ~/.claude.json or ~/.claude are symlinks (from the old global-switch mode),
  # replace them with real copies so bare `claude` keeps working.
  if [[ -L "$CLAUDE_JSON" ]]; then
    local target
    target=$(readlink "$CLAUDE_JSON")
    if [[ -f "$target" ]]; then
      cp "$target" "${CLAUDE_JSON}.tmp"
      rm -f "$CLAUDE_JSON"
      mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
      migrated=true
      echo -e "${CYAN}Restored${RESET} ~/.claude.json from symlink."
    else
      rm -f "$CLAUDE_JSON"
      migrated=true
      echo -e "${CYAN}Removed${RESET} dangling symlink ~/.claude.json."
    fi
  fi
  if [[ -L "$CLAUDE_DIR" ]]; then
    local target
    target=$(readlink "$CLAUDE_DIR")
    if [[ -d "$target" ]]; then
      cp -a "$target" "${CLAUDE_DIR}.tmp"
      rm -f "$CLAUDE_DIR"
      mv "${CLAUDE_DIR}.tmp" "$CLAUDE_DIR"
      migrated=true
      echo -e "${CYAN}Restored${RESET} ~/.claude/ from symlink."
    else
      rm -f "$CLAUDE_DIR"
      migrated=true
      echo -e "${CYAN}Removed${RESET} dangling symlink ~/.claude/."
    fi
  fi

  # Clean up old .current marker file
  if [[ -f "${PROFILES_DIR}/.current" ]]; then
    rm -f "${PROFILES_DIR}/.current"
  fi

  # Phase 1: Migrate flat-file profiles (v1: *.json files in profiles dir)
  for f in "${PROFILES_DIR}"/*.json; do
    [[ -f "$f" ]] || continue
    local base
    base=$(basename "$f" .json)
    [[ "$base" == *.stats-cache ]] && continue
    [[ -d "${PROFILES_DIR}/${base}" ]] && continue

    migrated=true
    echo -e "${CYAN}Migrating${RESET} old profile '${base}' to new format..."
    mkdir -p "${PROFILES_DIR}/${base}/data"
    mv "$f" "${PROFILES_DIR}/${base}/data/.claude.json"
    rm -f "${PROFILES_DIR}/${base}.stats-cache.json"
  done

  # Clean up remaining stats-cache files
  for f in "${PROFILES_DIR}"/*.stats-cache.json; do
    [[ -f "$f" ]] && rm -f "$f"
  done

  # Phase 2: Migrate v2 format (config.json outside data/) to v3 (inside data/)
  for d in "${PROFILES_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    if [[ -f "${d}config.json" && ! -f "${d}data/.claude.json" ]]; then
      migrated=true
      local n
      n=$(basename "$d")
      echo -e "${CYAN}Migrating${RESET} account '${n}' config into data directory..."
      mkdir -p "${d}data"
      mv "${d}config.json" "${d}data/.claude.json"
    fi
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

  mkdir -p "${acct}/data"

  # If ~/.claude.json or ~/.claude are symlinks (old version), resolve them first
  local src_json="$CLAUDE_JSON"
  local src_dir="$CLAUDE_DIR"
  [[ -L "$src_json" ]] && src_json=$(readlink "$src_json")
  [[ -L "$src_dir" ]]  && src_dir=$(readlink "$src_dir")

  # Copy data directory contents (skip ide/ — it will be symlinked to the global one)
  if [[ -d "$src_dir" ]]; then
    cp -a "${src_dir}/." "${acct}/data/"
    rm -rf "${acct}/data/ide"
  fi

  # Copy credentials
  if [[ -f "$src_json" ]]; then
    cp "$src_json" "${acct}/data/.claude.json"
  else
    echo '{}' > "${acct}/data/.claude.json"
  fi

  echo -e "${GREEN}Saved${RESET} current login as '${BOLD}${name}${RESET}'."
  echo -e "  Use it with:  $(basename "$0") run ${name}"
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

  local acct
  acct=$(account_dir "$name")
  mkdir -p "${acct}/data"
  echo '{}' > "${acct}/data/.claude.json"

  echo -e "${CYAN}Starting Claude Code for login.${RESET}"
  echo -e "Sign in with your desired account, then type ${BOLD}/exit${RESET} or press Ctrl+C.\n"
  read -rp "Press ENTER to continue..."

  # Launch claude with the new account's config dir
  CLAUDE_CONFIG_DIR="${acct}/data" claude || true

  # Check if login succeeded
  local login_ok=true
  if command -v jq &>/dev/null; then
    if ! jq -e '.oauthAccount' "$(account_config "$name")" &>/dev/null; then
      login_ok=false
    fi
  elif [[ ! -s "$(account_config "$name")" ]] || [[ "$(cat "$(account_config "$name")")" == "{}" ]]; then
    login_ok=false
  fi

  if ! $login_ok; then
    echo -e "\n${YELLOW}Warning:${RESET} No credentials detected. Did you complete the login?"
    rm -rf "$acct"
    return 1
  fi

  echo -e "\n${GREEN}Account '${BOLD}${name}${RESET}${GREEN}' saved.${RESET}"
  echo -e "  Use it with:  $(basename "$0") run ${name}"
}

cmd_env() {
  require_name "${1:-}" "env"
  local name="$1"

  maybe_migrate

  if ! account_exists "$name"; then
    echo -e "${RED}Error:${RESET} No account named '${name}'." >&2
    exit 1
  fi

  local data
  data=$(account_data "$name")

  # Ensure IDE integration works with CLAUDE_CONFIG_DIR
  ensure_ide_symlink "$data"

  # Output export statement for eval
  echo "export CLAUDE_CONFIG_DIR=\"${data}\""
}

cmd_run() {
  require_name "${1:-}" "run"
  local name="$1"
  shift

  maybe_migrate

  if ! account_exists "$name"; then
    echo -e "${RED}Error:${RESET} No account named '${name}'." >&2
    exit 1
  fi

  local data
  data=$(account_data "$name")

  # Ensure IDE integration works with CLAUDE_CONFIG_DIR
  ensure_ide_symlink "$data"

  # Launch claude with the account's config dir
  CLAUDE_CONFIG_DIR="${data}" exec claude "$@"
}

cmd_list() {
  maybe_migrate

  local found=false

  for d in "${PROFILES_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}data/.claude.json" ]] || continue
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
    [[ -f "${d}data/.claude.json" ]] || continue
    local name
    name=$(basename "$d")
    echo -e "  ${CYAN}${name}${RESET}"
  done
}

cmd_remove() {
  require_name "${1:-}" "remove"
  local name="$1"

  if ! account_exists "$name"; then
    echo -e "${RED}Error:${RESET} No account named '${name}'."
    exit 1
  fi

  read -rp "Remove account '${name}' and all its data? [y/N] " confirm
  [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]] && { echo "Aborted."; exit 0; }

  rm -rf "$(account_dir "$name")"
  echo -e "${GREEN}Removed${RESET} account '${name}'."
}

cmd_help() {
  echo -e "${BOLD}claude-accounts${RESET} — manage multiple Claude Code CLI accounts"
  echo ""
  echo -e "${BOLD}Usage:${RESET}"
  echo "  $(basename "$0") <command> [name]"
  echo ""
  echo -e "${BOLD}Commands:${RESET}"
  echo -e "  ${CYAN}save <name>${RESET}        Save current login as <name> (run this first!)"
  echo -e "  ${CYAN}add  <name>${RESET}        Log in with a new account and save it"
  echo -e "  ${CYAN}list${RESET}               Show all saved accounts"
  echo -e "  ${CYAN}remove <name>${RESET}      Delete a saved account and its data"
  echo -e "  ${CYAN}env  <name>${RESET}        Print export for per-terminal use"
  echo -e "  ${CYAN}run  <name> [...]${RESET}  Run claude with a specific account"
  echo ""
  echo -e "${BOLD}First-time setup:${RESET}"
  echo "  1. $(basename "$0") save work        # copies your current login into an account"
  echo "  2. $(basename "$0") add personal     # log in with another account"
  echo "  3. $(basename "$0") run work         # launch claude as 'work'"
  echo ""
  echo -e "${BOLD}Usage:${RESET}"
  echo "  # Option 1: set env in current shell"
  echo "  eval \"\$($(basename "$0") env work)\""
  echo "  claude"
  echo ""
  echo "  # Option 2: one-liner"
  echo "  $(basename "$0") run personal"
  echo "  $(basename "$0") run personal -p \"hello\""
  echo ""
  echo -e "${BOLD}How it works:${RESET}"
  echo "  Each account gets a fully isolated directory with its own credentials,"
  echo "  history, settings, and usage data. Accounts are launched via the"
  echo "  CLAUDE_CONFIG_DIR env var, so multiple accounts can run simultaneously"
  echo "  in different terminals."
  echo ""
  echo "  Bare 'claude' (without run/env) still works using your original"
  echo "  ~/.claude.json and ~/.claude/ as an unmanaged fallback."
  echo ""
  echo -e "${BOLD}Profiles stored in:${RESET} ~/.claude-accounts/"
}

# ─── dispatch ────────────────────────────────────────────────────────────────

case "${1:-help}" in
  save)    cmd_save    "${2:-}" ;;
  add)     cmd_add     "${2:-}" ;;
  list)    cmd_list ;;
  remove)  cmd_remove  "${2:-}" ;;
  env)     cmd_env     "${2:-}" ;;
  run)     shift; cmd_run "$@" ;;
  help|--help|-h) cmd_help ;;
  *)
    echo -e "${RED}Unknown command:${RESET} ${1}"
    echo "Run '$(basename "$0") help' for usage."
    exit 1
    ;;
esac
