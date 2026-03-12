# saveclip

Clipboard history daemon for macOS.

> **Note** — This is a personal tool. You are welcome to explore the code or
> fork it, but please set your expectations accordingly.

## What it does

Runs as a background daemon, polling `NSPasteboard` and saving every copy
(text, images, file paths) to SQLite + on-disk bundles with all UTI
representations preserved. A built-in TUI picker lets you search, filter,
and restore entries instantly.

## Features

- **Full fidelity** — stores every pasteboard representation (rich text, HTML, images, source URLs), not just plain text
- **Built-in TUI** — native terminal picker with search, preview, and inline actions (no fzf dependency)
- **Branches** — organize clips by context (auto-route by app, manual switch)
- **Sensitive detection** — auto-flags AWS keys, GitHub PATs, SSH keys, JWTs, etc.
- **Frequency tracking** — surfaces repeatedly copied entries
- **Pin / TTL** — pin important clips; old unpinned ones expire automatically
- **Compression** — gzip-compresses old entries to save disk space
- **Budget eviction** — stays under a configurable storage cap, evicting large old media first

## Requirements

- macOS 13+
- Swift 5.9+

## Install

```sh
make install        # builds release + copies to /usr/local/bin
make link           # symlinks zsh integration to ~/.zsh/
```

Then source from your `.zshrc`:

```sh
source ~/.zsh/saveclip.zsh
```

## Usage

```sh
# Start the daemon
clip start

# Open interactive picker (TUI)
clip

# Search
clip search <query>

# List recent entries
clip list
clip list --all

# Copy entry back to clipboard
clip <id>
clip get <id> -o    # print to stdout instead

# Manage entries
clip pin <id>
clip delete <id>
clip clear

# Branches
clip branch            # show current
clip branch work       # switch
clip branches          # list all
clip move <id> <branch>
```

### TUI keybindings

| Key | Action |
|-----|--------|
| Enter | Copy to clipboard |
| Ctrl-O | Print to stdout |
| Ctrl-D | Delete selected |
| Ctrl-P | Toggle pin |
| Ctrl-F | Toggle frequent view |
| Ctrl-B | Toggle branch filter |
| Ctrl-R | Reload from DB |
| Up/Down | Navigate |
| PgUp/PgDn | Page scroll |
| Typing | Filter entries |
| Esc / Ctrl-C | Exit |

## Configuration

`~/.saveclip/config.toml`:

```toml
poll_interval = 0.5
max_entries = 1000
max_entry_size = 10485760
max_storage_mb = 300
compress_after_days = 7
ttl_days = 90
excluded_apps = ["1Password", "Keychain Access"]
sensitive_patterns = ["my-custom-pattern"]

# Auto-route apps to branches
branch.Slack = "work"
branch.Discord = "social"
```

## License

MIT
