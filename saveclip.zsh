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

  local subcmd="${1:-}"

  case "$subcmd" in
    --pop)
      "$bin" pop
      ;;
    start|stop|status|config|clear|pin|unpin|delete|list|branches|move|paste|pop|frequent|scrub)
      shift
      "$bin" "$subcmd" "$@"
      ;;
    search)
      shift
      clb "$@"
      ;;
    branch)
      shift
      "$bin" branch "$@"
      ;;
    get)
      shift
      "$bin" get "$@"
      ;;
    help|--help|-h)
      _clip_help
      ;;
    "")
      # No args: print last clip to stdout
      "$bin" paste
      ;;
    *)
      # If it looks like a number, treat as `get <id>`
      if [[ "$subcmd" =~ ^[0-9]+$ ]]; then
        "$bin" get "$subcmd"
      else
        echo "\033[31mUnknown command:\033[0m $subcmd"
        _clip_help
        return 1
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

  if [[ -n "$*" ]]; then
    "$bin" tui --query "$*"
  else
    "$bin" tui
  fi
}

# ─── Help ─────────────────────────────────────────────────────────────

_clip_help() {
  local _d=$'\033[90m' _c=$'\033[0;36m' _r=$'\033[0m' _b=$'\033[1m' _m=$'\033[0;35m'

  echo -e "${_b}  clip${_r} — clipboard history"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clip${_r}              Print last clip to stdout"
  echo -e "  ${_c}clip --pop${_r}        Print last clip to stdout and remove it"
  echo -e "  ${_c}clip <id>${_r}         Copy entry back to clipboard"
  echo -e "  ${_c}clip get <id> -o${_r}  Print entry to stdout"
  echo -e "  ${_c}clip get <id> -p${_r}  Print file path of stored clip"
  echo -e "  ${_c}clip list${_r}         List entries (current branch)"
  echo -e "  ${_c}clip list --all${_r}   List entries (all branches)"
  echo -e "  ${_c}clip pin${_r} ${_d}<id>${_r}     Pin entry (survives TTL)"
  echo -e "  ${_c}clip unpin${_r} ${_d}<id>${_r}   Unpin entry"
  echo -e "  ${_c}clip delete${_r} ${_d}<id>${_r}  Delete entry"
  echo -e "  ${_c}clip clear${_r}        Delete all entries"
  echo -e ""
  echo -e "${_m}  Branches${_r}"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clip branch${_r}           Show current branch"
  echo -e "  ${_c}clip branch${_r} ${_d}<name>${_r}   Switch active branch"
  echo -e "  ${_c}clip branch -${_r}         Switch back to main"
  echo -e "  ${_c}clip branches${_r}         List all branches with counts"
  echo -e "  ${_c}clip move${_r} ${_d}<id> <br>${_r}  Move entry to branch"
  echo -e ""
  echo -e "${_b}  clb${_r} — interactive TUI picker"
  echo -e "${_d}  ─────────────────────────────────────────${_r}"
  echo -e "  ${_c}clb${_r}               Browse & pick from clipboard history"
  echo -e "  ${_c}clb${_r} ${_d}<query>${_r}       Open with pre-filtered search"
  echo -e ""
  echo -e "  ${_c}clip start${_r}        Start the daemon"
  echo -e "  ${_c}clip stop${_r}         Stop the daemon"
  echo -e "  ${_c}clip status${_r}       Check daemon status"
  echo -e "  ${_c}clip config${_r}       Show configuration"
  echo -e ""
  echo -e "${_d}  clb: enter=copy  ^O=stdout  ^D=del  ^P=pin  ^F=freq  ^B=branch  ^R=reload${_r}"
}

# ─── Zsh completion ───────────────────────────────────────────────────

_clip() {
  local -a subcmds=(
    'get:Copy entry back to clipboard'
    'list:List recent entries'
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
