#!/usr/bin/env bash
# bin/fm-treehouse-lib.sh - resolve the treehouse command for spawn panes.
#
# Firstmate resolves treehouse in its own shell. Herdr can then receive the
# concrete native executable path when its pane is a Windows PowerShell process
# whose PATH does not include the Git Bash installation directory.

fm_treehouse_is_msys_mingw() {
  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*) return 0 ;;
  esac
  case "$(uname -s 2>/dev/null || true)" in
    MSYS*|MINGW*|CYGWIN*) return 0 ;;
  esac
  return 1
}

fm_treehouse_powershell_quote() {  # <native-executable>
  printf "'"
  printf '%s' "$1" | sed "s/'/''/g"
  printf "'"
}

# fm_treehouse_resolve_command <backend>: resolve treehouse once and publish
# FM_TREEHOUSE_EXECUTABLE plus FM_TREEHOUSE_GET_COMMAND for fm-spawn.sh.
# A POSIX absolute path on MSYS/MINGW must cross into Herdr's PowerShell as a
# native Windows path; cygpath is therefore required for that one boundary.
fm_treehouse_resolve_command() {  # <backend>
  local backend=${1:-} executable native
  executable=$(command -v treehouse 2>/dev/null || true)
  if [ -z "$executable" ] || [ ! -f "$executable" ] || [ ! -x "$executable" ]; then
    echo "error: treehouse is missing or is not an executable regular file in the Firstmate PATH" >&2
    return 1
  fi

  FM_TREEHOUSE_EXECUTABLE=$executable
  FM_TREEHOUSE_GET_COMMAND='treehouse get'
  if [ "$backend" = herdr ] && fm_treehouse_is_msys_mingw; then
    case "$executable" in
      /*)
        command -v cygpath >/dev/null 2>&1 || {
          echo "error: Herdr on MSYS/MINGW requires cygpath to convert treehouse '$executable' for PowerShell" >&2
          return 1
        }
        native=$(cygpath -w "$executable" 2>/dev/null || true)
        case "$native" in
          [A-Za-z]:\\*|[A-Za-z]:/*) ;;
          *)
            echo "error: cygpath did not return a native Windows path for treehouse '$executable'" >&2
            return 1
            ;;
        esac
        FM_TREEHOUSE_EXECUTABLE=$native
        FM_TREEHOUSE_GET_COMMAND="& $(fm_treehouse_powershell_quote "$native") get"
        ;;
    esac
  fi
}

# Native Windows Herdr keeps a cmd.exe foreground, while fm-spawn's launch
# templates are POSIX shell programs. Restrict this boundary to the
# MSYS/MINGW/Cygwin Herdr case; every other backend receives the composed launch
# text directly.
spawn_windows_herdr_native_capable() {
  [ "${BACKEND:-}" = herdr ] || return 1
  fm_treehouse_is_msys_mingw
}

spawn_windows_herdr_resolve_bash() {
  local candidate native
  candidate=$(type -P -- bash.exe 2>/dev/null || type -P -- bash 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
    /*)
      command -v cygpath >/dev/null 2>&1 || return 1
      native=$(cygpath -w -- "$candidate" 2>/dev/null) || return 1
      ;;
    [A-Za-z]:\\*) native=$candidate ;;
    *) return 1 ;;
  esac
  case "$native" in
    [A-Za-z]:\\*) printf '%s' "$native" ;;
    *) return 1 ;;
  esac
}

# Quote one argv item for the native Windows command-line parser. The outer
# cmd.exe command supplies the surrounding command string; doubling only the
# backslashes that precede a quote or the closing quote preserves the POSIX
# payload bytes that Bash must execute.
spawn_windows_herdr_cmd_arg() {
  local value=$1 out='"' ch i slashes=0
  for ((i = 0; i < ${#value}; i++)); do
    ch=${value:i:1}
    if [ "$ch" = "\\" ]; then
      slashes=$((slashes + 1))
      continue
    fi
    while [ "$slashes" -gt 0 ]; do
      out="${out}\\"
      slashes=$((slashes - 1))
    done
    if [ "$ch" = '"' ]; then
      out="${out}\\"
    fi
    out="${out}${ch}"
  done
  while [ "$slashes" -gt 0 ]; do
    out="${out}\\"
    out="${out}\\"
    slashes=$((slashes - 1))
  done
  out="${out}\""
  printf '%s' "$out"
}

spawn_windows_herdr_wrap_launch() {
  local bash_executable=$1 payload=$2 bash_arg payload_arg
  command -v cmd.exe >/dev/null 2>&1 || {
    echo "error: native-Windows Herdr launch requires cmd.exe" >&2
    return 1
  }
  bash_arg=$(spawn_windows_herdr_cmd_arg "$bash_executable") || return 1
  payload_arg=$(spawn_windows_herdr_cmd_arg "$payload") || return 1
  printf 'cmd.exe /d /v:off /s /c "%s -c %s"' "$bash_arg" "$payload_arg"
}
