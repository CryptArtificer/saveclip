# -------------------------
# saveclip — Clipboard history
# -------------------------
# Sourced from ~/.zshrc — provides `clip`, `clb`, and friends.
[[ -n "${ZR_SHOW_BANNER:-}" ]] && echo -e "\033[90m  … saveclip\033[0m"

# Resolve binary — prefer release build, fall back to PATH
_saveclip_bin() {
  local dev_bin="$HOME/Dev/tools/saveclip/.build/release/saveclip"
  if [[ -x "$dev_bin" ]]; then
    echo "$dev_bin"
  elif command -v saveclip >/dev/null 2>&1; then
    echo "saveclip"
  else
    echo ""
  fi
}

# ─── clip — quick access ─────────────────────────────────────────────

clip() {
  local bin; bin=$(_saveclip_bin)
  if [[ -z "$bin" ]]; then
    echo "\033[31msaveclip binary not found.\033[0m Build with: cd ~/Dev/tools/saveclip && swift build -c release"
    return 1
  fi

  # Pipe mode: binary handles stdin detection natively
  if [[ ! -t 0 ]]; then
    "$bin" "$@"
    return $?
  fi

  local subcmd="${1:-}"

  case "$subcmd" in
    --pop)        "$bin" pop ;;
    search)       shift; clb "$@" ;;
    help|--help|-h) _clip_help ;;
    "")           "$bin" paste ;;
    *)
      # -N → last N entries to stdout
      if [[ "$subcmd" =~ ^-([1-9][0-9]*)$ ]]; then
        local count="${match[1]}"
        shift
        "$bin" paste --count "$count" "$@"
      # Positive number → get entry by ID
      elif [[ "$subcmd" =~ ^[0-9]+$ ]]; then
        "$bin" get "$subcmd"
      # Everything else → pass through to binary
      else
        shift
        "$bin" "$subcmd" "$@"
      fi
      ;;
  esac
}

# ─── clb — interactive TUI picker ────────────────────────────────────

clb() {
  local bin; bin=$(_saveclip_bin)
  if [[ -z "$bin" ]]; then
    echo "\033[31msaveclip binary not found.\033[0m Build with: cd ~/Dev/tools/saveclip && swift build -c release"
    return 1
  fi

  local -a flags=() query_parts=()
  for arg in "$@"; do
    if [[ "$arg" == -* ]]; then
      flags+=("$arg")
    else
      query_parts+=("$arg")
    fi
  done

  local result
  if [[ ${#query_parts[@]} -gt 0 ]]; then
    result=$("$bin" tui "${flags[@]}" --query "${query_parts[*]}")
  else
    result=$("$bin" tui "${flags[@]}")
  fi

  # Put selected text on the command line
  if [[ -n "$result" ]]; then
    print -z -- "$result"
  fi
}

# ─── Help ─────────────────────────────────────────────────────────────

_clip_help() {
  local _d=$'\033[90m' _c=$'\033[0;36m' _r=$'\033[0m' _b=$'\033[1m' _m=$'\033[0;35m'

  echo -e "${_b}  clip${_r} — clipboard history (works like pbcopy + pbpaste)"
  echo -e ""
  echo -e "${_m}  Output${_r} ${_d}(no pipe — acts like pbpaste)${_r}"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clip${_r}              Print last clip to stdout"
  echo -e "  ${_c}clip --pop${_r}        Print last clip and remove it"
  echo -e "  ${_c}clip -N${_r}           Last N entries to stdout (double-newline separated)"
  echo -e "  ${_c}clip -N -0${_r}        Last N entries, null-separated (for xargs -0)"
  echo -e "  ${_c}clip <id>${_r}         Copy entry by ID back to system clipboard"
  echo -e "  ${_c}clip get <id> -o${_r}  Print entry to stdout (without copying)"
  echo -e "  ${_c}clip get <id> -p${_r}  Print file path of stored clip bundle"
  echo -e ""
  echo -e "${_m}  Input${_r} ${_d}(pipe detected — acts like pbcopy, tees to stdout)${_r}"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}echo hi | clip${_r}         Save as one entry, pass through"
  echo -e "  ${_c}echo hi | clip -q${_r}      Save quietly (no tee, no status)"
  echo -e "  ${_c}cat f | clip | jq${_r}      Tee: saves and pipes to next command"
  echo -e "  ${_c}... | clip -s${_r}          Slurp: force all stdin as one entry"
  echo -e "  ${_d}Default splits on \\0 (null bytes). No nulls = one entry.${_r}"
  echo -e "  ${_d}printf 'a\\\\0b\\\\0c' | clip  → saves 3 separate entries${_r}"
  echo -e ""
  echo -e "${_m}  Files${_r} ${_d}(images, PDFs, any file)${_r}"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clip add${_r} ${_d}<file> [file...]${_r}  Add files to clipboard history"
  echo -e "  ${_d}Stores file URL (like Finder) + native content (PNG, JPEG, etc.)."
  echo -e "  Text files are auto-detected. Multiple files = separate entries.${_r}"
  echo -e ""
  echo -e "${_m}  Browse${_r}"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clip list${_r}         List entries (current branch)"
  echo -e "  ${_c}clip list -c N${_r}   List last N entries"
  echo -e "  ${_c}clip list --all${_r}   List entries (all branches)"
  echo -e "  ${_c}clip frequent${_r}     Most frequently copied entries"
  echo -e ""
  echo -e "${_m}  Manage${_r}"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clip pin${_r} ${_d}<id>${_r}     Pin entry (survives TTL auto-delete)"
  echo -e "  ${_c}clip unpin${_r} ${_d}<id>${_r}   Unpin entry"
  echo -e "  ${_c}clip delete${_r} ${_d}<id>${_r}  Delete entry"
  echo -e "  ${_c}clip clear${_r}        Delete all entries"
  echo -e "  ${_c}clip scrub${_r}        Find & flag sensitive entries (keys, tokens)"
  echo -e ""
  echo -e "${_m}  Branches${_r} ${_d}(organize clips by context)${_r}"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clip branch${_r}           Show current branch"
  echo -e "  ${_c}clip branch${_r} ${_d}<name>${_r}   Switch active branch"
  echo -e "  ${_c}clip branch -${_r}         Switch back to main"
  echo -e "  ${_c}clip branches${_r}         List all branches with counts"
  echo -e "  ${_c}clip move${_r} ${_d}<id> <br>${_r}  Move entry to branch"
  echo -e "  ${_d}Apps can auto-route to branches (see config.toml).${_r}"
  echo -e ""
  echo -e "${_b}  clb${_r} — interactive TUI picker (fullscreen)"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clb${_r}               Browse & pick from clipboard history"
  echo -e "  ${_c}clb${_r} ${_d}<query>${_r}       Open with pre-filtered search"
  echo -e "  ${_c}clip search${_r} ${_d}<q>${_r}   Same as clb <query>"
  echo -e ""
  echo -e "  ${_d}Type to search (FTS5 prefix match + Levenshtein typo fallback,"
  echo -e "  debounced 200ms). Preview loads full content after 150ms with"
  echo -e "  syntax highlighting (bat, if installed) and inline image rendering"
  echo -e "  (half-block 24-bit color). URLs highlighted in preview.${_r}"
  echo -e ""
  echo -e "  ${_d}enter=copy  ^O=stdout  ^D=del  ^P=pin  ^T=bump to top"
  echo -e "  ^F=frequent  ^B=branch  ^R=reload  ⌘↑/↓=home/end"
  echo -e "  Drag divider to resize preview (persisted). Scroll in"
  echo -e "  preview area scrolls content, scroll in list navigates.${_r}"
  echo -e ""
  echo -e "${_m}  Daemon${_r}"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clip start${_r}        Start the clipboard daemon"
  echo -e "  ${_c}clip stop${_r}         Stop the daemon"
  echo -e "  ${_c}clip status${_r}       Check if daemon is running"
  echo -e "  ${_c}clip config${_r}       Show current configuration"
  echo -e "  ${_d}Config: ~/.saveclip/config.toml (see config.example.toml)${_r}"
}

# ─── Zsh completion ───────────────────────────────────────────────────

_clip() {
  local -a subcmds=(
    'get:Copy entry back to clipboard'
    'list:List recent entries'
    'paste:Print entries to stdout'
    'add:Add files or stdin to clipboard history'
    'pin:Pin an entry'
    'unpin:Unpin an entry'
    'delete:Delete an entry'
    'clear:Delete all entries'
    'branch:Show/switch active branch'
    'branches:List all branches'
    'move:Move entry to branch'
    'start:Start the daemon'
    'stop:Stop the daemon'
    'status:Check daemon status'
    'config:Show configuration'
    'help:Show help'
  )

  if (( CURRENT == 2 )); then
    _describe 'clip command' subcmds
    return
  fi

  case "${words[2]}" in
    add)
      _files
      ;;
    get|pin|unpin|delete)
      if (( CURRENT == 3 )); then
        local bin; bin=$(_saveclip_bin)
        [[ -z "$bin" ]] && return
        local -a ids
        ids=(${(f)"$("$bin" list --all -c 50 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '{id=$1; $1=""; sub(/^ +/,""); print id":"$0}')"})
        _describe 'clip entry' ids
      fi
      ;;
    move)
      if (( CURRENT == 3 )); then
        local bin; bin=$(_saveclip_bin)
        [[ -z "$bin" ]] && return
        local -a ids
        ids=(${(f)"$("$bin" list --all -c 50 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '{id=$1; $1=""; sub(/^ +/,""); print id":"$0}')"})
        _describe 'clip entry' ids
      elif (( CURRENT == 4 )); then
        local bin; bin=$(_saveclip_bin)
        [[ -z "$bin" ]] && return
        local -a branches
        branches=(${(f)"$("$bin" branches 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '{name=$1; if(name=="*") name=$2; sub(/ .*/,"",name); print name}')"})
        _describe 'branch' branches
      fi
      ;;
    branch)
      if (( CURRENT == 3 )); then
        local bin; bin=$(_saveclip_bin)
        [[ -z "$bin" ]] && return
        local -a branches
        branches=(${(f)"$("$bin" branches 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '{name=$1; if(name=="*") name=$2; sub(/ .*/,"",name); print name}')"})
        branches+=('-:Switch back to main')
        _describe 'branch' branches
      fi
      ;;
  esac
}

compdef _clip clip
