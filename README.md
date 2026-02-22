# claude-accounts

A bash script to manage multiple Claude Code CLI accounts with full data isolation between accounts.

## The Problem

Claude Code stores credentials in `~/.claude.json` and all session data (history, telemetry, usage stats, project data) in `~/.claude/`. Without isolation, switching accounts by swapping only the credentials file causes:

- **Mixed history** — conversations from one account appear in the other
- **Cross-account telemetry** — activity gets attributed to the wrong account on claude.ai
- **Shared usage stats** — usage counters bleed between accounts
- **Shared settings** — permissions and preferences aren't per-account

## How It Works

Each account gets a fully isolated directory containing both its credentials and all its Claude data. Symlinks point `~/.claude.json` and `~/.claude/` to the active account's directory. Switching accounts just updates the symlink targets — no data is copied or shared.

```
~/.claude.json          → symlink → ~/.claude-accounts/<active>/config.json
~/.claude/              → symlink → ~/.claude-accounts/<active>/data/

~/.claude-accounts/
  work/
    config.json         ← credentials for "work"
    data/               ← all Claude data for "work" (history, telemetry, settings, etc.)
  personal/
    config.json         ← credentials for "personal"
    data/               ← all Claude data for "personal"
  .current              ← tracks the active account name
```

## Installation

```bash
# Clone the repository
git clone https://github.com/user/claude-code-multiple-account.git

# Make the script executable
chmod +x claude-code-multiple-account/claude-accounts.sh

# Add alias to your shell (add to ~/.zshrc or ~/.bashrc)
alias claude-accounts='~/path/to/claude-accounts.sh'

# Reload shell
source ~/.zshrc
```

## Requirements

- macOS / Linux with `bash` or `zsh`
- [Claude Code CLI](https://claude.ai/code) installed (`claude` command available)
- `jq` *(optional)* — used to verify login success in `add`

## Commands

| Command | Description |
|---------|-------------|
| `claude-accounts save <name>` | Save current login as a named account (run this first!) |
| `claude-accounts use <name>` | Switch to a saved account |
| `claude-accounts add <name>` | Log in with a new account and save it |
| `claude-accounts list` | Show all saved accounts |
| `claude-accounts current` | Show the active account |
| `claude-accounts remove <name>` | Delete a saved account and all its data |
| `claude-accounts help` | Show usage information |

## Usage

### First-time setup — save your existing login

```bash
claude-accounts save work
```

This moves your existing `~/.claude.json` and `~/.claude/` into `~/.claude-accounts/work/` and creates symlinks. This is a one-time migration.

### Add a second account

```bash
claude-accounts add personal
# Opens Claude Code → log in with your second account → /exit
# Credentials and data are saved as "personal"
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
# Remove account 'personal' and all its data? [y/N] y
```

## Migrating from the Old Format

If you used an earlier version of this script that stored flat `.json` files in `~/.claude-accounts/`, the `list` and `use` commands will automatically migrate them to the new directory structure. The active account at the time of migration keeps its data; other accounts start with a fresh data directory.

## Notes

- **Close Claude Code before switching accounts** to avoid any in-flight data being written to the wrong account's directory.
- The first `save` command converts `~/.claude.json` and `~/.claude/` from real files to symlinks. This is transparent to Claude Code.
- You cannot remove the currently active account — switch to another one first.
- Account names must contain only letters, numbers, hyphens, and underscores.
- Profile directories contain credentials — keep `~/.claude-accounts/` private and do not commit it to version control.
