# claude-accounts

A bash script to manage multiple Claude Code CLI accounts with full data isolation.

## The Problem

Claude Code stores credentials in `~/.claude.json` and all session data (history, telemetry, usage stats, project data) in `~/.claude/`. Without isolation, switching accounts causes mixed history, cross-account telemetry, and shared usage stats.

## How It Works

Each account gets a fully isolated directory. Accounts are launched via the `CLAUDE_CONFIG_DIR` environment variable, so you can run **multiple accounts simultaneously** in different terminals.

```
CLAUDE_CONFIG_DIR=~/.claude-accounts/<name>/data claude
```

Bare `claude` (without `run`/`env`) still works using your original `~/.claude.json` and `~/.claude/` as an unmanaged fallback.

### Directory layout

```
~/.claude-accounts/
  work/
    data/                   ← all Claude data for "work"
      .claude.json          ← credentials
      history.jsonl         ← conversation history
      settings.json         ← settings
      telemetry/            ← telemetry
      ...
  personal/
    data/                   ← all Claude data for "personal"
      .claude.json
      ...
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
|---|---|
| `save <name>` | Copy current login into a named account (run this first!) |
| `add <name>` | Log in with a new account and save it |
| `list` | Show all saved accounts |
| `remove <name>` | Delete a saved account and all its data |
| `env <name>` | Print `export` statement for per-terminal use |
| `run <name> [...]` | Run claude directly with a specific account |

## Usage

### First-time setup

```bash
# Save your existing login (copies ~/.claude.json and ~/.claude/ into the account)
claude-accounts save work
```

Your original files are left untouched — bare `claude` keeps working as before.

### Add a second account

```bash
claude-accounts add personal
# Opens Claude Code → log in with your second account → /exit
```

### Run with a specific account

```bash
# One-liner — launches claude with the account's config
claude-accounts run work
claude-accounts run personal
```

### Use different accounts in different terminals

```bash
# Terminal 1: use "work" account
claude-accounts run work

# Terminal 2: use "personal" account
claude-accounts run personal

# Or set the env var for the whole terminal session
eval "$(claude-accounts env work)"
claude
```

### Pass arguments through `run`

```bash
claude-accounts run work -p "summarize this file"
claude-accounts run personal --model sonnet
```

### List accounts

```bash
claude-accounts list
# Saved accounts:
#   work
#   personal
```

### Remove an account

```bash
claude-accounts remove personal
```

## Migrating from Older Versions

If you used an earlier version of this script (with `use`/`current` global-switching commands), the script will automatically:

- Restore `~/.claude.json` and `~/.claude/` from symlinks back to real files
- Clean up the `.current` marker file
- Migrate old profile formats to the current directory structure

## Notes

- The `save` command **copies** your data — originals stay untouched, so bare `claude` keeps working.
- The `run` and `env` commands use `CLAUDE_CONFIG_DIR` which is per-process, so multiple accounts can run simultaneously.
- Account names must contain only letters, numbers, hyphens, and underscores.
- Profile directories contain credentials — keep `~/.claude-accounts/` private.
