# saveclip

<p align="center">
  <img src="images/saveclip-sm.png" width="200" alt="saveclip">
</p>

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
- **Built-in TUI** — native terminal picker with FTS5 search, preview panel, mouse support, and inline actions (no fzf dependency)
- **Auto-refresh** — TUI updates live as new clipboard entries arrive
- **Mouse support** — click to select, double-click to copy, scroll wheel, draggable preview/list divider
- **Adaptive colors** — detects terminal fg/bg colors via OSC 10/11, age-based grey gradient that works in dark and light modes, reacts to theme changes live
- **Deduplication** — identical content is merged, most recent timestamp wins
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

## TUI picker

```
 ALL 42/200                        enter=copy  ^O=stdout  ^D=del  ^P=pin  ^F=freq  ^B=branch
  just a regular note
  second line of preview if present
────────────────────────────────────────────────────────────
> 38  27m  just a regular note
  37  28m  [sensitive] AKIAIOSF********************
  36  28m  [pin] normal safe text
  35  28m  ssh-ed25519 AAAAC3Nza...
  34  30m  safe normal text
  33  31m  [work] Slack message content here
  32  35m  SELECT * FROM users WHERE id = 42
  31  40m  const handler = async (req, res) => {...}
 > _
```

Type to search (FTS5 prefix matching), arrows or mouse to navigate, enter or
double-click to copy back to clipboard. Selected text (<1KB) is emitted to
stdout for `print -z` shell integration. The preview/list divider is draggable
and its size persists across sessions.

## Usage

```sh
# Start the daemon
clb start

# Open interactive picker (TUI)
clb

# Search
clb search <query>

# List recent entries
clb list
clb list --all

# Copy entry back to clipboard
clb <id>
clb get <id> -o    # print to stdout instead

# Manage entries
clb pin <id>
clb delete <id>
clb clear

# Branches
clb branch            # show current
clb branch work       # switch
clb branches          # list all
clb move <id> <branch>
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
| Up/Down / Scroll | Navigate |
| PgUp/PgDn | Page scroll |
| Click / Double-click | Select / Copy |
| Drag divider | Resize preview panel |
| Typing | Search entries (FTS5) |
| Esc / Ctrl-C | Exit |

### Mouse support

- **Scroll wheel** in the list area moves the selection cursor
- **Scroll wheel** in the preview area scrolls preview content
- **Click** selects an item, **double-click** copies it
- **Drag the divider** between preview and list to resize (persisted to `~/.saveclip/tui-state`)

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
