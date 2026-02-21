# claude-accounts

A bash script to manage multiple Claude Code CLI accounts and switch between them easily.

## Installation

```bash
# Make the script executable
chmod +x ~/claude-accounts.sh

# Add alias to your shell (add to ~/.zshrc or ~/.bashrc)
alias claude-accounts='~/claude-accounts.sh'

# Reload shell
source ~/.zshrc
```

> **Optional:** Copy to a directory in your `$PATH` for global access:
> ```bash
> sudo cp ~/claude-accounts.sh /usr/local/bin/claude-accounts
> ```

## Requirements

- macOS / Linux with `bash` or `zsh`
- [Claude Code CLI](https://claude.ai/code) installed (`claude` command available)
- `jq` *(optional but recommended)* — used to strip only auth keys on `add`, instead of wiping the whole config

## How it works

Claude Code stores your active credentials in `~/.claude.json`. This script saves snapshots of that file as named profiles in `~/.claude-accounts/`. Switching accounts is as simple as copying the right profile back to `~/.claude.json`.

```
~/.claude.json                        ← active credentials (used by Claude Code)
~/.claude/stats-cache.json            ← active usage stats (used by Claude Code)
~/.claude.json.backup                 ← auto-backup before each switch
~/.claude-accounts/
  work.json                           ← saved credentials profile
  work.stats-cache.json               ← saved usage stats for "work"
  personal.json                       ← saved credentials profile
  personal.stats-cache.json           ← saved usage stats for "personal"
  .current                            ← tracks the active profile name
```

## Commands

| Command | Description |
|---------|-------------|
| `claude-accounts list` | Show all saved accounts (`*` marks the active one) |
| `claude-accounts save <name>` | Save current `~/.claude.json` as a named profile |
| `claude-accounts use <name>` | Switch to a saved account |
| `claude-accounts add <name>` | Open Claude for a fresh login and save as a new profile |
| `claude-accounts remove <name>` | Delete a saved profile |
| `claude-accounts current` | Show the currently active account name |
| `claude-accounts help` | Show usage information |

## Usage

### First time setup — save your existing login

```bash
claude-accounts save work
```

### Add a second account

```bash
claude-accounts add personal
# Opens Claude Code → log in with your second account → /exit
# Credentials are saved automatically as "personal"
```

### Switch between accounts

```bash
claude-accounts use work
claude-accounts use personal
```

### List all accounts

```bash
claude-accounts list
# Saved accounts:
#   * work     (active)
#     personal
```

### Check active account

```bash
claude-accounts current
# Active account: work
```

### Remove an account

```bash
claude-accounts remove personal
# Remove account 'personal'? [y/N] y
```

## Notes

- Every time you run `use`, your current `~/.claude.json` is backed up to `~/.claude.json.backup` before switching.
- The `add` command temporarily strips auth keys from `~/.claude.json` (using `jq`) to force a fresh login, while preserving other Claude settings like theme and preferences.
- If `jq` is not installed, `add` falls back to wiping `~/.claude.json` entirely before prompting for login.
- On `use`, the current account's stats are saved before switching, so each account maintains its own independent usage history.
- Profile files contain credentials — keep `~/.claude-accounts/` private and do not commit it to version control.
