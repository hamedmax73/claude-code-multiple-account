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

# Cross-platform file mtime as epoch seconds
_file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null || echo 0
}

# Parse metadata from a session JSONL file.
# Outputs 6 lines (read with _read_session_meta):
#   title, cwd, branch, started, user_turns, asst_turns
_session_meta() {
  local file="$1"

  if command -v jq &>/dev/null; then
    jq -r -s '
      def first_of(f): [.[] | select(f)] | .[0];

      (first_of(.type == "summary") | .summary) // "" ,

      (first_of(.cwd) // {}) as $ctx |
        ($ctx.cwd // ""),
        ($ctx.gitBranch // ""),
        (($ctx.timestamp // "") | if . != "" then .[0:16] | sub("T"; " ") else "" end),

      ([.[] | select(.type == "user" and (.isMeta | not))] | length),
      ([.[] | select(.type == "assistant")] | length),

      (
        [ .[] | select(.type == "user" and (.isMeta | not)) |
          .message.content |
          ( if type == "array" then ([.[] | select(.type == "text")] | .[0].text) // ""
            elif type == "string" then .
            else "" end ) |
          split("\n")[0] |
          if length > 80 then .[0:80] else . end |
          select(length > 0) |
          select(test("<command-name>|<local-command") | not)
        ] | .[0]
      ) // ""
    ' "$file" 2>/dev/null | {
      # Resolve title: prefer summary (line 1), fall back to first user msg (line 7)
      local summary cwd branch started uturns aturns fallback
      IFS= read -r summary
      IFS= read -r cwd
      IFS= read -r branch
      IFS= read -r started
      IFS= read -r uturns
      IFS= read -r aturns
      IFS= read -r fallback
      local title="${summary:-$fallback}"
      printf '%s\n' "$title" "$cwd" "$branch" "$started" "$uturns" "$aturns"
    }
  else
    # Fallback: grep/sed — works without jq (basic field extraction)
    local summary="" cwd="" branch="" started="" fallback=""
    local user_turns=0 asst_turns=0

    # Summary title
    local summary_line
    summary_line=$(grep -m1 '"type":"summary"' "$file" 2>/dev/null || true)
    if [[ -n "$summary_line" ]]; then
      summary=$(echo "$summary_line" | sed -n 's/.*"summary":"\([^"]*\)".*/\1/p')
    fi

    # First entry with cwd → also grab branch and timestamp
    local ctx_line
    ctx_line=$(grep -m1 '"cwd":' "$file" 2>/dev/null || true)
    if [[ -n "$ctx_line" ]]; then
      cwd=$(echo "$ctx_line" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p')
      branch=$(echo "$ctx_line" | sed -n 's/.*"gitBranch":"\([^"]*\)".*/\1/p')
      local ts
      ts=$(echo "$ctx_line" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p')
      if [[ -n "$ts" ]]; then
        started="${ts:0:10} ${ts:11:5}"
      fi
    fi

    # Counts
    user_turns=$(grep '"type":"user"' "$file" 2>/dev/null | grep -cv '"isMeta":true' || echo 0)
    asst_turns=$(grep -c '"type":"assistant"' "$file" 2>/dev/null || echo 0)

    # Fallback title: first non-meta user message that isn't a command
    if [[ -z "$summary" ]]; then
      while IFS= read -r line; do
        local candidate
        candidate=$(echo "$line" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | cut -c1-80)
        [[ -z "$candidate" ]] && continue
        [[ "$candidate" == *"<command-name>"* ]] && continue
        [[ "$candidate" == *"<local-command"* ]] && continue
        fallback="$candidate"
        break
      done < <(grep '"type":"user"' "$file" 2>/dev/null | grep -v '"isMeta":true')
    fi

    local title="${summary:-$fallback}"
    printf '%s\n' "$title" "$cwd" "$branch" "$started" "$user_turns" "$asst_turns"
  fi
}

# Read 6 lines from _session_meta into named variables in the caller's scope.
# Usage: _read_session_meta <file>  (sets: title cwd branch started user_turns asst_turns)
_read_session_meta() {
  local _output
  _output=$(_session_meta "$1")
  { IFS= read -r title
    IFS= read -r cwd
    IFS= read -r branch
    IFS= read -r started
    IFS= read -r user_turns
    IFS= read -r asst_turns
  } <<< "$_output"
}

# Print one session entry to stdout
_print_session() {
  local file="$1" indent="${2:-  }"
  local session_id mod_date
  session_id=$(basename "$file" .jsonl)
  mod_date=$(date -r "$file" "+%Y-%m-%d %H:%M" 2>/dev/null \
         || stat -c "%y" "$file" 2>/dev/null | cut -d. -f1)

  local title cwd branch started user_turns asst_turns
  _read_session_meta "$file"

  echo -e "${indent}${CYAN}${session_id}${RESET}"
  [[ -n "$title"   ]] && echo -e "${indent}  ${BOLD}${title}${RESET}"
  [[ -n "$cwd"     ]] && echo -e "${indent}  Project : ${cwd}"
  [[ -n "$branch"  ]] && echo -e "${indent}  Branch  : ${branch}"
  local time_line=""
  [[ -n "$started"  ]] && time_line="Started: ${started}"
  if [[ -n "$mod_date" ]]; then
    [[ -n "$time_line" ]] && time_line="${time_line}  |  "
    time_line="${time_line}Modified: ${mod_date}"
  fi
  [[ -n "$time_line" ]] && echo -e "${indent}  ${time_line}"
  (( user_turns > 0 || asst_turns > 0 )) \
    && echo -e "${indent}  Turns   : ${user_turns} user, ${asst_turns} assistant"
  echo ""
}

# Collect all top-level session files for an account into _session_files[]
# sorted by modification time (oldest first → newest at bottom of terminal).
_collect_sessions() {
  local projects_dir="$1"
  _session_files=()

  local -a timed=()
  for proj_dir in "${projects_dir}"/*/; do
    [[ -d "$proj_dir" ]] || continue
    for f in "${proj_dir}"*.jsonl; do
      [[ -f "$f" ]] || continue
      timed+=("$(_file_mtime "$f") $f")
    done
  done

  # Sort by epoch (oldest first) and extract paths
  while IFS= read -r line; do
    _session_files+=("${line#* }")
  done < <(printf '%s\n' "${timed[@]}" | sort -n)
}

cmd_sessions() {
  require_name "${1:-}" "sessions"
  local name="$1"
  local limit="${2:-20}"

  maybe_migrate

  if ! account_exists "$name"; then
    echo -e "${RED}Error:${RESET} No account named '${name}'." >&2
    exit 1
  fi

  local projects_dir
  projects_dir="$(account_data "$name")/projects"

  if [[ ! -d "$projects_dir" ]]; then
    echo -e "${YELLOW}No sessions found for account '${name}'.${RESET}"
    return
  fi

  local -a _session_files
  _collect_sessions "$projects_dir"

  local total=${#_session_files[@]}
  if (( total == 0 )); then
    echo -e "${YELLOW}No sessions found for account '${name}'.${RESET}"
    return
  fi

  echo -e "${BOLD}Sessions for account '${CYAN}${name}${RESET}${BOLD}':${RESET}"
  echo ""

  local start=0
  if (( total > limit )); then
    start=$((total - limit))
    echo -e "  ${YELLOW}Showing ${limit} most recent of ${total} sessions.${RESET}"
    echo -e "  Run '$(basename "$0") sessions ${name} <number>' to show more."
    echo ""
  fi

  for (( i=start; i<total; i++ )); do
    _print_session "${_session_files[$i]}"
  done
}

cmd_copy_session() {
  local from_name="${1:-}"
  local to_name="${2:-}"
  local session_id="${3:-}"

  if [[ -z "$from_name" || -z "$to_name" ]]; then
    echo -e "${RED}Error:${RESET} source and destination account names are required."
    echo "  Usage: $(basename "$0") copy-session <from> <to> [session-id]"
    exit 1
  fi

  maybe_migrate

  if ! account_exists "$from_name"; then
    echo -e "${RED}Error:${RESET} No account named '${from_name}'." >&2
    exit 1
  fi
  if ! account_exists "$to_name"; then
    echo -e "${RED}Error:${RESET} No account named '${to_name}'." >&2
    exit 1
  fi

  local from_projects
  from_projects="$(account_data "$from_name")/projects"

  if [[ ! -d "$from_projects" ]]; then
    echo -e "${YELLOW}No sessions found in account '${from_name}'.${RESET}"
    exit 0
  fi

  # Collect sorted session files
  local -a _session_files
  _collect_sessions "$from_projects"

  # If a session-id was given, find it directly
  if [[ -n "$session_id" ]]; then
    local match=""
    for f in "${_session_files[@]}"; do
      if [[ "$(basename "$f" .jsonl)" == "$session_id" ]]; then
        match="$f"
        break
      fi
    done
    if [[ -z "$match" ]]; then
      echo -e "${RED}Error:${RESET} Session '${session_id}' not found in account '${from_name}'."
      echo "  Run '$(basename "$0") sessions ${from_name}' to list available sessions."
      exit 1
    fi
    _session_files=("$match")
  fi

  if [[ ${#_session_files[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No sessions found in account '${from_name}'.${RESET}"
    exit 1
  fi

  # If multiple sessions, prompt user to pick one (most recent at bottom, capped at 20)
  local selected_file
  if [[ ${#_session_files[@]} -gt 1 ]]; then
    local total=${#_session_files[@]}
    local limit=20
    local start=0
    if (( total > limit )); then
      start=$((total - limit))
    fi

    echo -e "${BOLD}Sessions in account '${CYAN}${from_name}${RESET}${BOLD}':${RESET}"
    echo ""
    if (( total > limit )); then
      echo -e "  ${YELLOW}Showing ${limit} most recent of ${total} sessions.${RESET}"
      echo -e "  Use '$(basename "$0") copy-session ${from_name} ${to_name} <id>' to copy an older one."
      echo ""
    fi

    local display_idx=1
    local -a picker=()
    for (( i=start; i<total; i++ )); do
      printf "  %2d) " "$display_idx"
      _print_session "${_session_files[$i]}" "      "
      picker+=("${_session_files[$i]}")
      (( display_idx++ ))
    done
    while true; do
      read -rp "Select session to copy [1-${#picker[@]}]: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#picker[@]} )); then
        selected_file="${picker[$((choice-1))]}"
        break
      fi
      echo -e "${YELLOW}Invalid choice. Enter a number between 1 and ${#picker[@]}.${RESET}"
    done
  else
    selected_file="${_session_files[0]}"
  fi

  # Resolve the project directory name for the destination
  local selected_proj
  selected_proj=$(basename "$(dirname "$selected_file")")

  local dest_proj_dir
  dest_proj_dir="$(account_data "$to_name")/projects/${selected_proj}"
  local dest_file="${dest_proj_dir}/$(basename "$selected_file")"

  if [[ -f "$dest_file" ]]; then
    local sid
    sid=$(basename "$selected_file" .jsonl)
    echo -e "${YELLOW}Session '${sid}' already exists in account '${to_name}'.${RESET}"
    read -rp "Overwrite? [y/N] " confirm
    [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "y" ]] && { echo "Aborted."; exit 0; }
  fi

  mkdir -p "$dest_proj_dir"
  cp "$selected_file" "$dest_file"

  local sid
  sid=$(basename "$selected_file" .jsonl)
  echo -e "${GREEN}Copied${RESET} session '${BOLD}${sid}${RESET}' → account '${BOLD}${to_name}${RESET}'."
  echo -e "  Resume it with:  $(basename "$0") run ${to_name} --continue ${sid}"
}

cmd_help() {
  echo -e "${BOLD}claude-accounts${RESET} — manage multiple Claude Code CLI accounts"
  echo ""
  echo -e "${BOLD}Usage:${RESET}"
  echo "  $(basename "$0") <command> [name]"
  echo ""
  echo -e "${BOLD}Commands:${RESET}"
  echo -e "  ${CYAN}save <name>${RESET}                   Save current login as <name> (run this first!)"
  echo -e "  ${CYAN}add  <name>${RESET}                   Log in with a new account and save it"
  echo -e "  ${CYAN}list${RESET}                          Show all saved accounts"
  echo -e "  ${CYAN}remove <name>${RESET}                 Delete a saved account and its data"
  echo -e "  ${CYAN}env  <name>${RESET}                   Print export for per-terminal use"
  echo -e "  ${CYAN}run  <name> [...]${RESET}             Run claude with a specific account"
  echo -e "  ${CYAN}sessions <name> [limit]${RESET}        List sessions (default: 20 most recent)"
  echo -e "  ${CYAN}copy-session <from> <to> [id]${RESET} Copy a session between accounts"
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
  echo -e "${BOLD}Session sharing:${RESET}"
  echo "  # List sessions in an account"
  echo "  $(basename "$0") sessions work"
  echo ""
  echo "  # Copy a specific session from work → personal"
  echo "  $(basename "$0") copy-session work personal <session-id>"
  echo ""
  echo "  # Pick interactively when no session-id is given"
  echo "  $(basename "$0") copy-session work personal"
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
  save)         cmd_save         "${2:-}" ;;
  add)          cmd_add          "${2:-}" ;;
  list)         cmd_list ;;
  remove)       cmd_remove       "${2:-}" ;;
  env)          cmd_env          "${2:-}" ;;
  run)          shift; cmd_run   "$@" ;;
  sessions)     cmd_sessions     "${2:-}" "${3:-}" ;;
  copy-session) cmd_copy_session "${2:-}" "${3:-}" "${4:-}" ;;
  help|--help|-h) cmd_help ;;
  *)
    echo -e "${RED}Unknown command:${RESET} ${1}"
    echo "Run '$(basename "$0") help' for usage."
    exit 1
    ;;
esac
